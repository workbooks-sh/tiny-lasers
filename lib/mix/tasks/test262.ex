defmodule Mix.Tasks.Test262 do
  @moduledoc "Run test262 on the Porffor→Wasm ASM lane."
  use Mix.Task

  @shortdoc "Run test262 subdir on ASM lane; print pass% + grouped failures"

  @switches [limit: :integer, slice: :boolean, fuel: :integer, sig: :string, write_cache: :boolean]

  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, switches: @switches)
    Mix.Task.run("app.start")

    {dir, label, hopts} =
      if opts[:slice] do
        base = Path.join([File.cwd!(), "test", "conformance", "test262"])
        {Path.join(base, "cases"), "committed slice", [harness_dir: Path.join(base, "harness")]}
      else
        sub = List.first(args) || Mix.raise("usage: mix test262 <subdir>  (or --slice)")
        {Path.join([TinyLasers.Js.Test262.clone_root(), "test", sub]), sub, []}
      end

    unless File.dir?(dir), do: Mix.raise("not a dir: #{dir}")

    ropts =
      hopts
      |> then(&if(opts[:limit], do: [{:limit, opts[:limit]} | &1], else: &1))
      |> then(&if(opts[:fuel], do: [{:fuel, opts[:fuel]} | &1], else: &1))
      |> then(&if(opts[:sig], do: Keyword.put(&1, :signature, opts[:sig]), else: &1))

    {results, summary} =
      if opts[:sig] do
        TinyLasers.Js.Test262.run_signatures(dir, ropts)
      else
        TinyLasers.Js.Test262.run_dir(dir, ropts)
      end

    if opts[:write_cache] do
      cache_path = Path.join([File.cwd!(), "test", "conformance", "test262", "last_run.work"])
      TinyLasers.Js.Test262.write_signature_cache(results, cache_path)
      IO.puts("wrote signature cache → #{cache_path}")
    end

    IO.puts(TinyLasers.Js.Test262.format_report(summary, label))
  end
end
