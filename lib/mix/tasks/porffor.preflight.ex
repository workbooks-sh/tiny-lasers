defmodule Mix.Tasks.Porffor.Preflight do
  @moduledoc "AST preflight scan for known Porffor lane seams."
  use Mix.Task

  @shortdoc "Preflight-scan a JS file for known compile/runtime seams"

  def run(argv) do
    Mix.Task.run("app.start")

    case argv do
      [path | _] ->
        case TinyLasers.Js.Preflight.scan_file(path) do
          {:ok, report} -> IO.puts(TinyLasers.Js.Preflight.format(report))
          {:error, reason} -> Mix.raise("preflight failed: #{inspect(reason)}")
        end

      [] ->
        Mix.raise("usage: mix porffor.preflight <file.js>")
    end
  end
end
