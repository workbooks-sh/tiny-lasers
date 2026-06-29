defmodule TinyLasers.Wasm.Validate do
  @moduledoc """
  **Structural validation** of a decoded module — the front gate for untrusted input. It rejects a
  module whose *references don't resolve* (a `call` to a function index that doesn't exist, a
  `local.get` past the frame, a `func` whose type index is out of range, an export/element pointing at
  a missing function, a memory op with no memory) **before** instantiation, with a clean
  `{:error, {:invalid, reason}}` — instead of letting the interpreter discover it mid-run as an opaque
  `Enum.at(_, huge) == nil` crash.

  This is the spec's `assert_invalid`/`assert_malformed` surface for the structural subset. Full
  *type* validation (operand-stack typing per instruction) is a later increment; the differential
  oracle + spec suite catch ill-typed-but-structurally-valid modules in the meantime. Crash-safety for
  untrusted input does not depend on full typing — it depends on every index being in range, which is
  what this enforces.
  """
  alias TinyLasers.Wasm

  # instruction tags that require a linear memory to be present
  @mem_ops MapSet.new([
             :i32_load, :i32_load8u, :i32_load8s, :i32_load16u, :i32_load16s,
             :i64_load, :i32_store, :i32_store8, :i32_store16, :i64_store,
             :f32_load, :f64_load, :f32_store, :f64_store,
             :memory_size, :memory_grow, :memory_copy, :memory_fill
           ])

  @doc "Validate a decoded module. → `:ok | {:error, {:invalid, reason}}`."
  def validate(%Wasm{} = mod) do
    n_imports = length(mod.imports)
    n_types = length(mod.types)
    n_funcs = n_imports + length(mod.funcs)
    n_globals = length(mod.globals)
    has_mem? = mod.mem != nil

    with :ok <- check_func_types(mod.funcs, n_types),
         :ok <- check_code_arity(mod.code, mod.funcs),
         :ok <- check_exports(mod.exports, n_funcs),
         :ok <- check_elements(mod.elements, n_funcs),
         :ok <- check_bodies(mod, n_types, n_funcs, n_globals, has_mem?) do
      :ok
    end
  end

  @doc "Decode then validate. → `{:ok, mod} | {:error, reason}`."
  def decode_validated(bytes) when is_binary(bytes) do
    with {:ok, mod} <- Wasm.decode(bytes),
         :ok <- validate(mod) do
      {:ok, mod}
    end
  end

  # every local func's declared type index must be in range
  defp check_func_types(funcs, n_types) do
    case Enum.find(funcs, &(&1 >= n_types or &1 < 0)) do
      nil -> :ok
      bad -> invalid({:func_type_index, bad, n_types})
    end
  end

  # one code body per declared local function
  defp check_code_arity(code, funcs) do
    if length(code) == length(funcs), do: :ok, else: invalid({:code_count, length(code), length(funcs)})
  end

  defp check_exports(exports, n_funcs) do
    case Enum.find(exports, fn {_name, idx} -> idx >= n_funcs or idx < 0 end) do
      nil -> :ok
      {name, idx} -> invalid({:export_func_index, name, idx, n_funcs})
    end
  end

  defp check_elements(elements, n_funcs) do
    bad =
      Enum.find_value(elements, fn {_offset, funcs} ->
        Enum.find(funcs, &(&1 >= n_funcs or &1 < 0))
      end)

    if bad, do: invalid({:element_func_index, bad, n_funcs}), else: :ok
  end

  # walk every function body (recursing into block/loop/if) checking each index-bearing instruction
  defp check_bodies(mod, n_types, n_funcs, n_globals, has_mem?) do
    mod.code
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {{nlocals, instrs}, i}, :ok ->
      tidx = Enum.at(mod.funcs, i)
      {params, _results} = Enum.at(mod.types, tidx)
      n_locals = length(params) + nlocals
      ctx = %{n_types: n_types, n_funcs: n_funcs, n_globals: n_globals, n_locals: n_locals, has_mem?: has_mem?}

      case walk(instrs, ctx) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp walk(instrs, ctx), do: Enum.reduce_while(instrs, :ok, fn instr, :ok ->
    case check_instr(instr, ctx) do
      :ok -> {:cont, :ok}
      err -> {:halt, err}
    end
  end)

  defp check_instr({:block, body}, ctx), do: walk(body, ctx)
  defp check_instr({:loop, body}, ctx), do: walk(body, ctx)
  defp check_instr({:if, then_b, else_b}, ctx), do: with(:ok <- walk(then_b, ctx), do: walk(else_b, ctx))

  defp check_instr({:call, f}, ctx),
    do: if(f < ctx.n_funcs and f >= 0, do: :ok, else: invalid({:call_index, f, ctx.n_funcs}))

  defp check_instr({:call_indirect, t}, ctx),
    do: if(t < ctx.n_types and t >= 0, do: :ok, else: invalid({:call_indirect_type, t, ctx.n_types}))

  defp check_instr({op, i}, ctx) when op in [:local_get, :local_set, :local_tee],
    do: if(i < ctx.n_locals and i >= 0, do: :ok, else: invalid({op, i, ctx.n_locals}))

  defp check_instr({op, i}, ctx) when op in [:global_get, :global_set],
    do: if(i < ctx.n_globals and i >= 0, do: :ok, else: invalid({op, i, ctx.n_globals}))

  defp check_instr(instr, ctx) do
    if elem(instr, 0) in @mem_ops and not ctx.has_mem? do
      invalid({:memory_op_without_memory, elem(instr, 0)})
    else
      :ok
    end
  end

  defp invalid(reason), do: {:error, {:invalid, reason}}
end
