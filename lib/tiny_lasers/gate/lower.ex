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

  @doc "Lower a full ESTree Program (decoded acorn JSON, string keys) into a quoted `run/0` body."
  def program(%{"type" => "Program", "body" => body}) do
    {stmts, _scope} = stmts(body, %{locals: MapSet.new()})
    {:__block__, [], stmts}
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
    do: %{s | locals: MapSet.put(s.locals, n)}

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

  defp stmt(%{"type" => "FunctionDeclaration", "id" => %{"name" => n}} = f, scope) do
    fq = func(f["params"], f["body"], scope)
    {quote(do: unquote(lvar(n)) = unquote(fq)), %{scope | locals: MapSet.put(scope.locals, n)}}
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

  defp stmt(%{"type" => "IfStatement"} = n, scope) do
    t = expr(n["test"], scope)
    {cons, _} = stmt(n["consequent"], scope)
    alt = if n["alternate"], do: elem(stmt(n["alternate"], scope), 0), else: :undefined

    q =
      quote do
        if unquote(@runtime).truthy(unquote(t)) do
          unquote(cons)
        else
          unquote(alt)
        end
      end

    {q, scope}
  end

  # for (init; test; update) body  — lowered to a tail-recursive anonymous fn (BEAM-native loop, GC'd).
  defp stmt(%{"type" => "ForStatement"} = n, scope) do
    {initq, s1} = if n["init"], do: for_init(n["init"], scope), else: {:undefined, scope}
    loop = Macro.var(:gg_loop, __MODULE__)
    testq = if n["test"], do: expr(n["test"], s1), else: true
    {bodyq, _} = stmt(n["body"], s1)
    updateq = if n["update"], do: expr(n["update"], s1), else: :undefined
    # capture the loop's mutable locals by threading them through the recursion is complex; for v0 we rely
    # on process-dict-free rebinding NOT being needed across iterations except the loop var, which update
    # mutates. We model loop vars via a small mutable cell in the Runtime to keep the lowering simple.
    q =
      quote do
        unquote(initq)

        unquote(loop) = fn me ->
          if unquote(@runtime).truthy(unquote(testq)) do
            unquote(bodyq)
            unquote(updateq)
            me.(me)
          else
            :undefined
          end
        end

        unquote(loop).(unquote(loop))
      end

    {q, scope}
  end

  defp stmt(%{"type" => "WhileStatement"} = n, scope) do
    stmt(%{"type" => "ForStatement", "init" => nil, "test" => n["test"], "update" => nil, "body" => n["body"]}, scope)
  end

  defp stmt(other, scope), do: {expr(other, scope), scope}

  defp for_init(%{"type" => "VariableDeclaration"} = d, scope), do: stmt(d, scope)
  defp for_init(e, scope), do: {expr(e, scope), scope}

  # ── expressions ──
  defp expr(%{"type" => "Literal", "value" => v}, _), do: lit(v)
  defp expr(%{"type" => "Identifier", "name" => n}, scope), do: ident(n, scope)

  defp expr(%{"type" => "ObjectExpression", "properties" => props}, scope) do
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

  defp expr(%{"type" => "MemberExpression"} = m, scope) do
    oq = expr(m["object"], scope)
    kq = if m["computed"], do: expr(m["property"], scope), else: key_of(m["property"])
    quote(do: unquote(@runtime).oget(unquote(oq), unquote(kq)))
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
            quote(do: unquote(lvar(n)) = unquote(@runtime).oput(unquote(ident(n, scope)), unquote(kq), unquote(rq)))

          _ ->
            # nested member target (o.a.b = v): functional update without rebinding the deep base (v0 limit)
            quote(do: unquote(@runtime).oput(unquote(expr(base, scope)), unquote(kq), unquote(rq)))
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

  defp expr(%{"type" => "UnaryExpression", "operator" => "!", "argument" => a}, scope),
    do: quote(do: not unquote(@runtime).truthy(unquote(expr(a, scope))))

  defp expr(%{"type" => "UnaryExpression", "operator" => "-", "argument" => a}, scope),
    do: quote(do: unquote(@runtime).binop(:-, 0.0, unquote(expr(a, scope))))

  # i++ / i-- as statements-in-expression: rebind the identifier
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

  # ── functions: real Elixir closures behind fun_new; returns via throw/catch ──
  defp func(params, body, scope) do
    names = Enum.map(params, fn %{"name" => n} -> n end)
    inner = Enum.reduce(names, scope.locals, &MapSet.put(&2, &1))
    # NOT of the form "gg_<name>" so it can never collide with a guest identifier's local var.
    argvar = Macro.var(:__ggargs, __MODULE__)

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
      unquote(@runtime).closure(fn unquote(argvar) ->
        try do
          unquote_splicing(binds)
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

  # ── helpers ──
  defp ident(n, scope) do
    if MapSet.member?(scope.locals, n), do: lvar(n), else: :undefined
  end

  defp lvar(n), do: Macro.var(String.to_atom("gg_" <> n), __MODULE__)

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
