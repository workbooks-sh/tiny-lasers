defmodule TinyLasers.Gate.Lower do
  @moduledoc """
  **F2 Phase 1 — ESTree (acorn JSON) → Elixir quoted AST, direct-term semantics.**

  Lowers real parsed JS to native BEAM behind the capability gate. The load-bearing decisions (proven by
  Phase 0 / H1): objects are DIRECTLY-HELD immutable terms `{keys, map}` — never a handle-table entry — so
  the BEAM GC reclaims unreachable objects and the memory wall vanishes. `o.x = v` is REBINDING (`o =
  oput(o, "x", v)`), which is correct for the single-reference case (the overwhelming majority of real JS);
  aliased-then-mutated objects are a later mutable-cell refinement.

  Confinement invariant (H2, inherited from the gate): guest data never becomes an atom/MFA/raw-fun. Every
  operation routes through `TinyLasers.Gate.Runtime`; an unknown identifier lowers to `:undefined`, so a
  host module can never be named. Guest keys are binaries; guest numbers are floats; guest strings binaries.

  Supported ESTree nodes (the core language — builtins are a separate layer):
    Program · VariableDeclaration · Literal · Identifier · ObjectExpression (+SpreadElement)
    MemberExpression · AssignmentExpression · BinaryExpression · LogicalExpression · UnaryExpression
    CallExpression · FunctionDeclaration/Expression · ArrowFunctionExpression · ReturnStatement
    IfStatement · ForStatement · WhileStatement · BlockStatement · ExpressionStatement · UpdateExpression
  """

  @runtime TinyLasers.Gate.Runtime

  @doc """
  Lower a full ESTree Program (decoded acorn JSON, string keys) into a quoted `run/0` body. `granted` maps a
  capability NAME to its integer cap id; a granted name compiles to a `{:host, id}` handle (never a module
  atom), anything else unknown to `:undefined`.
  """
  def program(ast, granted \\ %{})

  def program(%{"type" => "Program", "body" => body}, granted) do
    vars = collect_vars(body) |> Enum.uniq()
    boxed = boxed_set(vars, body)
    scope0 = %{locals: Enum.reduce(vars, MapSet.new(), &MapSet.put(&2, &1)), granted: granted, funcs: MapSet.new(), boxed: boxed, fnmap: %{}}
    {stmts, _scope} = stmts(body, scope0)
    # top-level `this` IS the global object; pre-bind hoisted vars (a boxed var gets a box — JS var hoisting).
    prelude =
      [quote(do: unquote(Macro.var(:__ggthis, __MODULE__)) = {:globalobj})] ++
        Enum.map(vars, fn v ->
          if MapSet.member?(boxed, v),
            do: quote(do: unquote(lvar(v)) = unquote(@runtime).box(:undefined)),
            else: quote(do: unquote(lvar(v)) = :undefined)
        end)

    # program end = end of the synchronous top-level script: run the queued promise callbacks (Walk does the
    # same after its last statement — without this every `.then` chain silently never fires in the compiled
    # lane). The program's VALUE stays the last statement's value (tests and callers rely on it).
    drain = quote(do: unquote(@runtime).drain_microtasks())
    val = Macro.var(:__ggprogval, __MODULE__)

    tail =
      case Enum.split(stmts, -1) do
        {init, [last]} -> init ++ [quote(do: unquote(val) = unquote(last)), drain, val]
        {[], []} -> [drain]
      end

    {:__block__, [], prelude ++ tail}
  end

  @doc """
  Lower a Program into a complete quoted `defmodule` BODY with the top-level statements SPLIT into
  `__gg_chunk_N/0` functions chained by `run/0`. The Erlang compiler is superlinear in single-function size —
  one giant `run/0` for a 1.27MB bundle was the compile-time wall — so many small functions compile near-
  linearly. The heavyweight optimizer passes are also disabled (`@compile` below): guest code is straight-line
  Runtime calls, so ssa/type/bool/bsm optimization buys nothing but time.

  Elixir bindings cannot cross function boundaries, so in this mode EVERY top-level var is boxed and the box
  HANDLES are registered in the greg registry (`gbox$<name>`); each chunk re-binds its local handles from the
  registry on entry, after which the normal boxed-var codegen applies unchanged.
  """
  # explosion thresholds: bodies above @explode_min_bytes source bytes split into @explode_piece_bytes slices
  # (878KB compiled in 109s as ONE function; ~12KB pieces compile near-linearly).
  @explode_min_bytes 30_000
  @explode_piece_bytes 12_000

  def module_quoted(ast, granted \\ %{}, opts \\ []) do
    %{main: main, siblings: []} = modules_quoted(ast, granted, Keyword.put(opts, :modules, 1))
    main
  end

  @doc """
  Like `module_quoted/3` but partitions the exploded-function defs round-robin across `opts[:modules]` sibling
  module bodies so the caller can COMPILE THEM CONCURRENTLY (the Erlang compiler parallelizes across modules,
  not within one). Chunk functions are invoked by NAME through `Runtime.cf/2`; each sibling exposes
  `__gg_register/0` (local-closure registration — no guest binary ever references another module, so each
  module's confinement check stays self-contained). The caller must run every sibling's `__gg_register/0`
  IN THE RUN PROCESS before `main.run/0` (registration lives in the process dictionary).
  """
  def modules_quoted(ast, granted \\ %{}, opts \\ [])

  def modules_quoted(%{"type" => "Program", "body" => body}, granted, opts) do
    chunk_size = Keyword.get(opts, :chunk_size, 25)
    nmods = max(Keyword.get(opts, :modules, 1), 1)
    # arm the sibling-def accumulator: func/6 explodes oversized bodies only when this is set.
    Process.put(:gg_lower_defs, [])
    vars = collect_vars(body) |> Enum.uniq()
    boxed = MapSet.new(vars)
    scope0 = %{locals: MapSet.new(vars), granted: granted, funcs: MapSet.new(), boxed: boxed, fnmap: %{}}
    hoisted = Enum.reduce(body, scope0, &hoist/2)

    # same global ordering as stmts/2: function declarations install first (JS hoisting).
    {fnnodes, rest} = Enum.split_with(body, &(is_map(&1) and &1["type"] == "FunctionDeclaration" and &1["id"]))
    chunks = Enum.chunk_every(fnnodes ++ rest, chunk_size)

    {chunk_defs, _} =
      chunks
      |> Enum.with_index()
      |> Enum.map_reduce(hoisted, fn {nodes, i}, sc ->
        {qs, sc2} = stmts(nodes, sc)
        name = String.to_atom("__gg_chunk_#{i}")

        # bind __ggthis plus the box handles of only the vars this chunk MENTIONS (from the registry).
        mentioned = MapSet.new(all_idents(nodes))

        handle_binds =
          [
            quote(do: unquote(Macro.var(:__ggthis, __MODULE__)) = {:globalobj}),
            quote(do: _ = unquote(Macro.var(:__ggthis, __MODULE__)))
          ] ++
            for v <- vars, MapSet.member?(mentioned, v) do
              quote(do: unquote(lvar(v)) = unquote(@runtime).greg_get(unquote("gbox$" <> v)))
            end

        q =
          quote do
            def unquote(name)() do
              unquote_splicing(handle_binds ++ qs)
              :ok
            end
          end

        {q, sc2}
      end)

    box_inits =
      Enum.map(vars, fn v ->
        quote(do: unquote(@runtime).greg_set(unquote("gbox$" <> v), unquote(@runtime).box(:undefined)))
      end)

    chunk_calls = Enum.map(0..(length(chunks) - 1)//1, fn i -> quote(do: unquote(String.to_atom("__gg_chunk_#{i}"))()) end)

    run_def =
      quote do
        def run() do
          __gg_register()
          unquote_splicing(box_inits ++ chunk_calls)
          unquote(@runtime).drain_microtasks()
        end
      end

    pairs = Process.get(:gg_lower_defs, []) |> Enum.reverse()
    Process.delete(:gg_lower_defs)

    # round-robin the exploded defs into nmods buckets; bucket 0 stays in main.
    buckets =
      if nmods <= 1 or pairs == [] do
        [pairs]
      else
        pairs
        |> Enum.with_index()
        |> Enum.group_by(fn {_, i} -> rem(i, nmods) end)
        |> Enum.sort()
        |> Enum.map(fn {_, l} -> Enum.map(l, &elem(&1, 0)) end)
      end

    [own | sibling_buckets] = buckets

    reg_def = fn ps ->
      regs =
        Enum.map(ps, fn {name, _} ->
          quote(do: unquote(@runtime).cf_reg(unquote(Atom.to_string(name)), fn env -> unquote(name)(env) end))
        end)

      quote do
        def __gg_register() do
          unquote_splicing(regs)
          :ok
        end
      end
    end

    # NOTE: do NOT set the internal no-*-opt compiler flags here. They saved no measurable compile time on the
    # 1.27MB bundle (77-81s either way) and :no_ssa_opt MISCOMPILED the include-phase box/try pattern (a node's
    # parent read yielded undefined unless an opaque remote call happened to sit between two statements —
    # a heisenbug that cost half a day; see f2_rollup_bundle history). It ALSO reproduces with :no_ssa_opt alone.
    main =
      quote do
        unquote_splicing(Enum.map(own, &elem(&1, 1)) ++ chunk_defs ++ [reg_def.(own), run_def])
      end

    siblings =
      Enum.map(sibling_buckets, fn ps ->
        quote do
          unquote_splicing(Enum.map(ps, &elem(&1, 1)) ++ [reg_def.(ps)])
        end
      end)

    %{main: main, siblings: siblings}
  end

  # ── statement lists thread lexical scope (which names are locals) ──
  defp stmts(nodes, scope) do
    # hoist function declarations + var names so forward references resolve as locals
    hoisted = Enum.reduce(nodes, scope, &hoist/2)

    # JS hoisting also moves the function INSTALLATION to the top of the scope: an object literal earlier in
    # source can hold a reference to a function declared later (`var T = {cjs: f}; function f(){}` — rollup's
    # DECONFLICT_IMPORTED_VARIABLES_BY_FORMAT table). greg_set must run before any other statement, so lower
    # the declarations first (their closures capture boxes, which the prelude pre-creates, so this is safe).
    {fnnodes, rest} =
      Enum.split_with(nodes, &(is_map(&1) and &1["type"] == "FunctionDeclaration" and &1["id"]))

    {rev, sc} =
      Enum.reduce(fnnodes ++ rest, {[], hoisted}, fn n, {acc, s} ->
        {q, s2} = stmt(n, s)
        {[q | acc], s2}
      end)

    {Enum.reverse(rev), sc}
  end

  defp hoist(%{"type" => "FunctionDeclaration", "id" => %{"name" => n}} = f, s),
    do: greg_hoist(s, n, fnkey(n, f))

  # class declarations hoist their name into the enclosing scope like a FunctionDeclaration (via the ctor's
  # greg key), so a `new C()` appearing before `class C {}` in source order resolves. fnkey uses the class's
  # `start`, which the synthetic ctor_decl (in stmt/2) mirrors — keeping the greg key identical on both sides.
  defp hoist(%{"type" => "ClassDeclaration", "id" => %{"name" => n}} = c, s),
    do: greg_hoist(s, n, fnkey(n, c))

  # register a greg-backed declaration (function/class): add to funcs/fnmap. Shadowing of an inherited
  # same-named boxed var is handled at the function-scope level via `fndecl_names` (which now includes
  # classes) — NOT here, so a locally boxed+reassigned function name keeps reading its box.
  defp greg_hoist(s, n, key) do
    s
    |> Map.put(:funcs, MapSet.put(s[:funcs] || MapSet.new(), n))
    |> Map.put(:fnmap, Map.put(s[:fnmap] || %{}, n, key))
  end

  defp hoist(%{"type" => "VariableDeclaration", "declarations" => ds}, s) do
    Enum.reduce(ds, s, fn d, acc ->
      Enum.reduce(pattern_names(d["id"]), acc, &%{&2 | locals: MapSet.put(&2.locals, &1)})
    end)
  end

  defp hoist(_, s), do: s

  # ── statements ──
  defp stmt(%{"type" => "VariableDeclaration", "declarations" => ds}, scope) do
    {rev, sc} =
      Enum.reduce(ds, {[], scope}, fn d, {acc, s} ->
        init = d["init"]
        s2 = Enum.reduce(pattern_names(d["id"]), s, &%{&2 | locals: MapSet.put(&2.locals, &1)})
        vq = if init, do: expr(init, s2), else: :undefined

        q =
          case d["id"] do
            %{"type" => "Identifier", "name" => n} -> bind_local(n, vq, s2)
            pattern -> destructure(pattern, vq, s2)
          end

        {[q | acc], s2}
      end)

    {{:__block__, [], Enum.reverse(rev)}, sc}
  end

  # top-level (and nested) function declarations register in the late-bound function registry, so forward
  # references and mutual recursion work regardless of source order.
  defp stmt(%{"type" => "FunctionDeclaration", "id" => %{"name" => n}} = f, scope) do
    key = fnkey(n, f)
    scope = %{scope | funcs: MapSet.put(scope[:funcs] || MapSet.new(), n), fnmap: Map.put(scope[:fnmap] || %{}, n, key)}
    fq = func(f["params"], f["body"], scope, f["async"] == true, false, f["generator"] == true)
    {quote(do: unquote(@runtime).greg_set(unquote(key), unquote(fq))), scope}
  end

  defp stmt(%{"type" => "ReturnStatement", "argument" => arg}, scope) do
    # returns are modeled by throwing to the function-body catch (see func/3)
    vq = if arg, do: expr(arg, scope), else: :undefined
    {quote(do: unquote(@runtime).ret(unquote(vq))), scope}
  end

  defp stmt(%{"type" => "ExpressionStatement", "expression" => e}, scope), do: {expr(e, scope), scope}

  defp stmt(%{"type" => "BlockStatement", "body" => body}, scope) do
    {qs, _} = stmts(body, scope)
    {{:__block__, [], qs}, scope}
  end

  # if/else must THREAD variables mutated in either branch out to the enclosing scope — Elixir `if` does not
  # export branch bindings, so each branch ends by returning the tuple of all branch-mutated vars, which we
  # rebind. (A var unmutated in a branch just returns its incoming value.) Correct for mutation-in-conditional
  # inside loops (e.g. qsort's `if (a[i]<p) lo.push(...) else hi.push(...)`).
  defp stmt(%{"type" => "IfStatement"} = n, scope) do
    t = expr(n["test"], scope)
    {cons, _} = stmt(n["consequent"], scope)
    alt = if n["alternate"], do: elem(stmt(n["alternate"], scope), 0), else: nil

    mutated =
      (assigned_names(n["consequent"]) ++ assigned_names(n["alternate"])) |> Enum.uniq() |> not_boxed(scope)

    if mutated == [] do
      q = quote(do: if(unquote(@runtime).truthy(unquote(t)), do: unquote(cons), else: unquote(alt || :undefined)))
      {q, scope}
    else
      state = {:{}, [], Enum.map(mutated, &lvar/1)}
      inits = for v <- mutated, not MapSet.member?(scope.locals, v), do: quote(do: unquote(lvar(v)) = :undefined)

      q =
        quote do
          unquote_splicing(inits)

          unquote(state) =
            if unquote(@runtime).truthy(unquote(t)) do
              unquote(cons)
              unquote(state)
            else
              unquote(alt)
              unquote(state)
            end
        end

      {q, scope}
    end
  end

  # for (init; test; update) body  — lowered to a tail-recursive anonymous fn (BEAM-native loop, GC'd).
  # Elixir closures capture by value, so every variable MUTATED in the loop (the counter AND any outer
  # accumulator) is threaded through the recursion as explicit state: rebound at the top of each iteration,
  # passed forward at the tail, and rebound in the enclosing scope from the loop's final state.
  defp stmt(%{"type" => "ForStatement"} = n, scope) do
    label = scope[:pending_label]
    {initq, s0} = if n["init"], do: for_init(n["init"], Map.put(scope, :pending_label, nil)), else: {:undefined, Map.put(scope, :pending_label, nil)}

    if loop_uses_control?(n["body"]) do
      # break/continue present: throw-based control flow. The loop's mutated vars are boxed (boxed_set), so the
      # state persists across the throw — no tuple threading needed.
      tag = System.unique_integer([:positive])
      s1 = Map.put(s0, :loops, [{label, tag, :loop} | (scope[:loops] || [])])
      loop = Macro.var(:gg_loop, __MODULE__)
      testq = if n["test"], do: expr(n["test"], s1), else: true
      {bodyq, _} = stmt(n["body"], s1)
      updateq = if n["update"], do: expr(n["update"], s1), else: :undefined

      q =
        quote do
          unquote(initq)

          unquote(loop) = fn me ->
            if unquote(@runtime).truthy(unquote(testq)) do
              try do
                unquote(bodyq)
              catch
                :throw, {:gg_continue, unquote(tag)} -> :ok
              end

              unquote(updateq)
              me.(me)
            else
              :ok
            end
          end

          try do
            unquote(loop).(unquote(loop))
          catch
            :throw, {:gg_break, unquote(tag)} -> :ok
          end
        end

      {q, scope}
    else
      s1 = s0

      mutated =
        [n["test"], n["update"], n["body"]]
        |> Enum.reject(&is_nil/1)
        |> Enum.flat_map(&assigned_names/1)
        |> Kernel.++(assigned_names(n["init"]))
        |> Enum.uniq()
        |> not_boxed(scope)

      statevars = Enum.map(mutated, &lvar/1)
      state_tuple = {:{}, [], statevars}
      loop = Macro.var(:gg_loop, __MODULE__)
      inits = for v <- mutated, not MapSet.member?(scope.locals, v), do: quote(do: unquote(lvar(v)) = :undefined)
      testq = if n["test"], do: expr(n["test"], s1), else: true
      {bodyq, _} = stmt(n["body"], s1)
      updateq = if n["update"], do: expr(n["update"], s1), else: :undefined

      q =
        quote do
          unquote_splicing(inits)
          unquote(initq)

          unquote(loop) = fn me, unquote(state_tuple) ->
            if unquote(@runtime).truthy(unquote(testq)) do
              unquote(bodyq)
              unquote(updateq)
              me.(me, unquote(state_tuple))
            else
              unquote(state_tuple)
            end
          end

          unquote(state_tuple) = unquote(loop).(unquote(loop), unquote(state_tuple))
        end

      {q, scope}
    end
  end

  # break targets the innermost breakable (loop OR switch); labeled → the matching one.
  defp break_tag(%{"name" => lbl}, scope) do
    case Enum.find(scope[:loops] || [], fn {l, _, _} -> l == lbl end) do
      {_, tag, _} -> tag
      nil -> first_tag(scope[:loops])
    end
  end

  defp break_tag(_nil, scope), do: first_tag(scope[:loops])

  # continue targets the innermost LOOP (switches are skipped); labeled → the matching loop.
  defp cont_tag(%{"name" => lbl}, scope) do
    case Enum.find(scope[:loops] || [], fn {l, _, k} -> l == lbl and k == :loop end) do
      {_, tag, _} -> tag
      nil -> loop_only_tag(scope[:loops])
    end
  end

  defp cont_tag(_nil, scope), do: loop_only_tag(scope[:loops])

  defp first_tag([{_, tag, _} | _]), do: tag
  defp first_tag(_), do: 0
  defp loop_only_tag(stack), do: (case Enum.find(stack || [], fn {_, _, k} -> k == :loop end) do {_, tag, _} -> tag; _ -> 0 end)

  defp stmt(%{"type" => "ThrowStatement", "argument" => arg}, scope),
    do: {quote(do: unquote(@runtime).throw_val(unquote(expr(arg, scope)))), scope}

  # a label attaches to its (loop) body — pass it down so the loop registers `label -> tag` for break/continue.
  defp stmt(%{"type" => "LabeledStatement", "label" => %{"name" => lbl}, "body" => body}, scope),
    do: stmt(body, Map.put(scope, :pending_label, lbl))

  # break/continue throw to the target loop's catch. Unlabeled → innermost loop; labeled → the loop with that
  # label. (Boxed loop state survives the throw; see boxed_set/control_loop_vars.)
  defp stmt(%{"type" => "BreakStatement", "label" => l}, scope),
    do: {quote(do: unquote(@runtime).brk(unquote(break_tag(l, scope)))), scope}

  defp stmt(%{"type" => "ContinueStatement", "label" => l}, scope),
    do: {quote(do: unquote(@runtime).cont(unquote(cont_tag(l, scope)))), scope}

  # try { block } catch (e) { handler } finally { finalizer }. Mutations thread out as returned state (like
  # if/for). Guest throws ({:gg_throw}) and guest errors ({:gg_guest_error}) are catchable; {:gg_return}
  # propagates (never swallowed). Finalizer runs after normal completion (v0: not on a return-in-try).
  defp stmt(%{"type" => "TryStatement"} = n, scope) do
    handler = n["handler"]
    hparam = handler && handler["param"]
    param = hparam && hparam["name"]
    # the catch param is a FRESH plain binding (`gg_param = thrown`); if it shadows an outer boxed var of the
    # same name, drop it from `boxed` in the handler so reads use the plain binding (not box_get on a raw value).
    # A PATTERN param (`catch ({ message })`) binds all its names and destructures from the thrown value.
    hnames = cond do
      param -> [param]
      hparam -> pattern_names(hparam)
      true -> []
    end

    hscope =
      if hnames != [],
        do: %{scope | locals: Enum.reduce(hnames, scope.locals, &MapSet.put(&2, &1)),
              boxed: Enum.reduce(hnames, scope[:boxed] || MapSet.new(), &MapSet.delete(&2, &1))},
        else: scope

    {blockq, _} = stmt(n["block"], scope)
    {handlerq, _} = if handler, do: stmt(handler["body"], hscope), else: {:undefined, scope}

    mutated =
      (assigned_names(n["block"]) ++
         (handler && assigned_names(handler["body"]) || []) ++
         (n["finalizer"] && assigned_names(n["finalizer"]) || []))
      |> Enum.uniq()
      |> not_boxed(scope)

    state = {:{}, [], Enum.map(mutated, &lvar/1)}
    inits = for v <- mutated, not MapSet.member?(scope.locals, v), do: quote(do: unquote(lvar(v)) = :undefined)

    bind_param =
      cond do
        param -> quote(do: unquote(lvar(param)) = __gg_thrown)
        hparam -> block([quote(do: _ = __gg_thrown) | destr_targets(hparam, quote(do: __gg_thrown), hscope)])
        true -> quote(do: _ = __gg_thrown)
      end

    # the handler runs inside its own try so a rethrowing handler (`catch(e){ throw wrap(e) }`) still reaches
    # the finalizer; anything the handler throws (including gg_return) is staged for rethrow AFTER `finally`.
    run_handler =
      quote do
        try do
          unquote(bind_param)
          unquote(handlerq)
          {unquote(state), nil}
        catch
          :throw, __gg_h -> {unquote(state), {:gg_rethrow, __gg_h}}
        end
      end

    q =
      cond do
        n["finalizer"] && handler ->
          {finq, _} = stmt(n["finalizer"], scope)

          quote do
            unquote_splicing(inits)

            {unquote(state), __gg_rethrow} =
              try do
                unquote(blockq)
                {unquote(state), nil}
              catch
                :throw, {:gg_throw, __gg_thrown} -> unquote(run_handler)
                :throw, {:gg_guest_error, __gg_reason} ->
                  __gg_thrown = __gg_reason
                  unquote(run_handler)

                # gg_return / gg_break / gg_continue: the finalizer must still run, then the control throw
                # continues on its way.
                :throw, __gg_other -> {unquote(state), {:gg_rethrow, __gg_other}}
              end

            unquote(finq)

            case __gg_rethrow do
              {:gg_rethrow, __gg_e} -> unquote(@runtime).rethrow(__gg_e)
              _ -> :ok
            end
          end

        n["finalizer"] ->
          # try/finally WITHOUT catch: JS runs the finalizer then RETHROWS — swallowing here silently
          # resolved rollup's failed build as undefined (catchUnfinishedHookActions is exactly this shape).
          {finq, _} = stmt(n["finalizer"], scope)

          quote do
            unquote_splicing(inits)

            {unquote(state), __gg_rethrow} =
              try do
                unquote(blockq)
                {unquote(state), nil}
              catch
                :throw, __gg_other -> {unquote(state), {:gg_rethrow, __gg_other}}
              end

            unquote(finq)

            case __gg_rethrow do
              {:gg_rethrow, __gg_e} -> unquote(@runtime).rethrow(__gg_e)
              _ -> :ok
            end
          end

        true ->
          quote do
            unquote_splicing(inits)

            unquote(state) =
              try do
                unquote(blockq)
                unquote(state)
              catch
                :throw, {:gg_throw, __gg_thrown} ->
                  unquote(bind_param)
                  unquote(handlerq)
                  unquote(state)

                :throw, {:gg_guest_error, __gg_reason} ->
                  __gg_thrown = __gg_reason
                  unquote(bind_param)
                  unquote(handlerq)
                  unquote(state)
              end
          end
      end

    {q, scope}
  end

  defp stmt(%{"type" => "WhileStatement"} = n, scope) do
    stmt(%{"type" => "ForStatement", "init" => nil, "test" => n["test"], "update" => nil, "body" => n["body"]}, scope)
  end

  # do body while(test): a native loop that runs the body, then checks the test. Always the throw-based
  # control shape — the old "body-copy + while" desugar compiled the first body copy with NO loop tag, so a
  # `break` inside it threw the uncatchable tag 0 (rollup's render path died on exactly that). State lives in
  # boxes (control_loop_vars boxes every var a do-while assigns); `continue` correctly falls through to the test.
  defp stmt(%{"type" => "DoWhileStatement"} = n, scope) do
    label = scope[:pending_label]
    tag = System.unique_integer([:positive])

    s1 =
      scope
      |> Map.put(:pending_label, nil)
      |> Map.put(:loops, [{label, tag, :loop} | scope[:loops] || []])

    testq = expr(n["test"], s1)
    {bodyq, _} = stmt(n["body"], s1)
    loop = Macro.var(:gg_loop, __MODULE__)

    q =
      quote do
        unquote(loop) = fn me ->
          try do
            unquote(bodyq)
          catch
            :throw, {:gg_continue, unquote(tag)} -> :ok
          end

          if unquote(@runtime).truthy(unquote(testq)), do: me.(me), else: :ok
        end

        try do
          unquote(loop).(unquote(loop))
        catch
          :throw, {:gg_break, unquote(tag)} -> :ok
        end
      end

    {q, scope}
  end

  defp stmt(%{"type" => "ForOfStatement"} = n, scope), do: for_each(n, :of, scope)
  defp stmt(%{"type" => "ForInStatement"} = n, scope), do: for_each(n, :in, scope)

  # switch(d){ case v: body; break; … default: … } — lowered to a `d === v` if/else-if chain (break ends a
  # case; NON-fall-through, the common form). Bind d to a temp, fold the cases into nested IfStatements, reuse
  # the if-threading for mutated vars.
  # JS switch with correct FALL-THROUGH: find the first matching case (or default), then run every following
  # case body until a `break`. Lowered as a matched-flag sequence: `matched ||= (d === caseVal)`, then
  # `if matched: body`. `break` (unlabeled) targets this switch's tag; case bodies mutate BOXED vars (switch_vars)
  # so they survive the `if matched` guards. `default` triggers when no tested case matches (checked over all).
  defp stmt(%{"type" => "SwitchStatement"} = n, scope) do
    label = scope[:pending_label]
    tag = System.unique_integer([:positive])
    s = Map.merge(scope, %{loops: [{label, tag, :switch} | scope[:loops] || []], pending_label: nil})
    dq = expr(n["discriminant"], s)
    cases = n["cases"] || []
    m = Macro.var(:__ggm, __MODULE__)
    d = Macro.var(:__ggd, __MODULE__)
    nomatch = Macro.var(:__ggnomatch, __MODULE__)

    matchq = fn c -> quote(do: unquote(@runtime).binop(:===, unquote(d), unquote(expr(c["test"], s)))) end

    # nomatch = true iff NO tested case matches (nested ifs — avoid Elixir `or`/`not`, which emit :erlang.error
    # boolean checks and would break the guest's Runtime-only confinement).
    nomatch_q =
      cases
      |> Enum.reject(&(&1["test"] == nil))
      |> Enum.reduce(true, fn c, acc -> quote(do: if(unquote(matchq.(c)), do: false, else: unquote(acc))) end)

    case_stmts =
      Enum.map(cases, fn c ->
        {bodyq, _} = stmt(block_of(c["consequent"] || []), s)
        cond_expr = if c["test"] == nil, do: nomatch, else: matchq.(c)
        quote(do: (unquote(m) = if(unquote(m), do: true, else: unquote(cond_expr)); if(unquote(m), do: unquote(bodyq))))
      end)

    q =
      quote do
        unquote(d) = unquote(dq)
        unquote(nomatch) = unquote(nomatch_q)
        unquote(m) = false

        try do
          (unquote_splicing(case_stmts))
        catch
          :throw, {:gg_break, unquote(tag)} -> :ok
        end
      end

    {q, scope}
  end

  # ES6 `class C { constructor(){…} m(){…} static s(){…} get g(){…} }` desugars to F2's existing prototype
  # machinery: a constructor FUNCTION + method assignments onto `C.prototype` (instance) / `C` (static) /
  # Object.defineProperty (get/set). (magic-string's classes are flat — no extends/super.)
  defp stmt(%{"type" => t} = n, scope) when t in ["ClassDeclaration", "ClassExpression"] do
    name = (n["id"] && n["id"]["name"]) || "__ggclass"
    members = (n["body"] && n["body"]["body"]) || []
    ctor = Enum.find(members, &(&1["kind"] == "constructor"))

    # ES6 inheritance: `class C extends S`. Bind the superclass value to a hidden local so the ctor/methods can
    # invoke it (super()/super.m()), rewrite Super nodes, and link the prototype chain after the ctor exists.
    sup = n["superClass"]
    sn = "__ggsuper$#{n["start"]}"
    rw = fn node -> if sup, do: rw_super(node, sn), else: node end

    cid = %{"type" => "Identifier", "name" => name}
    proto = member_of(cid, ident_key("prototype"), false)

    # a DERIVED class without an explicit constructor gets the implicit `constructor(){ super(...arguments) }`
    # (an empty body would skip the parent ctor entirely — rollup's `class Sub extends NodeBase {}` nodes
    # relied on NodeBase's ctor running createScope/initialise).
    default_body =
      if sup do
        %{"type" => "BlockStatement", "body" => [
          expr_stmt(%{"type" => "CallExpression", "callee" => %{"type" => "Super"},
            "arguments" => [%{"type" => "SpreadElement", "argument" => %{"type" => "Identifier", "name" => "arguments"}}]})
        ]}
      else
        %{"type" => "BlockStatement", "body" => []}
      end

    ctor_decl = %{
      "type" => "FunctionDeclaration",
      "id" => cid,
      # carry the class's `start` so the ctor's greg key (fnkey) matches the enclosing-scope hoist below.
      "start" => n["start"],
      "params" => (ctor && ctor["value"]["params"]) || [],
      "body" => rw.((ctor && ctor["value"]["body"]) || default_body)
    }

    member_stmts =
      for mth <- members, mth["kind"] != "constructor" do
        target = if mth["static"], do: cid, else: proto
        key = mth["key"]
        # the method fn IS the super scope: rewrite its body (rw_super stops at nested fns, so calling it on the
        # whole FunctionExpression would skip the body entirely).
        mval = if sup, do: Map.put(mth["value"], "body", rw_super(mth["value"]["body"], sn)), else: mth["value"]

        case mth["kind"] do
          k when k in ["method", nil] ->
            expr_stmt(%{"type" => "AssignmentExpression", "operator" => "=",
              "left" => member_of(target, key, mth["computed"]), "right" => mval})

          k when k in ["get", "set"] ->
            # Object.defineProperty(target, key, { <get|set>: fn })
            desc = %{"type" => "ObjectExpression", "properties" => [
              %{"type" => "Property", "key" => ident_key(k), "value" => mval, "computed" => false, "kind" => "init"}
            ]}
            expr_stmt(call_expr(member_of(obj_id("Object"), ident_key("defineProperty"), false),
              [target, target_key_expr(target, key, mth["computed"]), desc]))
        end
      end

    if sup do
      # bind the superclass VALUE in the greg registry (globally reachable from every method/ctor closure — a
      # captured local wouldn't work: `sn` is synthesised during lowering, after the enclosing function's
      # capture/box analysis already ran). Methods reference `sn` as a greg-backed name.
      scope_f = scope
                |> Map.put(:funcs, MapSet.put(scope[:funcs] || MapSet.new(), sn))
                |> Map.put(:fnmap, Map.put(scope[:fnmap] || %{}, sn, sn))
      {lowered, sc} = stmts([ctor_decl | member_stmts], scope_f)
      setsuperq = quote(do: unquote(@runtime).greg_set(unquote(sn), unquote(expr(sup, scope))))
      childq = quote(do: unquote(@runtime).greg_get(unquote(fnkey(name, ctor_decl))))
      linkq = quote(do: unquote(@runtime).set_proto_chain(unquote(childq), unquote(@runtime).greg_get(unquote(sn))))
      {block([setsuperq | lowered] ++ [linkq]), sc}
    else
      stmts([ctor_decl | member_stmts], scope)
    end
  end

  # rewrite `super(...)` / `super.m(...)` / `super.m` against a bound superclass local `sn`. super() invokes the
  # parent constructor with the current `this`; super.m(...) invokes the parent-prototype method with `this`.
  # Does not descend into nested regular functions (they open a new super scope); arrows inherit and ARE rewritten.
  defp rw_super(%{"type" => "CallExpression", "callee" => %{"type" => "Super"}} = c, sn) do
    %{c | "callee" => member_of(ident_key(sn), ident_key("call"), false),
          "arguments" => [%{"type" => "ThisExpression"} | Enum.map(c["arguments"] || [], &rw_super(&1, sn))]}
  end
  defp rw_super(%{"type" => "CallExpression", "callee" => %{"type" => "MemberExpression", "object" => %{"type" => "Super"}} = m} = c, sn) do
    protom = member_of(member_of(ident_key(sn), ident_key("prototype"), false), m["property"], m["computed"])
    %{c | "callee" => member_of(protom, ident_key("call"), false),
          "arguments" => [%{"type" => "ThisExpression"} | Enum.map(c["arguments"] || [], &rw_super(&1, sn))]}
  end
  defp rw_super(%{"type" => "MemberExpression", "object" => %{"type" => "Super"}} = m, sn),
    do: %{m | "object" => member_of(ident_key(sn), ident_key("prototype"), false), "property" => rw_super(m["property"], sn)}
  defp rw_super(%{"type" => ft} = n, _sn) when ft in ["FunctionExpression", "FunctionDeclaration"], do: n
  defp rw_super(%{} = node, sn), do: Map.new(node, fn {k, v} -> {k, rw_super(v, sn)} end)
  defp rw_super(list, sn) when is_list(list), do: Enum.map(list, &rw_super(&1, sn))
  defp rw_super(x, _sn), do: x

  defp stmt(other, scope), do: {expr(other, scope), scope}

  defp member_of(obj, key, computed), do: %{"type" => "MemberExpression", "object" => obj, "property" => key, "computed" => computed}
  defp ident_key(name), do: %{"type" => "Identifier", "name" => name}
  defp obj_id(name), do: %{"type" => "Identifier", "name" => name}
  defp expr_stmt(e), do: %{"type" => "ExpressionStatement", "expression" => e}
  defp call_expr(callee, args), do: %{"type" => "CallExpression", "callee" => callee, "arguments" => args}
  # the defineProperty key argument: a string literal for a plain name, else the computed expression.
  defp target_key_expr(_target, %{"name" => n} = _key, false), do: %{"type" => "Literal", "value" => n}
  defp target_key_expr(_target, key, true), do: key
  defp target_key_expr(_target, key, false), do: key

  defp for_init(%{"type" => "VariableDeclaration"} = d, scope), do: stmt(d, scope)
  defp for_init(e, scope), do: {expr(e, scope), scope}

  # for (var x of iterable) / for (var k in obj): iterate items/keys, binding the loop var each round, and
  # threading body-mutated vars through the recursion (like ForStatement). The loop var is bound from the
  # item, not threaded.
  defp for_each(n, kind, scope) do
    # a PATTERN head (`for (const [i, em] of xs.entries())`) binds the item to __ggforvar and destructures it
    # at the top of every iteration via the shared pattern machinery.
    {vn, pat} =
      case n["left"] do
        %{"type" => "VariableDeclaration", "declarations" => [%{"id" => %{"name" => v}} | _]} -> {v, nil}
        %{"type" => "VariableDeclaration", "declarations" => [%{"id" => p} | _]} -> {"__ggforvar", p}
        %{"type" => "Identifier", "name" => v} -> {v, nil}
        %{"type" => t} = p when t in ["ArrayPattern", "ObjectPattern"] -> {"__ggforvar", p}
        _ -> {"__ggforvar", nil}
      end

    label = scope[:pending_label]
    base = Map.put(scope, :pending_label, nil)
    patnames = if pat, do: pattern_names(pat), else: []
    s1 = %{base | locals: Enum.reduce([vn | patnames], base.locals, &MapSet.put(&2, &1))}
    itemsfn = if kind == :of, do: :iter, else: :enum_keys
    itemsq = quote(do: unquote(@runtime).unquote(itemsfn)(unquote(expr(n["right"], base))))
    loop = Macro.var(:gg_feach, __MODULE__)

    destrq = if pat, do: destr_targets(pat, quote(do: unquote(lvar(vn))), s1), else: []

    if loop_uses_control?(n["body"]) do
      tag = System.unique_integer([:positive])
      sc = Map.put(s1, :loops, [{label, tag, :loop} | (scope[:loops] || [])])
      {bodyq, _} = stmt(n["body"], sc)

      q =
        quote do
          unquote(loop) = fn
            me, [__ggitem | __ggrest] ->
              unquote(lvar(vn)) = __ggitem
              unquote_splicing(destrq)

              try do
                unquote(bodyq)
              catch
                :throw, {:gg_continue, unquote(tag)} -> :ok
              end

              me.(me, __ggrest)

            _me, [] ->
              :ok
          end

          try do
            unquote(loop).(unquote(loop), unquote(itemsq))
          catch
            :throw, {:gg_break, unquote(tag)} -> :ok
          end
        end

      {q, scope}
    else
      mutated = (assigned_names(n["body"]) -- [vn]) |> Enum.uniq() |> not_boxed(base)
      inits = for v <- mutated, not MapSet.member?(base.locals, v), do: quote(do: unquote(lvar(v)) = :undefined)
      state = {:{}, [], Enum.map(mutated, &lvar/1)}
      {bodyq, _} = stmt(n["body"], s1)

      q =
        quote do
          unquote_splicing(inits)

          unquote(loop) = fn
            me, [__ggitem | __ggrest], unquote(state) ->
              unquote(lvar(vn)) = __ggitem
              unquote_splicing(destrq)
              unquote(bodyq)
              me.(me, __ggrest, unquote(state))

            _me, [], unquote(state) ->
              unquote(state)
          end

          unquote(state) = unquote(loop).(unquote(loop), unquote(itemsq), unquote(state))
        end

      {q, scope}
    end
  end

  # ── expressions ──
  # regex literal /pattern/flags — acorn attaches a "regex" map; compile through the confined regex capability.
  defp expr(%{"type" => "Literal", "regex" => %{"pattern" => p, "flags" => f}}, _),
    do: quote(do: unquote(@runtime).regex(unquote(p), unquote(f)))

  defp expr(%{"type" => "Literal", "value" => v}, _), do: lit(v)

  # a class EXPRESSION (`X = class extends Y {…}`, esbuild's minified class form) is a first-class value: run
  # the same desugar as a class declaration under a unique greg name, then evaluate TO the constructor. The
  # name (real or synthetic) is bound in a local scope so the class's own methods + the return resolve it.
  defp expr(%{"type" => "ClassExpression"} = n, scope) do
    name = (n["id"] && n["id"]["name"]) || "__ggclass$#{n["start"]}"
    key = fnkey(name, n)
    scope2 = greg_hoist(scope, name, key)
    ncls = %{n | "type" => "ClassDeclaration", "id" => %{"type" => "Identifier", "name" => name, "start" => n["start"]}}
    {setupq, _} = stmt(ncls, scope2)
    quote do
      unquote(block(setupq))
      unquote(@runtime).greg_get(unquote(key))
    end
  end

  # new RegExp(source, flags) — the only constructor wired (classes/prototypes are a later phase).
  defp expr(%{"type" => "NewExpression", "callee" => %{"type" => "Identifier", "name" => "RegExp"}} = n, scope) do
    args = n["arguments"] || []
    src = if args != [], do: expr(Enum.at(args, 0), scope), else: ""
    flags = if length(args) > 1, do: expr(Enum.at(args, 1), scope), else: ""
    quote(do: unquote(@runtime).regex(unquote(src), unquote(flags)))
  end

  # generic `new F(args)`: construct via the Runtime (fresh `this` cell, invoke the constructor, return the
  # instance). Handles new Lexer(opts), new Error(msg), etc.
  defp expr(%{"type" => "NewExpression"} = n, scope) do
    argq = args_of(n["arguments"], scope)
    quote(do: unquote(@runtime).construct(unquote(expr(n["callee"], scope)), unquote(argq)))
  end
  defp expr(%{"type" => "Identifier", "name" => n}, scope), do: ident(n, scope)
  defp expr(%{"type" => "ThisExpression"}, _scope), do: Macro.var(:__ggthis, __MODULE__)

  # An object literal with a METHOD (function-valued property) is a stateful INSTANCE → a mutable cell (so
  # this.x=v and aliasing work). A pure data bag → an immutable {keys,map} term (GC'd, the H1 win). Spread
  # objects stay immutable (spread builds a fresh object).
  defp expr(%{"type" => "ObjectExpression", "properties" => props}, scope) do
    # JS objects are REFERENCE types: aliasing + shared mutation is load-bearing (marked builds its grammar
    # once and mutates shared sub-objects that were copied by reference via Object.assign). So every object
    # literal is a mutable cell. Per-run process isolation reclaims the cell table when the run process dies.
    has_spread = Enum.any?(props, &(&1["type"] == "SpreadElement"))

    if not has_spread do
      pairs =
        props
        |> Enum.reject(&(&1["kind"] == "set"))
        |> Enum.map(fn p ->
          kq = if p["computed"], do: expr(p["key"], scope), else: key_of(p["key"])
          # accessor property `{ get x() {…} }` — a getter MARKER, invoked on read by cell_oget.
          if p["kind"] == "get",
            do: quote(do: {unquote(kq), {:getter, unquote(expr(p["value"], scope))}}),
            else: quote(do: {unquote(kq), unquote(expr(p["value"], scope))})
        end)

      quote(do: unquote(@runtime).cell_new(unquote(pairs)))
    else
      # spread: start from an empty cell and merge/set each property in order.
      Enum.reduce(props, quote(do: unquote(@runtime).cell_new([])), fn p, acc ->
        case p do
          %{"type" => "SpreadElement", "argument" => a} ->
            quote(do: unquote(@runtime).omerge(unquote(acc), unquote(expr(a, scope))))

          %{"kind" => "get", "key" => k, "value" => v} = pg ->
            kq = if pg["computed"], do: expr(k, scope), else: key_of(k)
            quote(do: unquote(@runtime).oput(unquote(acc), unquote(kq), {:getter, unquote(expr(v, scope))}))

          %{"kind" => "set"} ->
            acc

          %{"key" => k, "value" => v, "computed" => computed} ->
            kq = if computed, do: expr(k, scope), else: key_of(k)
            quote(do: unquote(@runtime).oput(unquote(acc), unquote(kq), unquote(expr(v, scope))))
        end
      end)
    end
  end

  defp expr(%{"type" => "TemplateLiteral", "quasis" => qs, "expressions" => es}, scope) do
    quasis = Enum.map(qs, fn q -> (q["value"] && q["value"]["cooked"]) || "" end)
    exprs = Enum.map(es, &expr(&1, scope))
    # interleave q0, e0, q1, e1, …, qn  then string-concat via binop(:+)
    parts = interleave(quasis, exprs)
    Enum.reduce(parts, "", fn part, acc -> quote(do: unquote(@runtime).binop(:+, unquote(acc), unquote(part))) end)
  end

  defp expr(%{"type" => "ArrayExpression", "elements" => els}, scope) do
    if Enum.any?(els, &(&1 && &1["type"] == "SpreadElement")) do
      parts =
        Enum.map(els, fn
          %{"type" => "SpreadElement", "argument" => a} -> quote(do: {:spread, unquote(expr(a, scope))})
          nil -> quote(do: {:one, :undefined})
          e -> quote(do: {:one, unquote(expr(e, scope))})
        end)

      quote(do: unquote(@runtime).aspread(unquote(parts)))
    else
      elq = Enum.map(els, fn e -> if e, do: expr(e, scope), else: :undefined end)
      quote(do: unquote(@runtime).alit(unquote(elq)))
    end
  end

  # `a?.b()` / `a?.[k]` parse as ChainExpression wrapping the call/member (whose own `optional` flags
  # short-circuit) — unwrap, or the catch-all would silently lower the whole chain to undefined.
  defp expr(%{"type" => "ChainExpression", "expression" => e}, scope), do: expr(e, scope)

  # method call `recv.name(args)` → confined Runtime.method dispatch. A mutating method (push/pop/…) returns
  # `{:mut, new_recv, result}`; when the receiver is an identifier we rebind it (JS in-place mutation).
  defp expr(%{"type" => "CallExpression", "callee" => %{"type" => "MemberExpression", "computed" => false} = m} = c, scope) do
    name = key_of(m["property"])
    argq = args_of(c["arguments"], scope)

    if m["optional"] || c["optional"] do
      # optional call: `a?.m()` short-circuits on a nullish RECEIVER; `a.m?.()` additionally short-circuits
      # when the property itself is missing (the ?. guards the function, not the receiver).
      recvq = expr(m["object"], scope)
      base = Macro.var(:__ggoptrecv, __MODULE__)
      fn_guard = if c["optional"], do: quote(do: unquote(@runtime).optcall_missing?(unquote(base), unquote(name))), else: false

      quote do
        unquote(base) = unquote(recvq)

        if unquote(base) in [:undefined, :null] do
          :undefined
        else
          if unquote(fn_guard) do
            :undefined
          else
            case unquote(@runtime).method(unquote(base), unquote(name), unquote(argq)) do
              {:mut, _, r} -> r
              v -> v
            end
          end
        end
      end
    else
    case m["object"] do
      # identifier receiver: rebind it if the method mutated (a.push(x)). A BOXED receiver writes through its
      # box — rebinding would clobber the box HANDLE with the raw value and orphan every other closure's view.
      %{"type" => "Identifier", "name" => rn} ->
        if scope[:boxed] && MapSet.member?(scope.boxed, rn) do
          quote do
            case unquote(@runtime).method(unquote(ident(rn, scope)), unquote(name), unquote(argq)) do
              {:mut, nr, r} ->
                unquote(@runtime).box_set(unquote(lvar(rn)), nr)
                r

              v ->
                v
            end
          end
        else
          res = Macro.var(:__ggres, __MODULE__)

          quote do
            {unquote(lvar(rn)), unquote(res)} =
              case unquote(@runtime).method(unquote(ident(rn, scope)), unquote(name), unquote(argq)) do
                {:mut, nr, r} -> {nr, r}
                v -> {unquote(ident(rn, scope)), v}
              end

            unquote(res)
          end
        end

      # member receiver (this.tokens.push(x), o.arr.push(x)): write the mutated value back onto base[key] so
      # the container sees it. On a cell base this is an in-place mutation (persists); on an immutable base it
      # updates a fresh copy (v0 limit for deeply-nested immutable mutation).
      %{"type" => "MemberExpression"} = recv_m ->
        base = Macro.var(:__ggbase, __MODULE__)
        res = Macro.var(:__ggres, __MODULE__)
        rk = if recv_m["computed"], do: expr(recv_m["property"], scope), else: key_of(recv_m["property"])

        quote do
          unquote(base) = unquote(expr(recv_m["object"], scope))

          unquote(res) =
            case unquote(@runtime).method(unquote(@runtime).oget(unquote(base), unquote(rk)), unquote(name), unquote(argq)) do
              {:mut, nr, r} ->
                unquote(@runtime).oput_idx(unquote(base), unquote(rk), nr)
                r

              v ->
                v
            end

          unquote(res)
        end

      other ->
        quote do
          case unquote(@runtime).method(unquote(expr(other, scope)), unquote(name), unquote(argq)) do
            {:mut, _, r} -> r
            v -> v
          end
        end
    end
    end
  end

  defp expr(%{"type" => "MemberExpression"} = m, scope) do
    oq = expr(m["object"], scope)
    kq = if m["computed"], do: expr(m["property"], scope), else: key_of(m["property"])

    if m["optional"] do
      base = Macro.var(:__ggoptbase, __MODULE__)

      quote do
        unquote(base) = unquote(oq)
        if unquote(base) in [:undefined, :null], do: :undefined, else: unquote(@runtime).oget(unquote(base), unquote(kq))
      end
    else
      quote(do: unquote(@runtime).oget(unquote(oq), unquote(kq)))
    end
  end

  # logical assignment (&&=, ||=, ??=): x op= y  ==>  x = x <logical> y. Must lower as a LogicalExpression
  # (short-circuit / nullish), NOT a BinaryExpression — `&&`/`||`/`??` are not binary operators.
  defp expr(%{"type" => "AssignmentExpression", "operator" => op, "left" => l, "right" => r} = n, scope)
       when op in ["&&=", "||=", "??="] do
    logop = String.trim_trailing(op, "=")
    expr(%{n | "operator" => "=", "right" => %{"type" => "LogicalExpression", "operator" => logop, "left" => l, "right" => r}}, scope)
  end

  # compound assignment (+=, -=, *=, …): x op= y  ==>  x = x op y (desugar to the "=" case).
  defp expr(%{"type" => "AssignmentExpression", "operator" => op, "left" => l, "right" => r} = n, scope)
       when op != "=" do
    binop = String.trim_trailing(op, "=")
    expr(%{n | "operator" => "=", "right" => %{"type" => "BinaryExpression", "operator" => binop, "left" => l, "right" => r}}, scope)
  end

  # assignment: `id = v` rebinds the local; `id.prop = v` / `id[k] = v` rebinds id to the updated object.
  defp expr(%{"type" => "AssignmentExpression", "operator" => "=", "left" => l, "right" => r}, scope) do
    rq = expr(r, scope)

    case l do
      %{"type" => "Identifier", "name" => n} ->
        if scope[:boxed] && MapSet.member?(scope.boxed, n),
          do: quote(do: unquote(@runtime).box_set(unquote(lvar(n)), unquote(rq))),
          else: quote(do: unquote(lvar(n)) = unquote(rq))

      %{"type" => "MemberExpression"} = m ->
        # JS assignment evaluates to the ASSIGNED VALUE. `assign_to` rebuilds the member chain and rebinds the
        # root identifier, so DEEP assignments (w.emStrong.rDelimAst = …) propagate even on immutable nested
        # objects — marked's grammar building relies on this.
        v = Macro.var(:__ggav, __MODULE__)

        quote do
          unquote(v) = unquote(rq)
          unquote(assign_to(m, v, scope))
          unquote(v)
        end

      # destructuring ASSIGNMENT (not declaration): `[a, b] = x`, `({a, b} = o)` — minified rollup uses these.
      # Reuse the declaration destructuring machinery; the expression evaluates to the whole RHS value.
      %{"type" => t} = pat when t in ["ArrayPattern", "ObjectPattern"] ->
        v = Macro.var(:__ggav, __MODULE__)
        {:__block__, [], [quote(do: unquote(v) = unquote(rq))] ++ destr_targets(pat, v, scope) ++ [v]}
    end
  end

  # assign `valq` to a target (Identifier or MemberExpression), rebuilding the chain up to the root identifier.
  # A boxed root is written through its box (never rebound — that would destroy the shared box).
  defp assign_to(%{"type" => "Identifier", "name" => n}, valq, scope) do
    if scope[:boxed] && MapSet.member?(scope.boxed, n),
      do: quote(do: unquote(@runtime).box_set(unquote(lvar(n)), unquote(valq))),
      else: quote(do: unquote(lvar(n)) = unquote(valq))
  end

  defp assign_to(%{"type" => "MemberExpression"} = m, valq, scope) do
    kq = if m["computed"], do: expr(m["property"], scope), else: key_of(m["property"])
    new_base = quote(do: unquote(@runtime).oput_idx(unquote(expr(m["object"], scope)), unquote(kq), unquote(valq)))
    assign_to(m["object"], new_base, scope)
  end

  # a base that is neither an Identifier nor a MemberExpression (ThisExpression, a call result, …) is a mutable
  # reference (cell/globalobj): the property write in `valq` already mutated it IN PLACE, so just evaluate valq
  # — there is nothing to rebind. (Previously this wrote a spurious `base["0"] = base` on every `this.x = v`.)
  defp assign_to(_other, valq, _scope), do: valq

  defp expr(%{"type" => "BinaryExpression", "operator" => op} = n, scope) do
    quote(do: unquote(@runtime).binop(unquote(binop_atom(op)), unquote(expr(n["left"], scope)), unquote(expr(n["right"], scope))))
  end

  # `a && b` / `a || b`: the RIGHT side runs conditionally and may ASSIGN variables (minified short-circuit
  # `cond && (x = …)`). Elixir `if` doesn't export inner bindings, so thread the right side's mutated vars out
  # (like IfStatement) — otherwise the assignment is silently lost.
  defp expr(%{"type" => "LogicalExpression", "operator" => op} = n, scope) do
    lq = expr(n["left"], scope)
    rq = expr(n["right"], scope)
    mutated = assigned_names(n["right"]) |> Enum.uniq() |> not_boxed(scope)

    cond do
      mutated == [] and op == "&&" -> quote(do: (fn v -> if unquote(@runtime).truthy(v), do: unquote(rq), else: v end).(unquote(lq)))
      mutated == [] and op == "||" -> quote(do: (fn v -> if unquote(@runtime).truthy(v), do: v, else: unquote(rq) end).(unquote(lq)))
      # `a ?? b`: b only when a is null/undefined (nullish), NOT merely falsy.
      mutated == [] and op == "??" -> quote(do: (fn v -> if unquote(@runtime).is_nullish(v), do: unquote(rq), else: v end).(unquote(lq)))
      op == "??" -> cond_thread(quote(do: unquote(@runtime).is_nullish(__gglv)), rq, quote(do: __gglv), mutated, scope, quote(do: __gglv = unquote(lq)), false)
      true -> cond_thread(quote(do: unquote(@runtime).truthy(__gglv)), rq, quote(do: __gglv), mutated, scope, quote(do: __gglv = unquote(lq)), op == "||")
    end
  end

  # thread `mutated` vars out of a conditional whose value is `cons_q`(true)/`alt_q`(false). `pre` runs first
  # (binds the discriminant); `swap` flips branches (for `||`, where the "run right" branch is the false one).
  defp cond_thread(test_q, cons_q, alt_q, mutated, scope, pre, swap) do
    statevars = Enum.map(mutated, &lvar/1)
    inits = for v <- mutated, not MapSet.member?(scope.locals, v), do: quote(do: unquote(lvar(v)) = :undefined)
    res = Macro.var(:__ggcv, __MODULE__)
    bv = Macro.var(:__ggbv, __MODULE__)
    tuple = {:{}, [], [res | statevars]}
    # a branch runs its expression (binding mutated vars via block sequencing), THEN captures the state tuple —
    # a tuple literal does NOT thread bindings, so the assignment must be sequenced before the capture.
    branch = fn q -> quote(do: (unquote(bv) = unquote(q); unquote({:{}, [], [bv | statevars]}))) end
    {tb, fb} = if swap, do: {branch.(alt_q), branch.(cons_q)}, else: {branch.(cons_q), branch.(alt_q)}

    quote do
      unquote_splicing(inits)
      unquote(pre)
      unquote(tuple) = if unquote(test_q), do: unquote(tb), else: unquote(fb)
      unquote(res)
    end
  end

  # comma operator `a, b, c` — evaluate all, value is the last. (Minified code uses these everywhere, incl.
  # marked's whole export line `r.marked=I, r.parse=H, …`.)
  defp expr(%{"type" => "SequenceExpression", "expressions" => es}, scope) do
    {:__block__, [], Enum.map(es, &expr(&1, scope))}
  end

  # ternary `test ? a : b` — either branch may ASSIGN variables (`p ? (c=x) : (c=y)`); thread them out.
  defp expr(%{"type" => "ConditionalExpression"} = n, scope) do
    consq = expr(n["consequent"], scope)
    altq = expr(n["alternate"], scope)
    mutated = (assigned_names(n["consequent"]) ++ assigned_names(n["alternate"])) |> Enum.uniq() |> not_boxed(scope)

    if mutated == [] do
      quote(do: if(unquote(@runtime).truthy(unquote(expr(n["test"], scope))), do: unquote(consq), else: unquote(altq)))
    else
      cond_thread(quote(do: unquote(@runtime).truthy(unquote(expr(n["test"], scope)))), consq, altq, mutated, scope, quote(do: nil), false)
    end
  end

  defp expr(%{"type" => "UnaryExpression", "operator" => "typeof", "argument" => a}, scope),
    do: quote(do: unquote(@runtime).typeof(unquote(expr(a, scope))))

  defp expr(%{"type" => "UnaryExpression", "operator" => "!", "argument" => a}, scope),
    do: quote(do: not unquote(@runtime).truthy(unquote(expr(a, scope))))

  defp expr(%{"type" => "UnaryExpression", "operator" => "-", "argument" => a}, scope),
    do: quote(do: unquote(@runtime).binop(:-, 0.0, unquote(expr(a, scope))))

  # unary `+x` → ToNumber(x) (marked's ordered-list `start = +bullet.slice(0,-1)`); `~x` → bitwise NOT; `void x`.
  defp expr(%{"type" => "UnaryExpression", "operator" => "+", "argument" => a}, scope),
    do: quote(do: unquote(@runtime).to_number(unquote(expr(a, scope))))

  defp expr(%{"type" => "UnaryExpression", "operator" => "~", "argument" => a}, scope),
    do: quote(do: unquote(@runtime).binop(:bxor, -1.0, unquote(expr(a, scope))))

  defp expr(%{"type" => "UnaryExpression", "operator" => "void", "argument" => a}, scope),
    do: quote(do: (unquote(expr(a, scope)); :undefined))

  # `delete o.k` / `delete o[k]` — remove the property (Reflect.deleteProperty, same route as Walk); always true.
  defp expr(%{"type" => "UnaryExpression", "operator" => "delete", "argument" => %{"type" => "MemberExpression"} = m}, scope) do
    kq = if m["computed"], do: expr(m["property"], scope), else: key_of(m["property"])

    quote do
      unquote(@runtime).method({:global, "Reflect"}, "deleteProperty", [unquote(expr(m["object"], scope)), unquote(kq)])
      true
    end
  end

  defp expr(%{"type" => "UnaryExpression", "operator" => "delete"}, _scope), do: true

  # ++ / -- on a member: this.pos++ / o.n-- — read, +/-1, write back (in-place on a cell). The expression
  # value honors prefix/postfix: `buffer[position++]` reads at the OLD position (rollup's AST-buffer walk).
  defp expr(%{"type" => "UpdateExpression", "operator" => op, "argument" => %{"type" => "MemberExpression"} = m} = u, scope) do
    delta = if op == "++", do: 1.0, else: -1.0
    kq = if m["computed"], do: expr(m["property"], scope), else: key_of(m["property"])
    oldv = Macro.var(:__ggupdo, __MODULE__)
    newv = Macro.var(:__ggupdn, __MODULE__)
    result = if u["prefix"], do: newv, else: oldv

    case m["object"] do
      %{"type" => "Identifier", "name" => bn} ->
        # a BOXED base writes through its box; rebinding would clobber the handle (see method-call rebind).
        writeq =
          if scope[:boxed] && MapSet.member?(scope.boxed, bn),
            do: quote(do: unquote(@runtime).box_set(unquote(lvar(bn)), unquote(@runtime).oput_idx(unquote(ident(bn, scope)), unquote(kq), unquote(newv)))),
            else: quote(do: unquote(lvar(bn)) = unquote(@runtime).oput_idx(unquote(ident(bn, scope)), unquote(kq), unquote(newv)))

        quote do
          unquote(oldv) = unquote(@runtime).oget(unquote(ident(bn, scope)), unquote(kq))
          unquote(newv) = unquote(@runtime).binop(:+, unquote(oldv), unquote(delta))
          unquote(writeq)
          unquote(result)
        end

      base ->
        b = Macro.var(:__ggub, __MODULE__)

        quote do
          unquote(b) = unquote(expr(base, scope))
          unquote(oldv) = unquote(@runtime).oget(unquote(b), unquote(kq))
          unquote(newv) = unquote(@runtime).binop(:+, unquote(oldv), unquote(delta))
          unquote(@runtime).oput_idx(unquote(b), unquote(kq), unquote(newv))
          unquote(result)
        end
    end
  end

  # i++ / i-- / ++i / --i on an identifier: rebind (or box_set if boxed). Postfix evaluates to the OLD value.
  defp expr(%{"type" => "UpdateExpression", "operator" => op, "argument" => %{"name" => n}} = u, scope) do
    delta = if op == "++", do: 1.0, else: -1.0
    oldv = Macro.var(:__ggupdo, __MODULE__)

    setq =
      if scope[:boxed] && MapSet.member?(scope.boxed, n),
        do: quote(do: unquote(@runtime).box_set(unquote(lvar(n)), unquote(@runtime).binop(:+, unquote(oldv), unquote(delta)))),
        else: quote(do: unquote(lvar(n)) = unquote(@runtime).binop(:+, unquote(oldv), unquote(delta)))

    if u["prefix"] do
      quote do
        unquote(oldv) = unquote(ident(n, scope))
        unquote(setq)
      end
    else
      quote do
        unquote(oldv) = unquote(ident(n, scope))
        unquote(setq)
        unquote(oldv)
      end
    end
  end

  defp expr(%{"type" => "CallExpression"} = c, scope) do
    argq = args_of(c["arguments"], scope)

    if c["optional"] do
      # `f?.()` — a nullish function value short-circuits to undefined (args unevaluated).
      f = Macro.var(:__ggoptfn, __MODULE__)

      quote do
        unquote(f) = unquote(expr(c["callee"], scope))
        if unquote(@runtime).is_nullish(unquote(f)), do: :undefined, else: unquote(@runtime).call(unquote(f), unquote(argq))
      end
    else
      quote(do: unquote(@runtime).call(unquote(expr(c["callee"], scope)), unquote(argq)))
    end
  end

  defp expr(%{"type" => t} = f, scope) when t in ["FunctionExpression", "ArrowFunctionExpression"],
    do: func(f["params"], f["body"], scope, f["async"] == true, t == "ArrowFunctionExpression", f["generator"] == true)

  # yield collects into the current eager-generator frame (see the gen? branch of func/6).
  defp expr(%{"type" => "YieldExpression"} = y, scope) do
    aq = if y["argument"], do: expr(y["argument"], scope), else: :undefined

    if y["delegate"],
      do: quote(do: unquote(@runtime).gen_yield_star(unquote(aq))),
      else: quote(do: unquote(@runtime).gen_yield(unquote(aq)))
  end

  # `await x`: in the eager/synchronous promise model, unwrap a settled promise to its value (rejected → throw,
  # caught by the enclosing async fn's promise_from → rejected promise). Non-promises pass through.
  defp expr(%{"type" => "AwaitExpression", "argument" => a}, scope),
    do: quote(do: unquote(@runtime).await_(unquote(expr(a, scope))))

  defp expr(nil, _), do: :undefined
  defp expr(_other, _scope), do: :undefined

  # ── functions: real Elixir closures behind closure/1; returns via throw/catch ──
  # `self_name` (for named declarations/expressions) is bound INSIDE the body to a self-passing closure, so a
  # named function can recurse — Elixir anonymous funs can't reference their own binding name, so we use the
  # Y-combinator form `rec = fn me, args -> ...me... end` and expose `gg_<name>` as `closure(fn a-> me.(me,a) end)`.
  # a guest function as a directly-held closure with the (this, args) ABI. Recursion/forward/mutual refs are
  # handled by the late-bound function registry (a function name resolves to Runtime.greg_get at each use),
  # so no Y-combinator is needed here. `this` binds the method receiver; ThisExpression lowers to __ggthis.
  defp func(params, body, scope, async? \\ false, arrow? \\ false, gen? \\ false) do
    names = Enum.flat_map(params, &pattern_names/1)
    argvar = Macro.var(:__ggargs, __MODULE__)
    # a regular function binds `this` (__ggthis) from its call-time receiver; an ARROW inherits `this`
    # lexically, so it must NOT rebind __ggthis — use a throwaway param and let the body's ThisExpression
    # (which lowers to __ggthis) capture the enclosing binding (the program binds __ggthis at the top).
    thisvar = if arrow?, do: Macro.var(:__ggthis_lex_ignored, __MODULE__), else: Macro.var(:__ggthis, __MODULE__)
    # hoist this function's `var` declarations (JS function scope), pre-bound to :undefined.
    bodyvars = collect_vars(body) |> Enum.uniq() |> Enum.reject(&(&1 in names))
    uses_args? = "arguments" in all_idents(body)
    inner0 = Enum.reduce(names ++ bodyvars, scope.locals, &MapSet.put(&2, &1))
    inner1 = if uses_args?, do: MapSet.put(inner0, "arguments"), else: inner0
    # a function declared directly in this body binds to the registry (greg), shadowing any inherited local of
    # the same name (babel class IIFEs: `var K = (function(){ function K(){} return K })()`).
    fndecls = fndecl_names(body)
    inner = MapSet.difference(inner1, fndecls)

    # a param/var captured by a nested function AND mutated is BOXED so the closures share the mutation.
    boxed = boxed_set(names ++ bodyvars, body)

    hoistq =
      Enum.map(bodyvars, fn v ->
        if MapSet.member?(boxed, v),
          do: quote(do: unquote(lvar(v)) = unquote(@runtime).box(:undefined)),
          else: quote(do: unquote(lvar(v)) = :undefined)
      end)

    argbind =
      if uses_args?,
        do: [quote(do: unquote(lvar("arguments")) = unquote(@runtime).avec(unquote(argvar)))],
        else: []

    # a param/var here SHADOWS an outer boxed var of the same name — the inner one is a distinct variable, so
    # drop shadowed names from the inherited boxed set before unioning this scope's boxed vars.
    shadow = MapSet.union(MapSet.new(names ++ bodyvars), fndecls)
    inherited = MapSet.difference(scope[:boxed] || MapSet.new(), shadow)
    bscope = %{scope | locals: inner, boxed: MapSet.difference(MapSet.union(inherited, boxed), fndecls)}

    # a boxed PARAM-bound name needs its box pre-created before the (possibly destructuring) bind writes it.
    param_box_inits =
      for v <- Enum.uniq(names), MapSet.member?(bscope.boxed, v),
        do: quote(do: unquote(lvar(v)) = unquote(@runtime).box(:undefined))

    # each param — Identifier / default (AssignmentPattern) / {…}/[…] destructuring / ...rest — binds from its
    # positional arg (or the tail array for a rest param) via the shared pattern machinery.
    binds =
      params
      |> Enum.with_index()
      |> Enum.flat_map(fn {p, i} ->
        case p do
          %{"type" => "RestElement", "argument" => a} ->
            destr_targets(a, quote(do: unquote(@runtime).args_rest(unquote(argvar), unquote(i))), bscope)

          _ ->
            destr_targets(p, quote(do: unquote(@runtime).arg(unquote(argvar), unquote(i))), bscope)
        end
      end)

    # #6 direct-return optimization: if returns appear ONLY at the body's tail (or not at all), compile
    # without the try/catch/throw machinery — the block's value IS the result. Avoids one throw+catch per call
    # (the dominant per-call cost; ~millions for recursive marked code). Functions with early/nested returns
    # keep the throw path.
    stmts_list =
      case body do
        %{"type" => "BlockStatement", "body" => b} -> b
        e -> [%{"type" => "ReturnStatement", "argument" => e}]
      end

    nreturns = count_returns(stmts_list)
    last = List.last(stmts_list)
    tail_return? = nreturns == 0 or (nreturns == 1 and last && last["type"] == "ReturnStatement")
    prelude = hoistq ++ param_box_inits ++ binds ++ argbind

    # the Erlang compiler is strongly SUPERLINEAR in single-function size (878KB body = 109s, 94KB = 0.6s), so
    # a huge plain function body EXPLODES into sibling module functions: every local is boxed (per-invocation,
    # so recursion stays correct), the handles travel as one tuple, and gg_return throws cross the chunk calls.
    explode? =
      not async? and not gen? and Process.get(:gg_lower_defs) != nil and
        match?(%{"type" => "BlockStatement"}, body) and
        is_integer(body["start"]) and is_integer(body["end"]) and
        body["end"] - body["start"] > @explode_min_bytes

    cond do
      explode? ->
        explode_func(stmts_list, names, bodyvars, fndecls, uses_args?, thisvar, argvar, bscope, body["start"], params)
      # a GENERATOR runs its body to completion eagerly, collecting yields into a frame (gen_begin/gen_end) and
      # returning the collected array — same eager model as Walk; an early `return` stops collection, its value
      # is discarded (for-of never sees it).
      gen? ->
        {bq, _} = stmts(stmts_list, bscope)

        quote do
          unquote(@runtime).closure(fn unquote(thisvar), unquote(argvar) ->
            unquote_splicing(prelude)
            unquote(@runtime).gen_begin()

            try do
              unquote_splicing(bq ++ [:undefined])
            catch
              :throw, {:gg_return, _} -> :undefined
            end

            unquote(@runtime).gen_end()
          end)
        end

      # an ASYNC function ALWAYS returns a promise: run the body inside promise_from, which resolves with the
      # result (awaits settle synchronously in the eager model) or rejects on a thrown guest error/rejected await.
      async? ->
        {bq, _} = stmts(stmts_list, bscope)
        quote do
          unquote(@runtime).closure(fn unquote(thisvar), unquote(argvar) ->
            unquote_splicing(prelude)
            unquote(@runtime).promise_from(fn ->
              try do
                unquote_splicing(bq ++ [:undefined])
              catch
                :throw, {:gg_return, v} -> v
              end
            end)
          end)
        end

      # #6 direct-return optimization: returns only at the tail → the block's value IS the result, no try/catch.
      tail_return? ->
        {value_stmts, _} =
          if last && last["type"] == "ReturnStatement" do
            {init, sc} = stmts(Enum.drop(stmts_list, -1), bscope)
            {init ++ [expr(last["argument"] || %{"type" => "Literal", "value" => nil}, sc)], sc}
          else
            {sq, sc} = stmts(stmts_list, bscope)
            {sq ++ [:undefined], sc}
          end

        quote do
          unquote(@runtime).closure(fn unquote(thisvar), unquote(argvar) ->
            unquote_splicing(prelude ++ value_stmts)
          end)
        end

      true ->
        {bq, _} = stmts(stmts_list, bscope)

        quote do
          unquote(@runtime).closure(fn unquote(thisvar), unquote(argvar) ->
            try do
              unquote_splicing(prelude ++ bq)
              :undefined
            catch
              :throw, {:gg_return, v} -> v
            end
          end)
        end
    end
  end

  # ── function-body EXPLOSION (compile-time wall) ────────────────────────────────────────────────────────
  # A huge plain function body becomes: per-invocation boxes for EVERY local, an env tuple of the handles,
  # and N sibling module functions each running a byte-bounded slice of the statements. `return` inside a
  # slice throws gg_return, which unwinds through the slice call into the main closure's catch. Only active
  # under module_quoted (the :gg_lower_defs accumulator collects the sibling defs).
  defp explode_func(stmts_list, names, bodyvars, fndecls, uses_args?, thisvar, argvar, bscope, fnid, params) do
    own =
      (Enum.uniq(names ++ bodyvars) |> Enum.reject(&MapSet.member?(fndecls, &1))) ++
        if(uses_args?, do: ["arguments"], else: [])

    # FREE boxed vars this body mentions (outer function/program locals): a chunk def has no lexical capture,
    # so their handles travel in the env tuple alongside the body's own boxes. Anything a nested function
    # captures is boxed by boxed_set, so free-and-referenced ⊆ boxed holds.
    free =
      bscope.boxed
      |> MapSet.difference(MapSet.new(own))
      |> MapSet.intersection(MapSet.new(all_idents(stmts_list)))
      |> Enum.sort()

    locals = own ++ free
    exscope = %{bscope | boxed: MapSet.union(bscope.boxed, MapSet.new(own))}

    box_inits = Enum.map(own, fn v -> quote(do: unquote(lvar(v)) = unquote(@runtime).box(:undefined)) end)

    binds =
      params
      |> Enum.with_index()
      |> Enum.flat_map(fn {p, i} ->
        case p do
          %{"type" => "RestElement", "argument" => a} ->
            destr_targets(a, quote(do: unquote(@runtime).args_rest(unquote(argvar), unquote(i))), exscope)

          _ ->
            destr_targets(p, quote(do: unquote(@runtime).arg(unquote(argvar), unquote(i))), exscope)
        end
      end)

    argbind =
      if uses_args?,
        do: [quote(do: unquote(@runtime).box_set(unquote(lvar("arguments")), unquote(@runtime).avec(unquote(argvar))))],
        else: []

    # global hoist + fn-decls-install-first over the WHOLE body, then byte-bounded slices.
    hoisted = Enum.reduce(stmts_list, exscope, &hoist/2)
    {fnnodes, rest} = Enum.split_with(stmts_list, &(is_map(&1) and &1["type"] == "FunctionDeclaration" and &1["id"]))
    chunks = chunk_by_bytes(fnnodes ++ rest, @explode_piece_bytes)
    thisq = Macro.var(:__ggthis, __MODULE__)

    {calls, _} =
      chunks
      |> Enum.with_index()
      |> Enum.map_reduce(hoisted, fn {nodes, i}, sc ->
        {qs, sc2} = stmts(nodes, sc)
        name = String.to_atom("__gg_f#{fnid}_c#{i}")
        mentioned = MapSet.new(all_idents(nodes))

        pat_elems =
          [thisq] ++
            Enum.map(locals, fn v ->
              if MapSet.member?(mentioned, v), do: lvar(v), else: Macro.var(:_, __MODULE__)
            end)

        d =
          quote do
            def unquote(name)({unquote_splicing(pat_elems)}) do
              _ = unquote(thisq)
              unquote_splicing(qs)
              :ok
            end
          end

        Process.put(:gg_lower_defs, [{name, d} | Process.get(:gg_lower_defs)])
        envq = {:{}, [], [thisq | Enum.map(locals, &lvar/1)]}
        # invoke by NAME through the cf registry: the def may land in a SIBLING module (parallel compile),
        # and callers must hold no reference to it.
        {quote(do: unquote(@runtime).cf(unquote(Atom.to_string(name)), unquote(envq))), sc2}
      end)

    quote do
      unquote(@runtime).closure(fn unquote(thisvar), unquote(argvar) ->
        unquote_splicing(box_inits ++ binds ++ argbind)

        try do
          unquote_splicing(calls)
          :undefined
        catch
          :throw, {:gg_return, v} -> v
        end
      end)
    end
  end

  # group statements into slices of at most `limit` source bytes (a single oversized statement stays whole —
  # if it is itself a huge function, ITS body explodes recursively).
  defp chunk_by_bytes(nodes, limit) do
    nodes
    |> Enum.chunk_while(
      {[], 0},
      fn n, {acc, sz} ->
        b = (is_map(n) && (n["end"] || 0) - (n["start"] || 0)) || 0

        if sz + b > limit and acc != [],
          do: {:cont, Enum.reverse(acc), {[n], b}},
          else: {:cont, {[n | acc], sz + b}}
      end,
      fn
        {[], _} -> {:cont, {[], 0}}
        {acc, _} -> {:cont, Enum.reverse(acc), {[], 0}}
      end
    )
  end

  # count ReturnStatements in a subtree, NOT descending into nested functions.
  defp count_returns(%{"type" => t}) when t in ["FunctionExpression", "FunctionDeclaration", "ArrowFunctionExpression"], do: 0
  defp count_returns(%{"type" => "ReturnStatement"} = n), do: 1 + count_returns(n["argument"])
  defp count_returns(%{} = node), do: node |> Map.drop(["type"]) |> Map.values() |> Enum.map(&count_returns/1) |> Enum.sum()
  defp count_returns(list) when is_list(list), do: list |> Enum.map(&count_returns/1) |> Enum.sum()
  defp count_returns(_), do: 0

  defp block(list) when is_list(list), do: {:__block__, [], list}
  defp block(q), do: q

  # Identifier names that are ASSIGNMENT TARGETS anywhere in a subtree (for-loop state threading). Stops at
  # nested function boundaries (their assignments live in their own scope). Covers `=`/compound assignment,
  # `++`/`--`, `var` declarations, and `o.x = v` (which rebinds the base identifier `o`).
  defp assigned_names(nil), do: []

  defp assigned_names(%{"type" => t}) when t in ["FunctionExpression", "FunctionDeclaration", "ArrowFunctionExpression"],
    do: []

  defp assigned_names(%{"type" => "AssignmentExpression", "left" => l} = n) do
    target =
      case l do
        %{"type" => "Identifier", "name" => name} -> [name]
        %{"type" => "MemberExpression", "object" => %{"type" => "Identifier", "name" => name}} -> [name]
        _ -> []
      end

    target ++ assigned_names(n["right"])
  end

  defp assigned_names(%{"type" => "UpdateExpression", "argument" => %{"type" => "Identifier", "name" => name}}),
    do: [name]

  # a method call on an identifier receiver may rebind it (mutating methods push/pop/… — and the lowering
  # rebinds the identifier receiver unconditionally), so treat the receiver as assigned for loop-state threading.
  defp assigned_names(%{"type" => "CallExpression", "callee" => %{"type" => "MemberExpression", "computed" => false, "object" => %{"type" => "Identifier", "name" => name}}} = n),
    do: [name | Enum.flat_map(n["arguments"] || [], &assigned_names/1)]

  defp assigned_names(%{"type" => "VariableDeclaration", "declarations" => ds}) do
    Enum.flat_map(ds, fn d ->
      name = case d["id"] do %{"name" => n} -> [n]; _ -> [] end
      name ++ assigned_names(d["init"])
    end)
  end

  defp assigned_names(%{} = node) do
    node
    |> Map.drop(["type"])
    |> Map.values()
    |> Enum.flat_map(&assigned_names/1)
  end

  defp assigned_names(list) when is_list(list), do: Enum.flat_map(list, &assigned_names/1)
  defp assigned_names(_), do: []

  # ── helpers ──
  @globals ~w(Object Array Math JSON String Number Boolean Error TypeError RangeError SyntaxError Set Map WeakSet WeakMap Symbol Promise Buffer Proxy Reflect Date TextDecoder TextEncoder Uint8Array Int8Array Uint16Array Int16Array Uint32Array Int32Array Float32Array Float64Array ArrayBuffer DataView)
  @global_fns ~w(parseInt parseFloat isNaN isFinite encodeURIComponent decodeURIComponent encodeURI decodeURI BigInt)

  defp ident(n, scope) do
    cond do
      # a boxed local reads through its box (shared mutable closure variable)
      scope[:boxed] && MapSet.member?(scope.boxed, n) -> quote(do: unquote(@runtime).box_get(unquote(lvar(n))))
      MapSet.member?(scope.locals, n) -> lvar(n)
      # numeric global constants
      n == "Infinity" and not MapSet.member?(scope.locals, n) -> :infinity
      n == "NaN" and not MapSet.member?(scope.locals, n) -> :nan
      n == "undefined" and not MapSet.member?(scope.locals, n) -> :undefined
      # global namespaces (Object.keys, Math.floor, JSON.parse…) and bare global functions (parseInt…). Only
      # if not shadowed by a local/func — these are plain guest values ({:global}/{:globalfn} tags), not host refs.
      n in ~w(globalThis self window) and not MapSet.member?(scope.locals, n) -> {:{}, [], [:globalobj]}
      n in @globals and not (scope[:funcs] && MapSet.member?(scope.funcs, n)) -> {:{}, [], [:global, n]}
      n in @global_fns and not (scope[:funcs] && MapSet.member?(scope.funcs, n)) -> {:{}, [], [:globalfn, n]}
      # a top-level function name resolves LATE via the registry (forward refs + mutual recursion)
      is_map(scope) and scope[:funcs] && MapSet.member?(scope.funcs, n) ->
        quote(do: unquote(@runtime).greg_get(unquote((scope[:fnmap] || %{})[n] || n)))
      # a granted capability compiles to its integer handle — never a host module atom
      is_map(scope[:granted]) and Map.has_key?(scope.granted, n) -> {:{}, [], [:host, scope.granted[n]]}
      true -> :undefined
    end
  end

  defp lvar(n), do: Macro.var(String.to_atom("gg_" <> n), __MODULE__)

  # a per-declaration-SITE registry key so two different functions minified to the same name (marked's classes
  # all minify their inner constructor to `function u`) don't collide in the global late-bound registry.
  defp fnkey(n, %{"start" => s}), do: n <> "$" <> Integer.to_string(s)
  defp fnkey(n, _), do: n

  # JS `var` is FUNCTION-scoped and hoisted: collect every var name in a subtree (stopping at nested function
  # boundaries) so they can be pre-bound to :undefined at the function/program top. Fixes vars declared inside
  # nested blocks/if/switch referenced elsewhere in the same function.
  # names of function declarations directly in a body (not descending into nested functions/blocks).
  defp fndecl_names(%{"type" => "BlockStatement", "body" => body}), do: fndecl_names(body)
  defp fndecl_names(list) when is_list(list) do
    list
    |> Enum.filter(&(is_map(&1) and &1["type"] in ["FunctionDeclaration", "ClassDeclaration"] and &1["id"]))
    |> Enum.map(& &1["id"]["name"])
    |> MapSet.new()
  end
  defp fndecl_names(_), do: MapSet.new()

  defp collect_vars(nil), do: []

  defp collect_vars(%{"type" => t}) when t in ["FunctionExpression", "FunctionDeclaration", "ArrowFunctionExpression"],
    do: []

  defp collect_vars(%{"type" => "VariableDeclaration", "declarations" => ds} = _n) do
    Enum.flat_map(ds, fn d -> pattern_names(d["id"]) end) ++ Enum.flat_map(ds, fn d -> collect_vars(d["init"]) end)
  end

  defp collect_vars(%{} = node), do: node |> Map.drop(["type"]) |> Map.values() |> Enum.flat_map(&collect_vars/1)
  defp collect_vars(list) when is_list(list), do: Enum.flat_map(list, &collect_vars/1)
  defp collect_vars(_), do: []

  # ── closure-variable boxing analysis ──
  # names referenced INSIDE any nested function of `node` (captured variables).
  @fn_types ["FunctionExpression", "FunctionDeclaration", "ArrowFunctionExpression"]

  defp nested_refs(%{"type" => t} = n) when t in @fn_types, do: all_idents(n["body"]) ++ all_idents(n["params"])
  defp nested_refs(%{} = node), do: node |> Map.drop(["type"]) |> Map.values() |> Enum.flat_map(&nested_refs/1)
  defp nested_refs(list) when is_list(list), do: Enum.flat_map(list, &nested_refs/1)
  defp nested_refs(_), do: []

  defp all_idents(%{"type" => "Identifier", "name" => n}), do: [n]
  defp all_idents(%{} = node), do: node |> Map.drop(["type"]) |> Map.values() |> Enum.flat_map(&all_idents/1)
  defp all_idents(list) when is_list(list), do: Enum.flat_map(list, &all_idents/1)
  defp all_idents(_), do: []

  # names ASSIGNED anywhere (=, compound, ++/--, var-init) INCLUDING inside nested functions.
  defp all_assigned(%{"type" => "AssignmentExpression", "left" => %{"type" => "Identifier", "name" => n}} = a),
    do: [n | all_assigned(a["right"])]

  defp all_assigned(%{"type" => "UpdateExpression", "argument" => %{"type" => "Identifier", "name" => n}}), do: [n]

  defp all_assigned(%{"type" => "VariableDeclaration", "declarations" => ds}),
    do: Enum.flat_map(ds, fn d -> all_assigned(d["init"]) end)

  defp all_assigned(%{} = node), do: node |> Map.drop(["type"]) |> Map.values() |> Enum.flat_map(&all_assigned/1)
  defp all_assigned(list) when is_list(list), do: Enum.flat_map(list, &all_assigned/1)
  defp all_assigned(_), do: []

  # vars declared in `decls` that are captured by a nested function -> box them. JS closures capture by
  # REFERENCE, so boxing is needed both for shared MUTATION (counters/accumulators, marked's `u = u.replace`)
  # AND for self/forward references (`var n = { m: function(){ return n } }`, where n is captured before it is
  # assigned). Read-only non-captured locals stay plain (no box overhead).
  defp boxed_set(decls, body) do
    # captured-by-a-nested-fn OR mutated inside a loop that uses break/continue (those loops use throw-based
    # control flow, which unwinds the tuple-threaded state — so the affected vars must live in boxes instead).
    boxable =
      MapSet.new(nested_refs(body))
      |> MapSet.union(MapSet.new(control_loop_vars(body)))
      |> MapSet.union(MapSet.new(switch_vars(body)))
      |> MapSet.union(MapSet.new(try_vars(body)))
      |> MapSet.union(MapSet.new(expr_order_vars(body)))

    decls |> Enum.filter(&MapSet.member?(boxable, &1)) |> MapSet.new()
  end

  @fn_types ["FunctionExpression", "FunctionDeclaration", "ArrowFunctionExpression"]

  # Elixir does NOT propagate a rebind between sibling call arguments (`f(i++, i)` reads the stale i), so a var
  # that is UPDATED inside an expression AND mentioned again within the SAME expression root must be boxed —
  # box mutation is process-side and immune to argument-scope isolation. Loop counters (`for(;;i++)`) stay
  # unboxed: init/test/update are separate roots with one mention each.
  defp expr_order_vars(body) do
    body |> expr_roots() |> Enum.flat_map(&order_vars_in_root/1)
  end

  defp order_vars_in_root(root) do
    for v <- Enum.uniq(upd_targets(root)), ident_mentions(root, v) >= 2, do: v
  end

  defp expr_roots(%{"type" => t}) when t in @fn_types, do: []
  defp expr_roots(%{"type" => "ExpressionStatement", "expression" => e}) when is_map(e), do: [e]
  defp expr_roots(%{"type" => "VariableDeclarator"} = d), do: if(is_map(d["init"]), do: [d["init"]], else: [])
  defp expr_roots(%{"type" => "ReturnStatement"} = r), do: if(is_map(r["argument"]), do: [r["argument"]], else: [])
  defp expr_roots(%{"type" => "ThrowStatement", "argument" => e}) when is_map(e), do: [e]
  defp expr_roots(%{"type" => "IfStatement"} = n), do: [n["test"]] ++ expr_roots(n["consequent"]) ++ expr_roots(n["alternate"])
  defp expr_roots(%{"type" => t} = n) when t in ["WhileStatement", "DoWhileStatement"], do: [n["test"]] ++ expr_roots(n["body"])
  defp expr_roots(%{"type" => "ForStatement"} = n) do
    own = Enum.filter([n["test"], n["update"]], &is_map/1)
    init = if is_map(n["init"]) and n["init"]["type"] != "VariableDeclaration", do: [n["init"]], else: []
    own ++ init ++ expr_roots(n["init"]) ++ expr_roots(n["body"])
  end
  defp expr_roots(%{"type" => t} = n) when t in ["ForOfStatement", "ForInStatement"], do: [n["right"]] ++ expr_roots(n["body"])
  defp expr_roots(%{"type" => "SwitchStatement"} = n), do: [n["discriminant"]] ++ expr_roots(n["cases"])
  defp expr_roots(%{"type" => "SwitchCase"} = n), do: Enum.filter([n["test"]], &is_map/1) ++ expr_roots(n["consequent"])
  defp expr_roots(%{} = node), do: node |> Map.drop(["type"]) |> Map.values() |> Enum.flat_map(&expr_roots/1)
  defp expr_roots(list) when is_list(list), do: Enum.flat_map(list, &expr_roots/1)
  defp expr_roots(_), do: []

  defp upd_targets(%{"type" => t}) when t in @fn_types, do: []
  defp upd_targets(%{"type" => "UpdateExpression", "argument" => %{"type" => "Identifier", "name" => n}}), do: [n]
  defp upd_targets(%{"type" => "AssignmentExpression", "left" => %{"type" => "Identifier", "name" => n}} = a), do: [n | upd_targets(a["right"])]
  defp upd_targets(%{} = node), do: node |> Map.drop(["type"]) |> Map.values() |> Enum.flat_map(&upd_targets/1)
  defp upd_targets(list) when is_list(list), do: Enum.flat_map(list, &upd_targets/1)
  defp upd_targets(_), do: []

  defp ident_mentions(%{"type" => t}, _name) when t in @fn_types, do: 0
  defp ident_mentions(%{"type" => "Identifier", "name" => n}, name) when n == name, do: 1
  defp ident_mentions(%{} = node, name), do: node |> Map.drop(["type"]) |> Map.values() |> Enum.map(&ident_mentions(&1, name)) |> Enum.sum()
  defp ident_mentions(list, name) when is_list(list), do: list |> Enum.map(&ident_mentions(&1, name)) |> Enum.sum()
  defp ident_mentions(_, _), do: 0

  # vars assigned inside a try BLOCK (or its handler when a finalizer exists) — boxed so mutations made before
  # a throw survive the Elixir-try abort into the handler/finalizer path (bindings made in an aborted `try do`
  # body never escape into `catch`: `try { a = 1; throw x } catch (e) { …a… }` would read the stale value).
  defp try_vars(%{"type" => "TryStatement"} = n) do
    own =
      assigned_names(n["block"]) ++
        if(n["finalizer"] && n["handler"], do: assigned_names(n["handler"]["body"]), else: [])

    own ++ try_vars_children(n)
  end

  defp try_vars(%{"type" => t}) when t in ["FunctionExpression", "FunctionDeclaration", "ArrowFunctionExpression"], do: []
  defp try_vars(%{} = node), do: try_vars_children(node)
  defp try_vars(list) when is_list(list), do: Enum.flat_map(list, &try_vars/1)
  defp try_vars(_), do: []
  defp try_vars_children(node) when is_map(node), do: node |> Map.drop(["type"]) |> Map.values() |> Enum.flat_map(&try_vars/1)
  defp try_vars_children(_), do: []

  # vars assigned inside any switch case — boxed so case-body mutations survive the flag-guarded fall-through
  # lowering (an `if matched, do: body` doesn't export the body's bindings).
  defp switch_vars(%{"type" => "SwitchStatement"} = n), do: Enum.flat_map(n["cases"] || [], &assigned_names(&1["consequent"])) ++ switch_vars_children(n)
  defp switch_vars(%{"type" => t}) when t in ["FunctionExpression", "FunctionDeclaration", "ArrowFunctionExpression"], do: []
  defp switch_vars(%{} = node), do: switch_vars_children(node)
  defp switch_vars(list) when is_list(list), do: Enum.flat_map(list, &switch_vars/1)
  defp switch_vars(_), do: []
  defp switch_vars_children(node) when is_map(node), do: node |> Map.drop(["type"]) |> Map.values() |> Enum.flat_map(&switch_vars/1)
  defp switch_vars_children(_), do: []

  @loop_types ["ForStatement", "WhileStatement", "DoWhileStatement", "ForOfStatement", "ForInStatement"]

  # a do-while ALWAYS lowers to the throw-based shape (its state lives in boxes, never tuple threading), so
  # every var it assigns is boxed regardless of whether the body contains a break/continue.
  defp control_loop_vars(%{"type" => "DoWhileStatement"} = n),
    do: assigned_names(n) ++ control_loop_vars_children(n)

  # names assigned inside any loop whose body contains a break/continue (own-level, not a nested loop/switch).
  defp control_loop_vars(%{"type" => t} = n) when t in @loop_types do
    # must match the loop-lowering decision (loop_uses_control?): a labeled break/continue targeting THIS loop
    # can live inside a nested loop, so we can't stop at loop boundaries here.
    own = if loop_uses_control?(n["body"]), do: assigned_names(n), else: []
    own ++ control_loop_vars_children(n)
  end

  defp control_loop_vars(%{} = node), do: control_loop_vars_children(node)
  defp control_loop_vars(list) when is_list(list), do: Enum.flat_map(list, &control_loop_vars/1)
  defp control_loop_vars(_), do: []
  defp control_loop_vars_children(node) when is_map(node), do: node |> Map.drop(["type"]) |> Map.values() |> Enum.flat_map(&control_loop_vars/1)
  defp control_loop_vars_children(_), do: []

  # does this loop-body subtree contain a break/continue that targets THIS loop (stops at nested loops for
  # unlabeled ones; a labeled break/continue can still target an outer loop but is caught by label there)?
  defp loop_has_control?(%{"type" => t}) when t in ["BreakStatement", "ContinueStatement"], do: true
  defp loop_has_control?(%{"type" => t}) when t in @loop_types, do: false
  defp loop_has_control?(%{"type" => t}) when t in ["FunctionExpression", "FunctionDeclaration", "ArrowFunctionExpression"], do: false
  defp loop_has_control?(%{} = node), do: node |> Map.drop(["type"]) |> Map.values() |> Enum.any?(&loop_has_control?/1)
  defp loop_has_control?(list) when is_list(list), do: Enum.any?(list, &loop_has_control?/1)
  defp loop_has_control?(_), do: false

  # a loop body may contain break/continue targeting THIS loop OR (labeled) an outer one — either way, use the
  # throw-based control structure. Detect any break/continue not shadowed by a nested loop (unlabeled) — the
  # labeled ones we always route by label.
  defp loop_uses_control?(body) do
    labeled_control?(body) or loop_has_control?(body)
  end

  defp labeled_control?(%{"type" => t, "label" => l}) when t in ["BreakStatement", "ContinueStatement"] and is_map(l), do: true
  defp labeled_control?(%{"type" => t}) when t in ["FunctionExpression", "FunctionDeclaration", "ArrowFunctionExpression"], do: false
  defp labeled_control?(%{} = node), do: node |> Map.drop(["type"]) |> Map.values() |> Enum.any?(&labeled_control?/1)
  defp labeled_control?(list) when is_list(list), do: Enum.any?(list, &labeled_control?/1)
  defp labeled_control?(_), do: false

  # call/new argument list, spread-aware: `f(...xs, y)` flattens iterables at runtime.
  defp args_of(arguments, scope) do
    args = arguments || []
    if Enum.any?(args, &(&1["type"] == "SpreadElement")) do
      parts =
        Enum.map(args, fn
          %{"type" => "SpreadElement", "argument" => a} -> quote(do: {:spread, unquote(expr(a, scope))})
          e -> quote(do: {:one, unquote(expr(e, scope))})
        end)

      quote(do: unquote(@runtime).spread_args(unquote(parts)))
    else
      Enum.map(args, &expr(&1, scope))
    end
  end

  defp not_boxed(names, scope), do: Enum.reject(names, &(scope[:boxed] && MapSet.member?(scope.boxed, &1)))

  # ── destructuring patterns (const {a,b}=o / [x,y]=arr, with defaults + rest) ──
  defp pattern_names(nil), do: []
  defp pattern_names(%{"type" => "Identifier", "name" => n}), do: [n]

  defp pattern_names(%{"type" => "ObjectPattern", "properties" => props}),
    do: Enum.flat_map(props || [], fn
      %{"type" => "RestElement", "argument" => a} -> pattern_names(a)
      %{"value" => v} -> pattern_names(v)
      _ -> []
    end)

  defp pattern_names(%{"type" => "ArrayPattern", "elements" => els}), do: Enum.flat_map(els || [], &pattern_names/1)
  defp pattern_names(%{"type" => "AssignmentPattern", "left" => l}), do: pattern_names(l)
  defp pattern_names(%{"type" => "RestElement", "argument" => a}), do: pattern_names(a)
  defp pattern_names(_), do: []

  defp bind_local(n, vq, scope) do
    if scope[:boxed] && MapSet.member?(scope.boxed, n),
      do: quote(do: unquote(@runtime).box_set(unquote(lvar(n)), unquote(vq))),
      else: quote(do: unquote(lvar(n)) = unquote(vq))
  end

  # bind a destructuring pattern from `vq` — evaluate vq once into a temp, then bind each target.
  defp destructure(pattern, vq, scope) do
    tmp = uniqvar()
    {:__block__, [], [quote(do: unquote(tmp) = unquote(vq)) | destr_targets(pattern, tmp, scope)]}
  end

  defp destr_targets(%{"type" => "Identifier", "name" => n}, valq, scope), do: [bind_local(n, valq, scope)]

  # a destructuring TARGET that is a member expression (`[a.b] = …`, `({x: o.k} = …)`) — write through the
  # member chain rather than binding a local.
  defp destr_targets(%{"type" => "MemberExpression"} = m, valq, scope) do
    v = uniqvar()
    [quote(do: unquote(v) = unquote(valq)), assign_to(m, v, scope)]
  end

  defp destr_targets(%{"type" => "AssignmentPattern", "left" => l, "right" => r}, valq, scope) do
    v = uniqvar()
    [
      quote(do: unquote(v) = unquote(valq)),
      quote(do: unquote(v) = if(unquote(@runtime).binop(:===, unquote(v), :undefined), do: unquote(expr(r, scope)), else: unquote(v)))
      | destr_targets(l, v, scope)
    ]
  end

  defp destr_targets(%{"type" => "ObjectPattern", "properties" => props}, valq, scope) do
    v = uniqvar()
    taken = for p <- props, p["type"] != "RestElement", do: key_str_of(p["key"])

    [quote(do: unquote(v) = unquote(valq))] ++
      Enum.flat_map(props, fn
        %{"type" => "RestElement", "argument" => a} ->
          destr_targets(a, quote(do: unquote(@runtime).orest(unquote(v), unquote(taken))), scope)

        %{"key" => key, "value" => value, "computed" => computed} ->
          keyq = if computed, do: expr(key, scope), else: key_of(key)
          destr_targets(value, quote(do: unquote(@runtime).oget(unquote(v), unquote(keyq))), scope)
      end)
  end

  defp destr_targets(%{"type" => "ArrayPattern", "elements" => els}, valq, scope) do
    v = uniqvar()

    [quote(do: unquote(v) = unquote(valq))] ++
      (els
       |> Enum.with_index()
       |> Enum.flat_map(fn
         {nil, _} -> []
         {%{"type" => "RestElement", "argument" => a}, i} -> destr_targets(a, quote(do: unquote(@runtime).arest(unquote(v), unquote(i))), scope)
         {el, i} -> destr_targets(el, quote(do: unquote(@runtime).oget(unquote(v), unquote(i * 1.0))), scope)
       end))
  end

  defp key_str_of(%{"name" => n}), do: n
  defp key_str_of(%{"value" => v}) when is_binary(v), do: v
  defp key_str_of(%{"value" => v}), do: to_string(v)
  defp key_str_of(_), do: ""

  defp uniqvar, do: Macro.var(String.to_atom("__ggp#{System.unique_integer([:positive])}"), __MODULE__)

  # a switch case ends at an UNLABELED break (terminates the switch); a labeled `break outer` must survive to
  # reach the enclosing loop's catch.
  defp strip_breaks(stmts), do: Enum.reject(stmts || [], &(&1["type"] == "BreakStatement" and &1["label"] == nil))
  defp block_of(stmts), do: %{"type" => "BlockStatement", "body" => stmts}

  defp interleave([q | qs], [e | es]), do: [q, e | interleave(qs, es)]
  defp interleave(qs, []), do: qs
  defp interleave([], _), do: []

  defp method_prop?(%{"method" => true}), do: true
  defp method_prop?(%{"value" => %{"type" => t}}) when t in ["FunctionExpression", "ArrowFunctionExpression"], do: true
  defp method_prop?(_), do: false

  defp key_of(%{"type" => "Identifier", "name" => n}), do: n
  defp key_of(%{"type" => "Literal", "value" => v}) when is_binary(v), do: v
  defp key_of(%{"type" => "Literal", "value" => v}), do: to_string(v)

  defp lit(v) when is_integer(v), do: v * 1.0
  defp lit(v) when is_float(v), do: v
  # BigInt literal (tagged by the parser's replacer). No bigint term in F2 yet — represent as a float so the
  # value flows; exact >2^53 bigint math is a later rung, taken only if a reachable op actually needs it.
  defp lit(%{"$bigint" => s}), do: (case Integer.parse(s) do {i, _} -> i * 1.0; _ -> 0.0 end)
  defp lit(v) when is_binary(v), do: v
  defp lit(true), do: true
  defp lit(false), do: false
  defp lit(nil), do: :null

  defp binop_atom("+"), do: :+
  defp binop_atom("-"), do: :-
  defp binop_atom("*"), do: :*
  defp binop_atom("/"), do: :/
  defp binop_atom("<"), do: :<
  defp binop_atom(">"), do: :>
  defp binop_atom("<="), do: :"<="
  defp binop_atom(">="), do: :">="
  defp binop_atom("==="), do: :===
  defp binop_atom("=="), do: :==
  defp binop_atom("!=="), do: :!==
  defp binop_atom("!="), do: :!=
  defp binop_atom("%"), do: :rem
  defp binop_atom("&"), do: :band
  defp binop_atom("|"), do: :bor
  defp binop_atom("^"), do: :bxor
  defp binop_atom("<<"), do: :bsl
  defp binop_atom(">>"), do: :bsr
  defp binop_atom(">>>"), do: :bsru
  defp binop_atom("**"), do: :pow
  defp binop_atom("in"), do: :in
  defp binop_atom("instanceof"), do: :instanceof
  defp binop_atom(_), do: :bad
end
