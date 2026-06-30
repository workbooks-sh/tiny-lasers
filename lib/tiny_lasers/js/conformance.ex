defmodule TinyLasers.Js.Conformance do
  @moduledoc """
  Facade for the **predictive conformance stack** — cheap gates before test262/npm bundles.

  Tiers (cheapest first):
    1. `preflight/1` — AST seam scanner
    2. `invariants/1` — closure-conversion output invariants
    3. `census/1` — feature probe matrix vs node
    4. `asm_coverage/1` — WASM→ASM native %
    5. test262 / bundle gates (via mix tasks)

  Use `mix porffor.check` for the full developer workflow.
  """

  alias TinyLasers.Js.{AsmCoverage, Census, Preflight, Porffor}

  @doc "Run preflight scanner on JS source."
  def preflight(source, opts \\ []), do: Preflight.scan(source, opts)

  @doc "Run closure-conversion invariant check on JS source (post-transform)."
  def invariants(source, opts \\ []), do: Porffor.check_invariants(source, opts)

  @doc "Run feature census; opts `:compare`, `:enforce` forwarded to `Census.report/1`."
  def census(opts \\ []), do: Census.report(opts)

  @doc "ASM transpile coverage for compiled wasm or source."
  def asm_coverage(source_or_wasm, opts \\ [])

  def asm_coverage(source, opts) when is_binary(source) do
    if Keyword.get(opts, :wasm, false) do
      AsmCoverage.analyze(source, opts)
    else
      AsmCoverage.analyze_source(source, opts)
    end
  end

  @doc """
  Compile report: preflight warnings + invariant status + optional ASM coverage.
  Returns `{:ok, map}` or `{:error, reason}`.
  """
  def compile_report(source, opts \\ []) when is_binary(source) do
    pre = if Keyword.get(opts, :preflight, true), do: Preflight.scan(source, opts), else: {:ok, %Preflight.Report{}}
    inv = if Keyword.get(opts, :invariants, true), do: Porffor.check_invariants(source, opts), else: {:ok, :skipped}

    with {:ok, preflight} <- pre,
         {:ok, inv_result} <- inv do
      cov =
        if Keyword.get(opts, :coverage, false) do
          case Porffor.compile(source, Keyword.get(opts, :root, default_root()), Keyword.take(opts, [:skip_invariants])) do
            {:ok, wasm} -> AsmCoverage.analyze(wasm, opts)
            err -> err
          end
        else
          {:ok, nil}
        end

      with {:ok, coverage} <- cov do
        {:ok, %{preflight: preflight, invariants: inv_result, coverage: coverage}}
      end
    end
  end

  defp default_root do
    Enum.find(["compilers", Path.expand("compilers", File.cwd!())], &File.dir?/1) || "compilers"
  end
end
