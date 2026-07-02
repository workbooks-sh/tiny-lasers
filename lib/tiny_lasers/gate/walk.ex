defmodule TinyLasers.Gate.Walk do
  @moduledoc """
  **F2 dev-tier ESTree tree-walk interpreter — the fast feedback loop.**

  Evaluates a guest ESTree directly against `TinyLasers.Gate.Runtime`, the SAME semantic core the
  compile-to-BEAM path (`Lower`) emits calls to. No `Code.compile_quoted`, so it never pays to compile the
  dead 90% of a big bundle (rollup: ~160s compile → interpret the tiny reached slice in seconds). Because both
  frontends funnel through `Runtime`, they cannot diverge on behaviour; the locked corpus goldens
  (marked/acorn/magic-string) validate the interpreter against the compiler for free.

  This is a DEV accelerator, not the product: the confined-BEAM-native claim + perf are proven by the compile
  path and the locked ExUnit test. Use `Walk` to find gaps fast, `Lower` to prove the result.

  Values, control flow (`{:gg_return|:gg_throw|:gg_guest_error, _}` throws), and confinement (only `Runtime` is
  ever called) are identical to the compiled path. Variables live in boxes (`Runtime.box`) held in a scope
  chain, mirroring the compiler's closure/mutation model.

  (Distinct from `TinyLasers.Gate.Interp`, which interprets the `eval()` capability's custom tuple-AST.)
  """
  alias TinyLasers.Gate.Runtime

  @globals ~w(Object Array Math JSON String Number Boolean Error TypeError RangeError SyntaxError
              Set Map WeakSet WeakMap Symbol Promise Buffer Proxy Reflect Date TextDecoder TextEncoder
              Uint8Array Int8Array Uint16Array Int16Array Uint32Array Int32Array Float32Array Float64Array ArrayBuffer DataView)
  @global_fns ~w(parseInt parseFloat isNaN isFinite encodeURIComponent decodeURIComponent encodeURI decodeURI BigInt)

  # ── entry ──────────────────────────────────────────────────────────────────────────────────────────────
  @doc "Interpret a parsed Program AST. `granted` maps host-capability names → cap ids (like Lower)."
  def run(%{"type" => "Program", "body" => body}, granted \\ %{}) do
    Process.put(:walk_granted, granted)
    Process.put(:walk_uid, 0)
    env = new_env()
    hoist(env, body)
    exec_all(body, env)
    Runtime.drain_microtasks()
    :ok
  end

  # ── environment: a chain of scopes; each scope a process-dict map name→box (mutable, shared with closures) ─
  defp new_env do
    id = uid()
    Process.put({:wscope, id}, %{})
    [id]
  end

  defp push(env) do
    id = uid()
    Process.put({:wscope, id}, %{})
    [id | env]
  end

  defp scope_map(id), do: Process.get({:wscope, id}, %{})
  defp scope_put(id, name, box), do: Process.put({:wscope, id}, Map.put(scope_map(id), name, box))

  defp declare([id | _], name, val) do
    box = Runtime.box(val)
    scope_put(id, name, box)
    box
  end

  defp find_box([], _name), do: nil
  defp find_box([id | rest], name) do
    case Map.get(scope_map(id), name) do
      nil -> find_box(rest, name)
      box -> box
    end
  end

  defp get_var(env, name) do
    case find_box(env, name) do
      nil -> resolve_global(name)
      box -> Runtime.box_get(box)
    end
  end

  defp resolve_global("undefined"), do: :undefined
  defp resolve_global("NaN"), do: :nan
  defp resolve_global("Infinity"), do: :infinity
  defp resolve_global(n) when n in ~w(globalThis self window), do: {:globalobj}
  defp resolve_global(n) do
    granted = Process.get(:walk_granted, %{})
    cond do
      Map.has_key?(granted, n) -> {:host, granted[n]}
      n in @globals -> {:global, n}
      n in @global_fns -> {:globalfn, n}
      true -> :undefined
    end
  end

  defp set_var(env, name, val) do
    case find_box(env, name) do
      nil -> declare([List.last(env)], name, val)
      box -> Runtime.box_set(box, val)
    end
    val
  end

  # ── hoisting ─────────────────────────────────────────────────────────────────────────────────────────────
  defp hoist([id | _] = env, nodes) when is_list(nodes), do: Enum.each(nodes, &hoist_node(env, id, &1))

  defp hoist_node(env, sid, %{"type" => "VariableDeclaration", "declarations" => ds}) do
    Enum.each(ds, fn d -> Enum.each(pattern_names(d["id"]), fn n -> ensure_box(env, sid, n) end) end)
  end
  defp hoist_node(env, sid, %{"type" => "FunctionDeclaration", "id" => %{"name" => n}} = f) do
    box = ensure_box(env, sid, n)
    Runtime.box_set(box, make_fn(f["params"], f["body"], env, f["async"] == true, false, f["generator"] == true))
  end
  defp hoist_node(env, sid, %{"type" => "ClassDeclaration", "id" => %{"name" => n}}), do: ensure_box(env, sid, n)
  defp hoist_node(env, sid, %{"type" => t} = n) when t in ["IfStatement", "ForStatement", "ForInStatement",
       "ForOfStatement", "WhileStatement", "DoWhileStatement", "BlockStatement", "TryStatement",
       "SwitchStatement", "LabeledStatement"] do
    n |> Map.drop(["type", "test", "id"]) |> Map.values() |> Enum.each(&hoist_children(env, sid, &1))
  end
  defp hoist_node(_env, _sid, _), do: :ok

  defp hoist_children(env, sid, l) when is_list(l), do: Enum.each(l, &hoist_children(env, sid, &1))
  defp hoist_children(env, sid, %{"type" => _} = n), do: hoist_node(env, sid, n)
  defp hoist_children(_env, _sid, _), do: :ok

  defp ensure_box(env, sid, name) do
    case find_box(env, name) do
      nil -> declare([sid], name, :undefined)
      box -> box
    end
  end

  # ── statements ──────────────────────────────────────────────────────────────────────────────────────────
  defp exec_all(nodes, env), do: Enum.each(nodes, &exec(&1, env))

  defp exec(%{"type" => "VariableDeclaration", "declarations" => ds}, env) do
    Enum.each(ds, fn d ->
      val = if d["init"], do: eval(d["init"], env), else: :undefined
      bind_pattern(d["id"], val, env, true)
    end)
  end

  defp exec(%{"type" => "FunctionDeclaration"}, _env), do: :ok
  defp exec(%{"type" => "ExpressionStatement", "expression" => e}, env), do: eval(e, env)
  defp exec(%{"type" => "EmptyStatement"}, _env), do: :ok
  defp exec(%{"type" => "BlockStatement", "body" => body}, env), do: exec_block(body, env)

  defp exec(%{"type" => "ReturnStatement", "argument" => a}, env),
    do: throw({:gg_return, (if a, do: eval(a, env), else: :undefined)})

  defp exec(%{"type" => "IfStatement", "test" => t, "consequent" => c, "alternate" => a}, env) do
    if Runtime.truthy(eval(t, env)), do: exec(c, env), else: (if a, do: exec(a, env))
  end

  defp exec(%{"type" => "ForStatement"} = n, env), do: exec_for(n, env, nil)

  defp exec_for(n, env, lbl) do
    e2 = push(env)
    case n["init"] do
      %{"type" => "VariableDeclaration"} = d -> hoist([hd(e2)], [d]); exec(d, e2)
      nil -> :ok
      i -> eval(i, e2)
    end
    loop_for(n, e2, lbl)
  end

  defp exec(%{"type" => "WhileStatement", "test" => t, "body" => b}, env), do: loop_while(t, b, env, nil)
  defp exec(%{"type" => "DoWhileStatement", "test" => t, "body" => b}, env) do
    catch_break(nil, fn -> do_once(b, env, nil); while_iter(t, b, env, nil) end)
  end

  defp exec(%{"type" => "ForOfStatement"} = n, env), do: for_each(n, :of, env, nil)
  defp exec(%{"type" => "ForInStatement"} = n, env), do: for_each(n, :in, env, nil)

  defp exec(%{"type" => "BreakStatement", "label" => l}, _env), do: throw({:walk_break, label_name(l)})
  defp exec(%{"type" => "ContinueStatement", "label" => l}, _env), do: throw({:walk_continue, label_name(l)})

  defp exec(%{"type" => "LabeledStatement", "label" => %{"name" => lbl}, "body" => body}, env) do
    catch_break(lbl, fn -> exec_labeled(body, env, lbl) end)
  end

  defp exec(%{"type" => "ThrowStatement", "argument" => a}, env), do: Runtime.throw_val(eval(a, env))

  defp exec(%{"type" => "TryStatement", "block" => blk, "handler" => h, "finalizer" => fin}, env) do
    try do
      try do
        exec(blk, env)
      catch
        :throw, {tag, v} when tag in [:gg_throw, :gg_guest_error] ->
          if h do
            e2 = push(env)
            if h["param"], do: bind_pattern(h["param"], v, e2, true)
            exec(h["body"], e2)
          else
            throw({tag, v})
          end
      end
    after
      if fin, do: exec(fin, env)
    end
  end

  defp exec(%{"type" => "SwitchStatement"} = n, env), do: exec_switch(n, env)

  defp exec(%{"type" => t} = n, env) when t in ["ClassDeclaration", "ClassExpression"] do
    val = eval_class(n, env)
    if n["id"], do: set_var(env, n["id"]["name"], val)
    val
  end

  defp exec(other, env), do: eval(other, env)

  defp exec_block(body, env) do
    e2 = push(env)
    hoist(e2, body)
    exec_all(body, e2)
  end

  # ── expressions ─────────────────────────────────────────────────────────────────────────────────────────
  defp eval(%{"type" => "Literal", "regex" => %{"pattern" => p, "flags" => f}}, _env), do: Runtime.regex(p, f)
  defp eval(%{"type" => "Literal", "value" => %{"$bigint" => s}}, _env), do: (case Integer.parse(s) do {i, _} -> i * 1.0; _ -> 0.0 end)
  defp eval(%{"type" => "Literal", "value" => v}, _env), do: lit(v)
  defp eval(%{"type" => "Identifier", "name" => n}, env), do: get_var(env, n)
  defp eval(%{"type" => "ThisExpression"}, env), do: get_var(env, "this")

  defp eval(%{"type" => "TemplateLiteral", "quasis" => qs, "expressions" => es}, env) do
    quasis = Enum.map(qs, fn q -> (q["value"] && q["value"]["cooked"]) || "" end)
    exprs = Enum.map(es, &eval(&1, env))
    interleave(quasis, exprs) |> Enum.reduce("", fn part, acc -> Runtime.binop(:+, acc, part) end)
  end

  defp eval(%{"type" => "ArrayExpression", "elements" => els}, env) do
    if Enum.any?(els, &(&1 && &1["type"] == "SpreadElement")) do
      parts = Enum.map(els, fn
        %{"type" => "SpreadElement", "argument" => a} -> {:spread, eval(a, env)}
        nil -> {:one, :undefined}
        e -> {:one, eval(e, env)}
      end)
      Runtime.aspread(parts)
    else
      Runtime.avec(Enum.map(els, fn nil -> :undefined; e -> eval(e, env) end))
    end
  end

  defp eval(%{"type" => "ObjectExpression", "properties" => props}, env) do
    Enum.reduce(props, Runtime.cell_new([]), fn p, acc ->
      case p do
        %{"type" => "SpreadElement", "argument" => a} -> Runtime.omerge(acc, eval(a, env))
        # accessor property `{ get x() {…} }` — install a getter marker (cell_oget invokes it on read).
        # Setters are stored as plain fns only to keep the key visible; property WRITES shadow them (v0 limit).
        %{"kind" => "get", "key" => k, "value" => v} ->
          key = if p["computed"], do: eval(k, env), else: key_of(k)
          Runtime.oput(acc, key, {:getter, eval(v, env)})
        %{"kind" => "set"} -> acc
        %{"key" => k, "value" => v, "computed" => computed} ->
          key = if computed, do: eval(k, env), else: key_of(k)
          Runtime.oput(acc, key, eval(v, env))
      end
    end)
  end

  defp eval(%{"type" => t} = f, env) when t in ["FunctionExpression", "ArrowFunctionExpression"],
    do: make_fn(f["params"], f["body"], env, f["async"] == true, t == "ArrowFunctionExpression", f["generator"] == true)

  # `a?.b()` / `a?.[k]` parse as ChainExpression wrapping the call/member (whose own `optional` flags
  # short-circuit) — unwrap, or the catch-all would silently evaluate the whole chain to undefined.
  defp eval(%{"type" => "ChainExpression", "expression" => e}, env), do: eval(e, env)

  defp eval(%{"type" => "YieldExpression", "argument" => a} = y, env) do
    v = if a, do: eval(a, env), else: :undefined
    if y["delegate"], do: Runtime.gen_yield_star(v), else: Runtime.gen_yield(v)
  end

  defp eval(%{"type" => t} = n, env) when t in ["ClassExpression", "ClassDeclaration"], do: eval_class(n, env)

  defp eval(%{"type" => "AwaitExpression", "argument" => a}, env), do: Runtime.await_(eval(a, env))

  defp eval(%{"type" => "UnaryExpression", "operator" => op, "argument" => a}, env), do: unary(op, a, env)
  defp eval(%{"type" => "UpdateExpression"} = n, env), do: update(n, env)

  defp eval(%{"type" => "BinaryExpression", "operator" => op, "left" => l, "right" => r}, env),
    do: Runtime.binop(binop_atom(op), eval(l, env), eval(r, env))

  defp eval(%{"type" => "LogicalExpression", "operator" => op, "left" => l, "right" => r}, env) do
    lv = eval(l, env)
    case op do
      "&&" -> if Runtime.truthy(lv), do: eval(r, env), else: lv
      "||" -> if Runtime.truthy(lv), do: lv, else: eval(r, env)
      "??" -> if Runtime.is_nullish(lv), do: eval(r, env), else: lv
    end
  end

  defp eval(%{"type" => "ConditionalExpression", "test" => t, "consequent" => c, "alternate" => a}, env),
    do: if(Runtime.truthy(eval(t, env)), do: eval(c, env), else: eval(a, env))

  defp eval(%{"type" => "SequenceExpression", "expressions" => es}, env),
    do: Enum.reduce(es, :undefined, fn e, _ -> eval(e, env) end)

  defp eval(%{"type" => "MemberExpression"} = m, env), do: eval_member(m, env)

  defp eval(%{"type" => "CallExpression", "callee" => callee} = n, env), do: eval_call(callee, n["arguments"], env, n["optional"] == true)
  # new RegExp(source, flags) — mirror Lower's special case (regex is built by the Runtime, not `construct`).
  defp eval(%{"type" => "NewExpression", "callee" => %{"type" => "Identifier", "name" => "RegExp"}, "arguments" => args}, env) do
    args = args || []
    src = if args != [], do: eval(Enum.at(args, 0), env), else: ""
    flags = if length(args) > 1, do: eval(Enum.at(args, 1), env), else: ""
    Runtime.regex(src, flags)
  end
  defp eval(%{"type" => "NewExpression", "callee" => callee, "arguments" => args}, env) do
    Runtime.construct(eval(callee, env), eval_args(args, env))
  end

  defp eval(%{"type" => "AssignmentExpression"} = n, env), do: eval_assign(n, env)

  defp eval(nil, _env), do: :undefined
  defp eval(_other, _env), do: :undefined

  # ── member / call / new ─────────────────────────────────────────────────────────────────────────────────
  defp eval_member(%{"object" => %{"type" => "Super"}, "property" => p, "computed" => computed}, env) do
    sup = get_var(env, "__superval")
    key = if computed, do: eval(p, env), else: key_of(p)
    Runtime.oget(Runtime.oget(sup, "prototype"), key)
  end
  defp eval_member(%{"object" => o, "property" => p} = m, env) do
    obj = eval(o, env)
    if m["optional"] && Runtime.is_nullish(obj) do
      :undefined
    else
      key = if m["computed"], do: eval(p, env), else: key_of(p)
      Runtime.oget(obj, key)
    end
  end

  # super(...) — call the parent ctor with the current `this`.
  defp eval_call(%{"type" => "Super"}, args, env, _opt) do
    sup = get_var(env, "__superval")
    this = get_var(env, "this")
    Runtime.invoke(sup, this, eval_args(args, env))
  end
  # super.m(...) — parent-prototype method with the current `this`.
  defp eval_call(%{"type" => "MemberExpression", "object" => %{"type" => "Super"}} = m, args, env, _opt) do
    sup = get_var(env, "__superval")
    this = get_var(env, "this")
    key = if m["computed"], do: eval(m["property"], env), else: key_of(m["property"])
    f = Runtime.oget(Runtime.oget(sup, "prototype"), key)
    Runtime.invoke(f, this, eval_args(args, env))
  end
  defp eval_call(%{"type" => "MemberExpression"} = m, args, env, optional) do
    obj = eval(m["object"], env)
    if (m["optional"] || optional) && Runtime.is_nullish(obj) do
      :undefined
    else
      key = if m["computed"], do: eval(m["property"], env), else: key_of(m["property"])
      # `o.f?.()` — the ?. guards the FUNCTION, not the receiver: a missing property yields undefined.
      if optional && Runtime.optcall_missing?(obj, key) do
        :undefined
      else
        Runtime.method(obj, key, eval_args(args, env))
      end
    end
  end
  defp eval_call(callee, args, env, optional) do
    f = eval(callee, env)
    a = eval_args(args, env)
    if optional && Runtime.is_nullish(f), do: :undefined, else: Runtime.call(f, a)
  end

  defp eval_args(args, env) do
    args = args || []
    if Enum.any?(args, &(&1["type"] == "SpreadElement")) do
      Runtime.spread_args(Enum.map(args, fn
        %{"type" => "SpreadElement", "argument" => a} -> {:spread, eval(a, env)}
        e -> {:one, eval(e, env)}
      end))
    else
      Enum.map(args, &eval(&1, env))
    end
  end

  # ── assignment ──────────────────────────────────────────────────────────────────────────────────────────
  defp eval_assign(%{"operator" => "=", "left" => l, "right" => r}, env) do
    case l do
      %{"type" => t} when t in ["ArrayPattern", "ObjectPattern"] ->
        v = eval(r, env); bind_pattern(l, v, env, false); v
      _ ->
        v = eval(r, env)
        assign_target(l, v, env); v
    end
  end
  defp eval_assign(%{"operator" => op, "left" => l, "right" => r}, env) when op in ["&&=", "||=", "??="] do
    cur = eval(l, env)
    proceed = case op do "&&=" -> Runtime.truthy(cur); "||=" -> not Runtime.truthy(cur); "??=" -> Runtime.is_nullish(cur) end
    if proceed, do: (v = eval(r, env); assign_target(l, v, env); v), else: cur
  end
  defp eval_assign(%{"operator" => op, "left" => l, "right" => r}, env) do
    bop = binop_atom(String.trim_trailing(op, "="))
    v = Runtime.binop(bop, eval(l, env), eval(r, env))
    assign_target(l, v, env)
    v
  end

  defp assign_target(%{"type" => "Identifier", "name" => n}, v, env), do: set_var(env, n, v)
  defp assign_target(%{"type" => "MemberExpression"} = m, v, env) do
    obj = eval(m["object"], env)
    key = if m["computed"], do: eval(m["property"], env), else: key_of(m["property"])
    Runtime.oput(obj, key, v)
    v
  end
  defp assign_target(_other, v, _env), do: v

  # ── destructuring ───────────────────────────────────────────────────────────────────────────────────────
  defp bind_pattern(%{"type" => "Identifier", "name" => n}, val, env, declare?),
    do: (if declare?, do: declare(env, n, val), else: set_var(env, n, val))
  defp bind_pattern(%{"type" => "MemberExpression"} = m, val, env, _declare?), do: assign_target(m, val, env)
  defp bind_pattern(%{"type" => "AssignmentPattern", "left" => l, "right" => r}, val, env, declare?) do
    v = if Runtime.binop(:===, val, :undefined) == true, do: eval(r, env), else: val
    bind_pattern(l, v, env, declare?)
  end
  defp bind_pattern(%{"type" => "ObjectPattern", "properties" => props}, val, env, declare?) do
    taken = for p <- props, p["type"] != "RestElement", do: key_str_of(p["key"])
    Enum.each(props, fn
      %{"type" => "RestElement", "argument" => a} -> bind_pattern(a, Runtime.orest(val, taken), env, declare?)
      %{"key" => k, "value" => v, "computed" => c} ->
        key = if c, do: eval(k, env), else: key_of(k)
        bind_pattern(v, Runtime.oget(val, key), env, declare?)
    end)
  end
  defp bind_pattern(%{"type" => "ArrayPattern", "elements" => els}, val, env, declare?) do
    els |> Enum.with_index() |> Enum.each(fn
      {nil, _} -> :ok
      {%{"type" => "RestElement", "argument" => a}, i} -> bind_pattern(a, Runtime.arest(val, i), env, declare?)
      {el, i} -> bind_pattern(el, Runtime.oget(val, i * 1.0), env, declare?)
    end)
  end
  defp bind_pattern(_, _, _, _), do: :ok

  # ── functions ───────────────────────────────────────────────────────────────────────────────────────────
  defp make_fn(params, body, defenv, async?, arrow?, gen? \\ false) do
    Runtime.closure(fn this, args ->
      scope = push(defenv)
      unless arrow? do
        declare(scope, "this", this)
        declare(scope, "arguments", Runtime.avec(args))
      end
      Enum.each(Enum.flat_map(params || [], &pattern_names/1), fn n -> ensure_box([hd(scope)], hd(scope), n) end)
      bind_params(params || [], args, scope)
      if gen? do
        Runtime.gen_begin()
        run_body(body, scope, false)
        Runtime.gen_end()
      else
        run_body(body, scope, async?)
      end
    end)
  end

  defp bind_params(params, args, env) do
    params
    |> Enum.with_index()
    |> Enum.each(fn
      {%{"type" => "RestElement", "argument" => a}, i} -> bind_pattern(a, Runtime.args_rest(args, i), env, true)
      {p, i} -> bind_pattern(p, Enum.at(args, i, :undefined), env, true)
    end)
  end

  defp run_body(body, env, async?) do
    thunk = fn ->
      case body do
        %{"type" => "BlockStatement", "body" => b} ->
          hoist(env, b)
          try do
            exec_all(b, env)
            :undefined
          catch
            :throw, {:gg_return, v} -> v
          end
        expr -> eval(expr, env)
      end
    end
    if async?, do: Runtime.promise_from(thunk), else: thunk.()
  end

  # ── classes ─────────────────────────────────────────────────────────────────────────────────────────────
  defp eval_class(n, env) do
    name = (n["id"] && n["id"]["name"]) || "__ggclass"
    members = (n["body"] && n["body"]["body"]) || []
    ctor = Enum.find(members, &(&1["kind"] == "constructor"))
    sup = if n["superClass"], do: eval(n["superClass"], env), else: nil

    cenv = push(env)

    ctor_fn =
      Runtime.closure(fn this, args ->
        s = push(cenv)
        declare(s, "this", this)
        declare(s, "arguments", Runtime.avec(args))
        if sup, do: declare(s, "__superval", sup)
        cparams = (ctor && ctor["value"]["params"]) || []
        Enum.each(Enum.flat_map(cparams, &pattern_names/1), fn nm -> ensure_box([hd(s)], hd(s), nm) end)
        bind_params(cparams, args, s)
        cond do
          ctor -> run_ctor_body(ctor["value"]["body"], s)
          # a derived class with NO explicit constructor gets the implicit `constructor(...args){ super(...args) }`
          # — run the parent ctor with all args so its field initialization happens.
          sup -> Runtime.invoke(sup, this, args)
          true -> :ok
        end
        this
      end)

    declare(cenv, name, ctor_fn)
    if sup, do: Runtime.set_proto_chain(ctor_fn, sup)

    proto = Runtime.oget(ctor_fn, "prototype")
    Enum.each(members, fn m ->
      unless m["kind"] == "constructor" do
        target = if m["static"], do: ctor_fn, else: proto
        key = if m["computed"], do: eval(m["key"], cenv), else: key_of(m["key"])
        fnv = make_super_method(m["value"], cenv, sup)
        case m["kind"] do
          k when k in ["get", "set"] ->
            desc = Runtime.cell_new([{k, fnv}])
            Runtime.method({:global, "Object"}, "defineProperty", [target, Runtime.to_str(key), desc])
          _ -> Runtime.oput(target, key, fnv)
        end
      end
    end)

    ctor_fn
  end

  defp make_super_method(fnode, cenv, sup) do
    Runtime.closure(fn this, args ->
      s = push(cenv)
      declare(s, "this", this)
      declare(s, "arguments", Runtime.avec(args))
      if sup, do: declare(s, "__superval", sup)
      params = fnode["params"] || []
      Enum.each(Enum.flat_map(params, &pattern_names/1), fn nm -> ensure_box([hd(s)], hd(s), nm) end)
      bind_params(params, args, s)
      if fnode["generator"] == true do
        Runtime.gen_begin()
        run_body(fnode["body"], s, false)
        Runtime.gen_end()
      else
        run_body(fnode["body"], s, fnode["async"] == true)
      end
    end)
  end

  defp run_ctor_body(%{"type" => "BlockStatement", "body" => b}, env) do
    hoist(env, b)
    try do
      exec_all(b, env)
    catch
      :throw, {:gg_return, _v} -> :ok
    end
  end

  # ── loops ───────────────────────────────────────────────────────────────────────────────────────────────
  defp loop_for(%{"test" => t, "update" => u, "body" => b}, env, lbl), do: catch_break(lbl, fn -> for_iter(t, u, b, env, lbl) end)
  defp for_iter(t, u, b, env, lbl) do
    if t == nil or Runtime.truthy(eval(t, env)) do
      catch_continue(lbl, fn -> exec(b, env) end)
      if u, do: eval(u, env)
      for_iter(t, u, b, env, lbl)
    end
  end

  defp loop_while(t, b, env, lbl), do: catch_break(lbl, fn -> while_iter(t, b, env, lbl) end)
  defp while_iter(t, b, env, lbl) do
    if Runtime.truthy(eval(t, env)) do
      catch_continue(lbl, fn -> exec(b, env) end)
      while_iter(t, b, env, lbl)
    end
  end
  defp do_once(b, env, lbl), do: catch_continue(lbl, fn -> exec(b, env) end)

  defp for_each(%{"left" => left, "right" => right, "body" => body}, kind, env, lbl) do
    coll = eval(right, env)
    # for-of steps a LIVE cursor: JS iterators see entries appended during the loop (rollup grows Sets/arrays
    # mid-iteration to close over dependency graphs). for-in keeps snapshot keys.
    catch_break(lbl, fn ->
      if kind == :of do
        for_cursor(Runtime.iter_start(coll), left, body, env, lbl)
      else
        Enum.each(Runtime.enum_keys(coll), fn item ->
          e2 = push(env)
          bind_for_target(left, item, e2)
          catch_continue(lbl, fn -> exec(body, e2) end)
        end)
      end
    end)
  end

  defp for_cursor(cur, left, body, env, lbl) do
    case Runtime.iter_next(cur) do
      :done ->
        :ok

      {item, cur2} ->
        e2 = push(env)
        bind_for_target(left, item, e2)
        catch_continue(lbl, fn -> exec(body, e2) end)
        for_cursor(cur2, left, body, env, lbl)
    end
  end

  defp bind_for_target(%{"type" => "VariableDeclaration", "declarations" => [%{"id" => id} | _]}, item, env),
    do: bind_pattern(id, item, env, true)
  defp bind_for_target(target, item, env), do: bind_pattern(target, item, env, false)

  defp catch_break(lbl, fun) do
    try do
      fun.()
    catch
      :throw, {:walk_break, l} when l == nil or l == lbl -> :ok
    end
  end
  defp catch_continue(lbl, fun) do
    try do
      fun.()
    catch
      :throw, {:walk_continue, l} when l == nil or l == lbl -> :ok
    end
  end

  # a label on a LOOP threads down so `continue <label>` is caught at that loop's iteration boundary
  # (`break <label>` is already caught by the LabeledStatement's catch_break above).
  defp exec_labeled(%{"type" => "ForStatement"} = n, env, lbl), do: exec_for(n, env, lbl)
  defp exec_labeled(%{"type" => "WhileStatement", "test" => t, "body" => b}, env, lbl), do: loop_while(t, b, env, lbl)
  defp exec_labeled(%{"type" => "DoWhileStatement", "test" => t, "body" => b}, env, lbl),
    do: catch_break(lbl, fn -> do_once(b, env, lbl); while_iter(t, b, env, lbl) end)
  defp exec_labeled(%{"type" => "ForOfStatement"} = n, env, lbl), do: for_each(n, :of, env, lbl)
  defp exec_labeled(%{"type" => "ForInStatement"} = n, env, lbl), do: for_each(n, :in, env, lbl)
  defp exec_labeled(body, env, _lbl), do: exec(body, env)

  # ── switch ──────────────────────────────────────────────────────────────────────────────────────────────
  defp exec_switch(%{"discriminant" => d, "cases" => cases}, env) do
    dv = eval(d, env)
    e2 = push(env)
    catch_break(nil, fn ->
      matched =
        Enum.reduce(cases, false, fn c, m ->
          m2 = m or (c["test"] != nil and Runtime.binop(:===, dv, eval(c["test"], e2)) == true)
          if m2, do: exec_all(c["consequent"], e2)
          m2
        end)
      unless matched do
        Enum.each(cases, fn c -> if c["test"] == nil, do: exec_all(c["consequent"], e2) end)
      end
    end)
  end

  # ── unary / update ──────────────────────────────────────────────────────────────────────────────────────
  defp unary("typeof", %{"type" => "Identifier", "name" => n}, env), do: Runtime.typeof(get_var(env, n))
  defp unary("typeof", a, env), do: Runtime.typeof(eval(a, env))
  defp unary("!", a, env), do: not Runtime.truthy(eval(a, env))
  defp unary("-", a, env), do: Runtime.binop(:-, 0.0, eval(a, env))
  defp unary("+", a, env), do: Runtime.to_number(eval(a, env))
  defp unary("~", a, env), do: Runtime.binop(:bxor, -1.0, eval(a, env))
  defp unary("void", a, env), do: (eval(a, env); :undefined)
  defp unary("delete", %{"type" => "MemberExpression"} = m, env) do
    obj = eval(m["object"], env)
    key = if m["computed"], do: eval(m["property"], env), else: key_of(m["property"])
    Runtime.method({:global, "Reflect"}, "deleteProperty", [obj, key]); true
  end
  defp unary("delete", _a, _env), do: true
  defp unary(_op, a, env), do: eval(a, env)

  defp update(%{"operator" => op, "argument" => arg, "prefix" => prefix}, env) do
    old = Runtime.to_number(eval(arg, env))
    new = Runtime.binop((if op == "++", do: :+, else: :-), old, 1.0)
    assign_target(arg, new, env)
    if prefix, do: new, else: old
  end

  # ── shared helpers ─────────────────────────────────────────────────────────────────────────────────────
  defp lit(v) when is_integer(v), do: v * 1.0
  defp lit(v) when is_float(v), do: v
  defp lit(v) when is_binary(v), do: v
  defp lit(true), do: true
  defp lit(false), do: false
  defp lit(nil), do: :null
  defp lit(_), do: :undefined

  defp key_of(%{"type" => "Identifier", "name" => n}), do: n
  defp key_of(%{"type" => "Literal", "value" => v}) when is_binary(v), do: v
  defp key_of(%{"type" => "Literal", "value" => v}) when is_number(v), do: Runtime.to_str(v * 1.0)
  defp key_of(%{"type" => "Literal", "value" => v}), do: to_string(v)
  defp key_of(other), do: inspect(other)

  defp key_str_of(%{"name" => n}), do: n
  defp key_str_of(%{"value" => v}) when is_binary(v), do: v
  defp key_str_of(%{"value" => v}), do: to_string(v)
  defp key_str_of(_), do: ""

  defp label_name(nil), do: nil
  defp label_name(%{"name" => n}), do: n

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

  defp pattern_names(%{"type" => "Identifier", "name" => n}), do: [n]
  defp pattern_names(%{"type" => "AssignmentPattern", "left" => l}), do: pattern_names(l)
  defp pattern_names(%{"type" => "RestElement", "argument" => a}), do: pattern_names(a)
  defp pattern_names(%{"type" => "ArrayPattern", "elements" => els}), do: Enum.flat_map(els || [], fn nil -> []; e -> pattern_names(e) end)
  defp pattern_names(%{"type" => "ObjectPattern", "properties" => props}) do
    Enum.flat_map(props, fn
      %{"type" => "RestElement", "argument" => a} -> pattern_names(a)
      %{"value" => v} -> pattern_names(v)
      _ -> []
    end)
  end
  defp pattern_names(_), do: []

  defp interleave([q], []), do: [q]
  defp interleave([q | qs], [e | es]), do: [q, e | interleave(qs, es)]
  defp interleave(qs, _), do: qs

  defp uid do
    n = Process.get(:walk_uid, 0)
    Process.put(:walk_uid, n + 1)
    n
  end
end
