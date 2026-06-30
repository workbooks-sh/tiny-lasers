defmodule Mix.Tasks.Porffor.Census do
  @moduledoc "Run the Porffor feature census vs node oracle."
  use Mix.Task

  @shortdoc "Run Porffor feature census (reporting gate)"

  @switches [compare: :boolean, enforce: :boolean]

  def run(argv) do
    Mix.Task.run("app.start")
    {opts, _, _} = OptionParser.parse(argv, switches: @switches)

    census_opts = [compare: opts[:compare] || true]

    if opts[:enforce] do
      TinyLasers.Js.Census.report!(census_opts)
    else
      TinyLasers.Js.Census.report(census_opts)
    end
  end
end
