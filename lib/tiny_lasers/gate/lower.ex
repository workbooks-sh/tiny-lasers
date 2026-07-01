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
    scope0 = %{locals: Enum.reduce(vars, MapSet.new(), &MapSet.put(&2, &1)), granted: granted, funcs: MapSet.new()}
    {stmts, _scope} = stmts(body, scope0)
    # top-level `this` is undefined; pre-bind all hoisted vars to :undefined (JS var hoisting).
    prelude = [quote(do: unquote(Macro.var(:__ggthis, __MODULE__)) = :undefined) | Enum.map(vars, fn v -> quote(do: unquote(lvar(v)) = :undefined) end)]
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

  defp hoist(%{"type" => "FunctionDeclaration", "id" => %{"name" => n}}, s),
    do: %{s | funcs: MapSet.put(s[:funcs] || MapSet.new(), n)}

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
        q = quote(do: unquote(lvar(n)) = unquote(vq))
        {[q | acc], s2}
      end)

    {{:__block__, [], Enum.reverse(rev)}, sc}
  end

  # top-level (and nested) function declarations register in the late-bound function registry, so forward
  # references and mutual recursion work regardless of source order.
  defp stmt(%{"type" => "FunctionDeclaration", "id" => %{"name" => n}} = f, scope) do
    fq = func(f["params"], f["body"], scope)
    {quote(do: unquote(@runtime).greg_set(unquote(n), unquote(fq))), %{scope | funcs: MapSet.put(scope[:funcs] || MapSet.new(), n)}}
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
      (assigned_names(n["consequent"]) ++ assigned_names(n["alternate"])) |> Enum.uniq()

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
    {initq, s1} = if n["init"], do: for_init(n["init"], scope), else: {:undefined, scope}

    mutated =
      [n["test"], n["update"], n["body"]]
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(&assigned_names/1)
      |> Kernel.++(assigned_names(n["init"]))
      |> Enum.uniq()

    statevars = Enum.map(mutated, &lvar/1)
    state_tuple = {:{}, [], statevars}
    loop = Macro.var(:gg_loop, __MODULE__)

    # a var declared INSIDE the loop body (not already bound in the enclosing scope) must be initialized
    # before the initial state tuple is built, else it is unbound.
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

  defp stmt(%{"type" => "ThrowStatement", "argument" => arg}, scope),
    do: {quote(do: unquote(@runtime).throw_val(unquote(expr(arg, scope)))), scope}

  # try { block } catch (e) { handler } finally { finalizer }. Mutations thread out as returned state (like
  # if/for). Guest throws ({:gg_throw}) and guest errors ({:gg_guest_error}) are catchable; {:gg_return}
  # propagates (never swallowed). Finalizer runs after normal completion (v0: not on a return-in-try).
  defp stmt(%{"type" => "TryStatement"} = n, scope) do
    handler = n["handler"]
    param = handler && handler["param"] && handler["param"]["name"]
    hscope = if param, do: %{scope | locals: MapSet.put(scope.locals, param)}, else: scope

    {blockq, _} = stmt(n["block"], scope)
    {handlerq, _} = if handler, do: stmt(handler["body"], hscope), else: {:undefined, scope}

    mutated =
      (assigned_names(n["block"]) ++ (handler && assigned_names(handler["body"]) || []))
      |> Enum.uniq()

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
  defp stmt(%{"type" => "SwitchStatement"} = n, scope) do
    dvar = %{"type" => "Identifier", "name" => "__ggswitch"}
    decl = %{"type" => "VariableDeclaration", "declarations" => [%{"id" => dvar, "init" => n["discriminant"]}]}

    cases = n["cases"] || []
    {defaults, tested} = Enum.split_with(cases, &(&1["test"] == nil))
    default_body = if defaults != [], do: block_of(strip_breaks(hd(defaults)["consequent"])), else: nil

    chain =
      Enum.reduce(Enum.reverse(tested), default_body, fn c, acc ->
        %{
          "type" => "IfStatement",
          "test" => %{"type" => "BinaryExpression", "operator" => "===", "left" => dvar, "right" => c["test"]},
          "consequent" => block_of(strip_breaks(c["consequent"])),
          "alternate" => acc
        }
      end)

    stmt(%{"type" => "BlockStatement", "body" => [decl | (chain && [chain]) || []]}, scope)
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

    s1 = %{scope | locals: MapSet.put(scope.locals, vn)}
    itemsfn = if kind == :of, do: :iter, else: :enum_keys
    itemsq = quote(do: unquote(@runtime).unquote(itemsfn)(unquote(expr(n["right"], scope))))

    mutated = (assigned_names(n["body"]) -- [vn]) |> Enum.uniq()
    inits = for v <- mutated, not MapSet.member?(scope.locals, v), do: quote(do: unquote(lvar(v)) = :undefined)
    state = {:{}, [], Enum.map(mutated, &lvar/1)}
    loop = Macro.var(:gg_feach, __MODULE__)
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
  defp expr(%{"type" => "Identifier", "name" => n}, scope), do: ident(n, scope)
  defp expr(%{"type" => "ThisExpression"}, _scope), do: Macro.var(:__ggthis, __MODULE__)

  # An object literal with a METHOD (function-valued property) is a stateful INSTANCE → a mutable cell (so
  # this.x=v and aliasing work). A pure data bag → an immutable {keys,map} term (GC'd, the H1 win). Spread
  # objects stay immutable (spread builds a fresh object).
  defp expr(%{"type" => "ObjectExpression", "properties" => props}, scope) do
    has_spread = Enum.any?(props, &(&1["type"] == "SpreadElement"))
    has_method = Enum.any?(props, &method_prop?/1)

    if has_method and not has_spread do
      pairs =
        Enum.map(props, fn p ->
          kq = if p["computed"], do: expr(p["key"], scope), else: key_of(p["key"])
          quote(do: {unquote(kq), unquote(expr(p["value"], scope))})
        end)

      quote(do: unquote(@runtime).cell_new(unquote(pairs)))
    else
      Enum.reduce(props, quote(do: unquote(@runtime).olit()), fn p, acc ->
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
    elq = Enum.map(els, fn e -> if e, do: expr(e, scope), else: :undefined end)
    quote(do: unquote(@runtime).alit(unquote(elq)))
  end

  # method call `recv.name(args)` → confined Runtime.method dispatch. A mutating method (push/pop/…) returns
  # `{:mut, new_recv, result}`; when the receiver is an identifier we rebind it (JS in-place mutation).
  defp expr(%{"type" => "CallExpression", "callee" => %{"type" => "MemberExpression", "computed" => false} = m} = c, scope) do
    name = key_of(m["property"])
    argq = Enum.map(c["arguments"], &expr(&1, scope))

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
        quote(do: unquote(lvar(n)) = unquote(rq))

      %{"type" => "MemberExpression"} = m ->
        base = m["object"]
        kq = if m["computed"], do: expr(m["property"], scope), else: key_of(m["property"])

        case base do
          %{"type" => "Identifier", "name" => n} ->
            quote(do: unquote(lvar(n)) = unquote(@runtime).oput_idx(unquote(ident(n, scope)), unquote(kq), unquote(rq)))

          _ ->
            # nested member target (o.a.b = v): functional update without rebinding the deep base (v0 limit)
            quote(do: unquote(@runtime).oput_idx(unquote(expr(base, scope)), unquote(kq), unquote(rq)))
        end
    end
  end

  defp expr(%{"type" => "BinaryExpression", "operator" => op} = n, scope) do
    quote(do: unquote(@runtime).binop(unquote(binop_atom(op)), unquote(expr(n["left"], scope)), unquote(expr(n["right"], scope))))
  end

  defp expr(%{"type" => "LogicalExpression", "operator" => op} = n, scope) do
    lq = expr(n["left"], scope)
    rq = expr(n["right"], scope)

    case op do
      "&&" -> quote(do: (fn v -> if unquote(@runtime).truthy(v), do: unquote(rq), else: v end).(unquote(lq)))
      "||" -> quote(do: (fn v -> if unquote(@runtime).truthy(v), do: v, else: unquote(rq) end).(unquote(lq)))
    end
  end

  defp expr(%{"type" => "ConditionalExpression"} = n, scope) do
    quote do
      if unquote(@runtime).truthy(unquote(expr(n["test"], scope))),
        do: unquote(expr(n["consequent"], scope)),
        else: unquote(expr(n["alternate"], scope))
    end
  end

  defp expr(%{"type" => "UnaryExpression", "operator" => "typeof", "argument" => a}, scope),
    do: quote(do: unquote(@runtime).typeof(unquote(expr(a, scope))))

  defp expr(%{"type" => "UnaryExpression", "operator" => "!", "argument" => a}, scope),
    do: quote(do: not unquote(@runtime).truthy(unquote(expr(a, scope))))

  defp expr(%{"type" => "UnaryExpression", "operator" => "-", "argument" => a}, scope),
    do: quote(do: unquote(@runtime).binop(:-, 0.0, unquote(expr(a, scope))))

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

  # i++ / i-- / ++i / --i on an identifier: rebind. (prefix vs postfix return value rarely load-bearing here.)
  defp expr(%{"type" => "UpdateExpression", "operator" => op, "argument" => %{"name" => n}} = _u, scope) do
    delta = if op == "++", do: 1.0, else: -1.0
    quote(do: unquote(lvar(n)) = unquote(@runtime).binop(:+, unquote(ident(n, scope)), unquote(delta)))
  end

  defp expr(%{"type" => "CallExpression"} = c, scope) do
    argq = Enum.map(c["arguments"], &expr(&1, scope))
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
    inner = Enum.reduce(names ++ bodyvars, scope.locals, &MapSet.put(&2, &1))

    hoistq = Enum.map(bodyvars, fn v -> quote(do: unquote(lvar(v)) = :undefined) end)

    binds =
      names
      |> Enum.with_index()
      |> Enum.map(fn {p, i} -> quote(do: unquote(lvar(p)) = unquote(@runtime).arg(unquote(argvar), unquote(i))) end)

    bodyq =
      case body do
        %{"type" => "BlockStatement", "body" => b} -> elem(stmts(b, %{scope | locals: inner}), 0) |> block()
        e -> quote(do: unquote(@runtime).ret(unquote(expr(e, %{scope | locals: inner}))))
      end

    quote do
      unquote(@runtime).closure(fn unquote(thisvar), unquote(argvar) ->
        try do
          unquote_splicing(hoistq ++ binds)
          unquote(bodyq)
          :undefined
        catch
          :throw, {:gg_return, v} -> v
        end
      end)
    end
  end

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
  defp ident(n, scope) do
    cond do
      MapSet.member?(scope.locals, n) -> lvar(n)
      # a top-level function name resolves LATE via the registry (forward refs + mutual recursion)
      is_map(scope) and scope[:funcs] && MapSet.member?(scope.funcs, n) -> quote(do: unquote(@runtime).greg_get(unquote(n)))
      # a granted capability compiles to its integer handle — never a host module atom
      is_map(scope[:granted]) and Map.has_key?(scope.granted, n) -> {:{}, [], [:host, scope.granted[n]]}
      true -> :undefined
    end
  end

  defp lvar(n), do: Macro.var(String.to_atom("gg_" <> n), __MODULE__)

  # JS `var` is FUNCTION-scoped and hoisted: collect every var name in a subtree (stopping at nested function
  # boundaries) so they can be pre-bound to :undefined at the function/program top. Fixes vars declared inside
  # nested blocks/if/switch referenced elsewhere in the same function.
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

  defp strip_breaks(stmts), do: Enum.reject(stmts || [], &(&1["type"] == "BreakStatement"))
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
  defp lit(nil), do: :undefined

  defp binop_atom("+"), do: :+
  defp binop_atom("-"), do: :-
  defp binop_atom("*"), do: :*
  defp binop_atom("/"), do: :/
  defp binop_atom("<"), do: :<
  defp binop_atom(">"), do: :>
  defp binop_atom("<="), do: :"<="
  defp binop_atom(">="), do: :">="
  defp binop_atom("==="), do: :==
  defp binop_atom("=="), do: :==
  defp binop_atom("!=="), do: :!=
  defp binop_atom("!="), do: :!=
  defp binop_atom("%"), do: :rem
  defp binop_atom(_), do: :bad
end
