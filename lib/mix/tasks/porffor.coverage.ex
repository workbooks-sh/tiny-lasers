defmodule Mix.Tasks.Porffor.Coverage do
  @moduledoc "Report WASM→BEAM ASM transpile coverage for a JS program."
  use Mix.Task

  @shortdoc "ASM transpile coverage % for a JS file"

  @switches [entry: :string]

  def run(argv) do
    Mix.Task.run("app.start")
    {opts, files, _} = OptionParser.parse(argv, switches: @switches)

    case files do
      [path | _] ->
        js = File.read!(path)
        entry = opts[:entry] || "m"

        case TinyLasers.Js.AsmCoverage.analyze_source(js, entry: entry) do
          {:ok, report} -> IO.puts(TinyLasers.Js.AsmCoverage.format(report))
          {:error, reason} -> Mix.raise("coverage failed: #{inspect(reason)}")
        end

      [] ->
        Mix.raise("usage: mix porffor.coverage <file.js> [--entry m]")
    end
  end
end
