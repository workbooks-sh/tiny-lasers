defmodule Mix.Tasks.Porffor.Debug do
  @moduledoc "Profile JS on the Porffor→TinyLasers.Wasm lane. See `TinyLasers.Js.Debug`."
  use Mix.Task

  @shortdoc "Profile a JS file on the Porffor→Wasm lane"

  @switches [fuel: :integer, top: :integer, entry: :string, transpile: :boolean, prelude: :string]

  def run(argv) do
    Mix.Task.run("app.start")
    {opts, files, _} = OptionParser.parse(argv, switches: @switches)

    case files do
      [path | _] ->
        prelude = if opts[:prelude], do: File.read!(opts[:prelude]) <> "\n", else: ""
        js = prelude <> File.read!(path)

        diag_opts = [
          fuel: opts[:fuel] || 2_000_000_000,
          top: opts[:top] || 25,
          entry: opts[:entry] || "m",
          transpile: opts[:transpile] || false
        ]

        case TinyLasers.Js.Debug.diagnose(js, diag_opts) do
          {:ok, report} -> IO.puts(TinyLasers.Js.Debug.format(report))
          {:error, reason} -> Mix.raise("compile/run failed: #{inspect(reason)}")
        end

      [] ->
        Mix.raise("usage: mix porffor.debug <file.js> [--fuel N] [--top N] [--transpile]")
    end
  end
end
