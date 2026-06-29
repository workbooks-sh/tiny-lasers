defmodule TinyLasers.Gate.Codegen do
  @moduledoc """
  Confined codegen: guest-AST -> Elixir quoted AST -> (driver compiles to native BEAM).

  The whole point: the emitted module references EXACTLY ONE external module —
  `TinyLasers.Gate.Runtime` — and never atomizes guest data. The compile-time gate
  lives in `comp/2` for `{:var, name}`: an identifier that is neither a local nor a
  granted capability resolves to `:undefined`. There is no codegen path that turns a
  guest identifier into a host module reference, so `os.cmd(...)` cannot be emitted —
  `os` is simply `:undefined`, and calling it is a guest TypeError.

  Guest AST (plain Elixir data — a real frontend would parse JS to this):

      {:lit, number | binary | boolean}     {:undef}
      {:var, name}                           {:binop, op, l, r}
      {:obj, [{k_ast, v_ast}, ...]}          {:get, o, k}        {:set, o, k, v}
      {:call, callee, [arg, ...]}            {:fn, [param, ...], body}
      {:let, name, val}                      {:seq, [stmt, ...]}
      {:spin}                                {:mem_bomb}
  """

  @runtime TinyLasers.Gate.Runtime

  @doc "Build a quoted module `modname` with a `run/0` whose body is the compiled guest."
  def module(modname, ast, granted) do
    {body, _env} = comp(ast, %{locals: MapSet.new(), granted: granted})

    quote do
      defmodule unquote(modname) do
        def run, do: unquote(body)
      end
    end
  end

  # ── literals ──
  def comp({:lit, v}, env), do: {lit(v), env}
  def comp({:undef}, env), do: {:undefined, env}

  # ── variable resolution = the compile-time capability gate ──
  def comp({:var, name}, env) do
    cond do
      MapSet.member?(env.locals, name) ->
        {Macro.var(local_var(name), nil), env}

      Map.has_key?(env.granted, name) ->
        # a granted capability compiles to its handle — never a module atom
        {quote(do: {:host, unquote(env.granted[name])}), env}

      true ->
        # unknown identifier -> undefined. THIS is why `os` / `File` / `:erlang`
        # can never appear in the emitted bytecode.
        {:undefined, env}
    end
  end

  # ── operators / structures (all routed through the confined Runtime) ──
  def comp({:binop, op, l, r}, env) do
    {lq, _} = comp(l, env)
    {rq, _} = comp(r, env)
    {quote(do: unquote(@runtime).binop(unquote(op), unquote(lq), unquote(rq))), env}
  end

  def comp({:obj, pairs}, env) do
    pairlist =
      Enum.map(pairs, fn {k, v} ->
        {kq, _} = comp(k, env)
        {vq, _} = comp(v, env)
        quote(do: {unquote(kq), unquote(vq)})
      end)

    {quote(do: unquote(@runtime).obj_new(unquote(pairlist))), env}
  end

  def comp({:get, o, k}, env) do
    {oq, _} = comp(o, env)
    {kq, _} = comp(k, env)
    {quote(do: unquote(@runtime).get(unquote(oq), unquote(kq))), env}
  end

  def comp({:set, o, k, v}, env) do
    {oq, _} = comp(o, env)
    {kq, _} = comp(k, env)
    {vq, _} = comp(v, env)
    {quote(do: unquote(@runtime).set(unquote(oq), unquote(kq), unquote(vq))), env}
  end

  def comp({:call, callee, args}, env) do
    {cq, _} = comp(callee, env)
    argq = Enum.map(args, fn a -> {q, _} = comp(a, env); q end)
    {quote(do: unquote(@runtime).call(unquote(cq), unquote(argq))), env}
  end

  def comp({:fn, params, body}, env) do
    argvar = Macro.var(:gg_args, nil)
    inner = Enum.reduce(params, env.locals, &MapSet.put(&2, &1))

    binds =
      params
      |> Enum.with_index()
      |> Enum.map(fn {p, i} ->
        quote do
          unquote(Macro.var(local_var(p), nil)) = unquote(@runtime).arg(unquote(argvar), unquote(i))
        end
      end)

    {bodyq, _} = comp(body, %{env | locals: inner})

    fnq =
      quote do
        unquote(@runtime).fun_new(fn unquote(argvar) ->
          unquote_splicing(binds ++ [bodyq])
        end)
      end

    {fnq, env}
  end

  # ── statements that thread scope ──
  def comp({:let, name, val}, env) do
    {vq, _} = comp(val, env)
    q = quote(do: unquote(Macro.var(local_var(name), nil)) = unquote(vq))
    {q, %{env | locals: MapSet.put(env.locals, name)}}
  end

  def comp({:seq, stmts}, env) do
    {rev, env2} =
      Enum.reduce(stmts, {[], env}, fn s, {acc, e} ->
        {q, e2} = comp(s, e)
        {[q | acc], e2}
      end)

    {{:__block__, [], Enum.reverse(rev)}, env2}
  end

  # ── DoS primitives (for containment tests; still route through the confined Runtime) ──
  def comp({:spin}, env), do: {quote(do: unquote(@runtime).spin()), env}
  def comp({:mem_bomb}, env), do: {quote(do: unquote(@runtime).mem_bomb()), env}

  # ── helpers ──
  defp lit(v) when is_integer(v), do: v * 1.0
  defp lit(v) when is_float(v), do: v
  defp lit(v) when is_binary(v), do: v
  defp lit(true), do: true
  defp lit(false), do: false

  # Identifier -> local var atom. Compile-time only (a fixed program's identifiers),
  # never guest runtime data, so this does not widen the runtime atom-domain firewall.
  defp local_var(name), do: String.to_atom("gg_" <> name)
end
