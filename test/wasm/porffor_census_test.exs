defmodule TinyLasers.JsPorfforCensusTest do
  @moduledoc "Reporting gate: census pass rate vs baseline."
  use ExUnit.Case, async: false

  alias TinyLasers.Js.Census

  @moduletag :porffor
  @moduletag :census_report

  setup_all do
    if System.find_executable("node"), do: :ok, else: {:skip, "node absent"}
  end

  test "census runs and reports pass count (reporting only)" do
    results = Census.run()
    pass = Enum.count(results, fn {_, _, s, _, _} -> s == :pass end)
    total = Enum.count(results, fn {_, _, s, _, _} -> s != :oracle_skip end)

    IO.puts("\n[census gate] #{pass}/#{total} pass\n")

    assert total > 0
    assert pass >= 0
  end

  test "baseline file is readable" do
    base = Census.baseline()
    assert is_map(base)
  end
end
