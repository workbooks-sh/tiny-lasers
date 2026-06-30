defmodule Mix.Tasks.Porffor.Check do
  @moduledoc """
  Run the predictive conformance stack (cheapest gates first).

      mix porffor.check [file.js] [--test262] [--skip-census]
  """
  use Mix.Task

  @shortdoc "Run predictive conformance stack (preflight → invariants → census → optional test262)"

  @switches [test262: :boolean, skip_census: :boolean, coverage: :boolean]

  def run(argv) do
    Mix.Task.run("app.start")
    {opts, files, _} = OptionParser.parse(argv, switches: @switches)

    rows = []

    rows =
      case files do
        [path | _] ->
          js = File.read!(path)

          pre =
            case TinyLasers.Js.Preflight.scan(js) do
              {:ok, r} -> {"preflight", if(r.hard_block, do: :fail, else: :report), length(r.warnings)}
              {:error, e} -> {"preflight", :error, inspect(e)}
            end

          inv =
            case TinyLasers.Js.Porffor.check_invariants(js) do
              {:ok, :clean} -> {"invariants", :pass, 0}
              {:error, {:invariant, inv, _}} -> {"invariants", :fail, inv}
              {:error, e} -> {"invariants", :error, inspect(e)}
            end

          cov =
            if opts[:coverage] do
              case TinyLasers.Js.AsmCoverage.analyze_source(js) do
                {:ok, r} -> {"asm_coverage", :report, "#{r.pct}% (#{r.asm_native}/#{r.total})"}
                {:error, e} -> {"asm_coverage", :error, inspect(e)}
              end
            else
              nil
            end

          base_rows = [pre, inv, cov] |> Enum.reject(&is_nil/1)
          base_rows ++ rows

        [] ->
          rows
      end

    unless opts[:skip_census] do
      results = TinyLasers.Js.Census.run()
      pass = Enum.count(results, fn {_, _, s, _, _} -> s == :pass end)
      total = Enum.count(results, fn {_, _, s, _, _} -> s != :oracle_skip end)
      rows = [{"census", :report, "#{pass}/#{total}"} | rows]
    end

    if opts[:test262] do
      base = Path.join([File.cwd!(), "test", "conformance", "test262", "cases"])
      hdir = Path.join([File.cwd!(), "test", "conformance", "test262", "harness"])

      if File.dir?(base) do
        {_results, summary} = TinyLasers.Js.Test262.run_dir(base, harness_dir: hdir, limit: 50)
        rows = [{"test262_sample", :report, "#{summary.pass}/#{summary.total - summary.skip}"} | rows]
      end
    end

    IO.puts("\n=== porffor.check summary ===\n")

    for {name, status, detail} <- Enum.reverse(rows) do
      IO.puts("#{String.pad_trailing(name, 16)} #{pad_status(status)}  #{detail}")
    end

    IO.puts("")

    fails = Enum.count(rows, fn {_, s, _} -> s == :fail end)

    if fails > 0 do
      Mix.raise("#{fails} hard-fail gate(s) — see summary above")
    end
  end

  defp pad_status(:pass), do: "PASS "
  defp pad_status(:fail), do: "FAIL "
  defp pad_status(:report), do: "INFO "
  defp pad_status(:error), do: "ERR  "
  defp pad_status(other), do: "#{other}   "
end
