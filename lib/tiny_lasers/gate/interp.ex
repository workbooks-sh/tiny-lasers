defmodule TinyLasers.Gate.Interp do
  @moduledoc """
  Confined tree-walk interpreter for `eval`'d guest code.

  `eval` deliberately does NOT compile (compiling per-eval would mint module +
  identifier atoms — a node-wide, permanent atom-exhaustion DoS). Instead it
  interprets the guest AST over the SAME closed value-universe and the SAME dispatch
  gate (`Runtime.call/get/binop/host_call`), with the SAME identifier-resolution rule
  as the compiler: a name is a local, else a granted capability handle, else
  `:undefined`. So eval'd code is exactly as confined as compiled code — `os` is
  `:undefined`, never a module — and the interpreter creates no atoms from guest data.

  This is the natural hybrid: AOT-native for the module body, interpreted-confined for
  the rare `eval`. Authority comes from `ctx` (the parent's grant), never widened.
  """

  alias TinyLasers.Gate.Runtime

  @doc "Interpret a guest AST under the run ctx. `scope` is a name=>value map for eval-locals."
  def run(ast, ctx, scope \\ %{}), do: elem(ev(ast, ctx, scope), 0)

  # returns {value, scope} so `let` can thread bindings through a seq
  defp ev({:lit, v}, _ctx, scope) when is_number(v), do: {v * 1.0, scope}
  defp ev({:lit, v}, _ctx, scope), do: {v, scope}
  defp ev({:undef}, _ctx, scope), do: {:undefined, scope}

  defp ev({:var, name}, ctx, scope) do
    val =
      cond do
        Map.has_key?(scope, name) -> Map.get(scope, name)
        # granted capability -> its handle. The interpreter's gate, identical to the compiler's.
        Map.has_key?(ctx.granted, name) -> {:host, Map.fetch!(ctx.granted, name)}
        # unknown identifier -> undefined. `os`/`File`/`:erlang` are unreachable, by construction.
        true -> :undefined
      end

    {val, scope}
  end

  defp ev({:binop, op, l, r}, ctx, scope) do
    {lv, _} = ev(l, ctx, scope)
    {rv, _} = ev(r, ctx, scope)
    {Runtime.binop(op, lv, rv), scope}
  end

  defp ev({:obj, pairs}, ctx, scope) do
    built =
      Enum.map(pairs, fn {k, v} ->
        {kv, _} = ev(k, ctx, scope)
        {vv, _} = ev(v, ctx, scope)
        {kv, vv}
      end)

    {Runtime.obj_new(built), scope}
  end

  defp ev({:get, o, k}, ctx, scope) do
    {ov, _} = ev(o, ctx, scope)
    {kv, _} = ev(k, ctx, scope)
    {Runtime.get(ov, kv), scope}
  end

  defp ev({:set, o, k, v}, ctx, scope) do
    {ov, _} = ev(o, ctx, scope)
    {kv, _} = ev(k, ctx, scope)
    {vv, _} = ev(v, ctx, scope)
    {Runtime.set(ov, kv, vv), scope}
  end

  defp ev({:call, callee, args}, ctx, scope) do
    {cv, _} = ev(callee, ctx, scope)
    argv = Enum.map(args, fn a -> {v, _} = ev(a, ctx, scope); v end)
    # dispatch through the SAME gate — only guest closures or granted host handles resolve
    {Runtime.call(cv, argv), scope}
  end

  defp ev({:let, name, val}, ctx, scope) do
    {v, _} = ev(val, ctx, scope)
    {v, Map.put(scope, name, v)}
  end

  defp ev({:seq, stmts}, ctx, scope) do
    Enum.reduce(stmts, {:undefined, scope}, fn s, {_acc, sc} -> ev(s, ctx, sc) end)
  end

  defp ev(_unknown, _ctx, scope), do: {:undefined, scope}
end
