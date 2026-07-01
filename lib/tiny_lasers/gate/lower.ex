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

    {:__block__, [], prelude ++ stmts}
  end

  # ── statement lists thread lexical scope (which names are locals) ──
  defp stmts(nodes, scope) do
    # hoist function declarations + var names so forward references resolve as locals
    hoisted = Enum.reduce(nodes, scope, &hoist/2)

    {rev, sc} =
      Enum.reduce(nodes, {[], hoisted}, fn n, {acc, s} ->
        {q, s2} = stmt(n, s)
        {[q | acc], s2}
      end)

    {Enum.reverse(rev), sc}
  end

  defp hoist(%{"type" => "FunctionDeclaration", "id" => %{"name" => n}} = f, s),
    do: %{s | funcs: MapSet.put(s[:funcs] || MapSet.new(), n), fnmap: Map.put(s[:fnmap] || %{}, n, fnkey(n, f))}

  defp hoist(%{"type" => "VariableDeclaration", "declarations" => ds}, s) do
    Enum.reduce(ds, s, fn %{"id" => %{"name" => n}}, acc -> %{acc | locals: MapSet.put(acc.locals, n)} end)
  end

  defp hoist(_, s), do: s

  # ── statements ──
  defp stmt(%{"type" => "VariableDeclaration", "declarations" => ds}, scope) do
    {rev, sc} =
      Enum.reduce(ds, {[], scope}, fn %{"id" => %{"name" => n}} = d, {acc, s} ->
        init = d["init"]
        s2 = %{s | locals: MapSet.put(s.locals, n)}
        vq = if init, do: expr(init, s2), else: :undefined
        # a boxed var's box is pre-created at scope entry; the declaration SETS the box (never rebinds).
        q =
          if s2[:boxed] && MapSet.member?(s2.boxed, n),
            do: quote(do: unquote(@runtime).box_set(unquote(lvar(n)), unquote(vq))),
            else: quote(do: unquote(lvar(n)) = unquote(vq))

        {[q | acc], s2}
      end)

    {{:__block__, [], Enum.reverse(rev)}, sc}
  end

  # top-level (and nested) function declarations register in the late-bound function registry, so forward
  # references and mutual recursion work regardless of source order.
  defp stmt(%{"type" => "FunctionDeclaration", "id" => %{"name" => n}} = f, scope) do
    key = fnkey(n, f)
    scope = %{scope | funcs: MapSet.put(scope[:funcs] || MapSet.new(), n), fnmap: Map.put(scope[:fnmap] || %{}, n, key)}
    fq = func(f["params"], f["body"], scope)
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
    param = handler && handler["param"] && handler["param"]["name"]
    # the catch param is a FRESH plain binding (`gg_param = thrown`); if it shadows an outer boxed var of the
    # same name, drop it from `boxed` in the handler so reads use the plain binding (not box_get on a raw value).
    hscope =
      if param,
        do: %{scope | locals: MapSet.put(scope.locals, param), boxed: MapSet.delete(scope[:boxed] || MapSet.new(), param)},
        else: scope

    {blockq, _} = stmt(n["block"], scope)
    {handlerq, _} = if handler, do: stmt(handler["body"], hscope), else: {:undefined, scope}

    mutated =
      (assigned_names(n["block"]) ++ (handler && assigned_names(handler["body"]) || []))
      |> Enum.uniq()
      |> not_boxed(scope)

    state = {:{}, [], Enum.map(mutated, &lvar/1)}
    inits = for v <- mutated, not MapSet.member?(scope.locals, v), do: quote(do: unquote(lvar(v)) = :undefined)
    bind_param = if param, do: quote(do: unquote(lvar(param)) = __gg_thrown), else: quote(do: _ = __gg_thrown)

    tryq =
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

    q =
      if n["finalizer"] do
        {finq, _} = stmt(n["finalizer"], scope)
        quote(do: (unquote(tryq); unquote(finq)))
      else
        tryq
      end

    {q, scope}
  end

  defp stmt(%{"type" => "WhileStatement"} = n, scope) do
    stmt(%{"type" => "ForStatement", "init" => nil, "test" => n["test"], "update" => nil, "body" => n["body"]}, scope)
  end

  defp stmt(%{"type" => "DoWhileStatement"} = n, scope) do
    # do body while(test): run body once, then a while. Approximate by running body then the while loop.
    {b1, _} = stmt(n["body"], scope)
    {w, _} = stmt(%{"type" => "WhileStatement", "test" => n["test"], "body" => n["body"]}, scope)
    {quote(do: (unquote(b1); unquote(w))), scope}
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

  defp stmt(other, scope), do: {expr(other, scope), scope}

  defp for_init(%{"type" => "VariableDeclaration"} = d, scope), do: stmt(d, scope)
  defp for_init(e, scope), do: {expr(e, scope), scope}

  # for (var x of iterable) / for (var k in obj): iterate items/keys, binding the loop var each round, and
  # threading body-mutated vars through the recursion (like ForStatement). The loop var is bound from the
  # item, not threaded.
  defp for_each(n, kind, scope) do
    vn =
      case n["left"] do
        %{"type" => "VariableDeclaration", "declarations" => [%{"id" => %{"name" => v}} | _]} -> v
        %{"type" => "Identifier", "name" => v} -> v
        _ -> "__ggforvar"
      end

    label = scope[:pending_label]
    base = Map.put(scope, :pending_label, nil)
    s1 = %{base | locals: MapSet.put(base.locals, vn)}
    itemsfn = if kind == :of, do: :iter, else: :enum_keys
    itemsq = quote(do: unquote(@runtime).unquote(itemsfn)(unquote(expr(n["right"], base))))
    loop = Macro.var(:gg_feach, __MODULE__)

    if loop_uses_control?(n["body"]) do
      tag = System.unique_integer([:positive])
      sc = Map.put(s1, :loops, [{label, tag, :loop} | (scope[:loops] || [])])
      {bodyq, _} = stmt(n["body"], sc)

      q =
        quote do
          unquote(loop) = fn
            me, [__ggitem | __ggrest] ->
              unquote(lvar(vn)) = __ggitem

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
        Enum.map(props, fn p ->
          kq = if p["computed"], do: expr(p["key"], scope), else: key_of(p["key"])
          quote(do: {unquote(kq), unquote(expr(p["value"], scope))})
        end)

      quote(do: unquote(@runtime).cell_new(unquote(pairs)))
    else
      # spread: start from an empty cell and merge/set each property in order.
      Enum.reduce(props, quote(do: unquote(@runtime).cell_new([])), fn p, acc ->
        case p do
          %{"type" => "SpreadElement", "argument" => a} ->
            quote(do: unquote(@runtime).omerge(unquote(acc), unquote(expr(a, scope))))

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

  # method call `recv.name(args)` → confined Runtime.method dispatch. A mutating method (push/pop/…) returns
  # `{:mut, new_recv, result}`; when the receiver is an identifier we rebind it (JS in-place mutation).
  defp expr(%{"type" => "CallExpression", "callee" => %{"type" => "MemberExpression", "computed" => false} = m} = c, scope) do
    name = key_of(m["property"])
    argq = args_of(c["arguments"], scope)

    case m["object"] do
      # identifier receiver: rebind it if the method mutated (a.push(x))
      %{"type" => "Identifier", "name" => rn} ->
        res = Macro.var(:__ggres, __MODULE__)

        quote do
          {unquote(lvar(rn)), unquote(res)} =
            case unquote(@runtime).method(unquote(ident(rn, scope)), unquote(name), unquote(argq)) do
              {:mut, nr, r} -> {nr, r}
              v -> {unquote(ident(rn, scope)), v}
            end

          unquote(res)
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

  defp expr(%{"type" => "MemberExpression"} = m, scope) do
    oq = expr(m["object"], scope)
    kq = if m["computed"], do: expr(m["property"], scope), else: key_of(m["property"])
    quote(do: unquote(@runtime).oget(unquote(oq), unquote(kq)))
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

  # ++ / -- on a member: this.pos++ / o.n-- — read, +/-1, write back (in-place on a cell).
  defp expr(%{"type" => "UpdateExpression", "operator" => op, "argument" => %{"type" => "MemberExpression"} = m}, scope) do
    delta = if op == "++", do: 1.0, else: -1.0
    kq = if m["computed"], do: expr(m["property"], scope), else: key_of(m["property"])

    case m["object"] do
      %{"type" => "Identifier", "name" => bn} ->
        quote(do: unquote(lvar(bn)) = unquote(@runtime).oput_idx(unquote(ident(bn, scope)), unquote(kq),
          unquote(@runtime).binop(:+, unquote(@runtime).oget(unquote(ident(bn, scope)), unquote(kq)), unquote(delta))))

      base ->
        b = Macro.var(:__ggub, __MODULE__)
        quote do
          unquote(b) = unquote(expr(base, scope))
          unquote(@runtime).oput_idx(unquote(b), unquote(kq),
            unquote(@runtime).binop(:+, unquote(@runtime).oget(unquote(b), unquote(kq)), unquote(delta)))
        end
    end
  end

  # i++ / i-- / ++i / --i on an identifier: rebind (or box_set if boxed).
  defp expr(%{"type" => "UpdateExpression", "operator" => op, "argument" => %{"name" => n}} = _u, scope) do
    delta = if op == "++", do: 1.0, else: -1.0
    newv = quote(do: unquote(@runtime).binop(:+, unquote(ident(n, scope)), unquote(delta)))

    if scope[:boxed] && MapSet.member?(scope.boxed, n),
      do: quote(do: unquote(@runtime).box_set(unquote(lvar(n)), unquote(newv))),
      else: quote(do: unquote(lvar(n)) = unquote(newv))
  end

  defp expr(%{"type" => "CallExpression"} = c, scope) do
    argq = args_of(c["arguments"], scope)
    quote(do: unquote(@runtime).call(unquote(expr(c["callee"], scope)), unquote(argq)))
  end

  defp expr(%{"type" => t} = f, scope) when t in ["FunctionExpression", "ArrowFunctionExpression"],
    do: func(f["params"], f["body"], scope)

  defp expr(nil, _), do: :undefined
  defp expr(_other, _scope), do: :undefined

  # ── functions: real Elixir closures behind closure/1; returns via throw/catch ──
  # `self_name` (for named declarations/expressions) is bound INSIDE the body to a self-passing closure, so a
  # named function can recurse — Elixir anonymous funs can't reference their own binding name, so we use the
  # Y-combinator form `rec = fn me, args -> ...me... end` and expose `gg_<name>` as `closure(fn a-> me.(me,a) end)`.
  # a guest function as a directly-held closure with the (this, args) ABI. Recursion/forward/mutual refs are
  # handled by the late-bound function registry (a function name resolves to Runtime.greg_get at each use),
  # so no Y-combinator is needed here. `this` binds the method receiver; ThisExpression lowers to __ggthis.
  defp func(params, body, scope) do
    names = Enum.map(params, fn %{"name" => n} -> n end)
    argvar = Macro.var(:__ggargs, __MODULE__)
    thisvar = Macro.var(:__ggthis, __MODULE__)
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

    binds =
      names
      |> Enum.with_index()
      |> Enum.map(fn {p, i} ->
        av = quote(do: unquote(@runtime).arg(unquote(argvar), unquote(i)))
        if MapSet.member?(boxed, p),
          do: quote(do: unquote(lvar(p)) = unquote(@runtime).box(unquote(av))),
          else: quote(do: unquote(lvar(p)) = unquote(av))
      end)

    # a param/var here SHADOWS an outer boxed var of the same name — the inner one is a distinct variable, so
    # drop shadowed names from the inherited boxed set before unioning this scope's boxed vars.
    shadow = MapSet.union(MapSet.new(names ++ bodyvars), fndecls)
    inherited = MapSet.difference(scope[:boxed] || MapSet.new(), shadow)
    bscope = %{scope | locals: inner, boxed: MapSet.difference(MapSet.union(inherited, boxed), fndecls)}

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

    if tail_return? do
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
          unquote_splicing(hoistq ++ binds ++ argbind ++ value_stmts)
        end)
      end
    else
      {bq, _} = stmts(stmts_list, bscope)

      quote do
        unquote(@runtime).closure(fn unquote(thisvar), unquote(argvar) ->
          try do
            unquote_splicing(hoistq ++ binds ++ argbind ++ bq)
            :undefined
          catch
            :throw, {:gg_return, v} -> v
          end
        end)
      end
    end
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
  @globals ~w(Object Array Math JSON String Number Boolean Error TypeError RangeError SyntaxError Set Map)
  @global_fns ~w(parseInt parseFloat isNaN isFinite encodeURIComponent decodeURIComponent encodeURI decodeURI)

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
    |> Enum.filter(&(is_map(&1) and &1["type"] == "FunctionDeclaration"))
    |> Enum.map(& &1["id"]["name"])
    |> MapSet.new()
  end
  defp fndecl_names(_), do: MapSet.new()

  defp collect_vars(nil), do: []

  defp collect_vars(%{"type" => t}) when t in ["FunctionExpression", "FunctionDeclaration", "ArrowFunctionExpression"],
    do: []

  defp collect_vars(%{"type" => "VariableDeclaration", "declarations" => ds} = n) do
    names = Enum.flat_map(ds, fn d -> case d["id"] do %{"name" => nm} -> [nm]; _ -> [] end end)
    names ++ Enum.flat_map(ds, fn d -> collect_vars(d["init"]) end)
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

    decls |> Enum.filter(&MapSet.member?(boxable, &1)) |> MapSet.new()
  end

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
