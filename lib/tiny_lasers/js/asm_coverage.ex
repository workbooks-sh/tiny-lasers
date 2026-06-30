defmodule TinyLasers.Js.AsmCoverage do
  @moduledoc """
  WASM→BEAM ASM transpile coverage report for a compiled Porffor module.

  Measures how many **reachable** local functions lower to native BEAM ASM vs interpreter fallback.
  """

  alias TinyLasers.Wasm.Transpile
  alias TinyLasers.Wasm.TranspileAsm

  @batch 64

  defmodule Report do
    @moduledoc false
    defstruct total: 0, asm_native: 0, interp_fallback: 0, pct: 0.0, entry: "m", wasm_kb: 0
  end

  @doc "Analyze `wasm_bytes`; returns `{:ok, %Report{}}` or `{:error, reason}`."
  def analyze(wasm_bytes, opts \\ []) when is_binary(wasm_bytes) do
    entry = Keyword.get(opts, :entry, "m")

    with {:ok, mod} <- TinyLasers.Wasm.decode(wasm_bytes) do
      reachable = Transpile.reachable_gfidxs(mod, entry)

      {asm_native, interp_fallback} =
        reachable
        |> Enum.chunk_every(@batch)
        |> Enum.reduce({0, 0}, fn chunk, {a, i} ->
          case TranspileAsm.compile_module(mod, chunk) do
            {:ok, _m, map, leftover, _tok} ->
              {a + map_size(map), i + length(leftover)}

            :none ->
              {a, i + length(chunk)}

            _ ->
              {a, i + length(chunk)}
          end
        end)

      total = asm_native + interp_fallback
      pct = if total > 0, do: Float.round(asm_native * 100 / total, 1), else: 0.0

      {:ok,
       %Report{
         total: total,
         asm_native: asm_native,
         interp_fallback: interp_fallback,
         pct: pct,
         entry: entry,
         wasm_kb: div(byte_size(wasm_bytes), 1024)
       }}
    end
  end

  @doc "Compile JS source then analyze ASM coverage."
  def analyze_source(source, opts \\ []) when is_binary(source) do
    alias TinyLasers.Js.Porffor

    compile_opts = Keyword.take(opts, [:root, :skip_invariants, :debug, :report_error, :flags])

    with {:ok, wasm} <- Porffor.compile(source, Keyword.get(opts, :root, default_root()), compile_opts) do
      analyze(wasm, opts)
    end
  end

  defp default_root do
    Enum.find(["compilers", Path.expand("compilers", File.cwd!())], &File.dir?/1) || "compilers"
  end

  @doc "Pretty one-line + detail for CLI."
  def format(%Report{} = r) do
    "ASM coverage: #{r.asm_native}/#{r.total} (#{r.pct}%) native, #{r.interp_fallback} interp fallback  " <>
      "(entry #{r.entry}, wasm #{r.wasm_kb}KB)\n"
  end
end
