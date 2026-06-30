defmodule TinyLasers.JsPorfforPreflightTest do
  @moduledoc "Reporting gate: preflight scanner surfaces known seams."
  use ExUnit.Case, async: false

  alias TinyLasers.Js.Preflight

  @moduletag :porffor
  @moduletag :preflight_report

  test "eval triggers hard_block" do
    assert {:ok, r} = Preflight.scan("eval('1+1'); console.log(1);")
    assert r.hard_block
    assert Enum.any?(r.warnings, &(&1.code == :hard_unsupported))
  end

  test "simple program has no hard block" do
    assert {:ok, r} = Preflight.scan("console.log(1);")
    refute r.hard_block
  end

  test "import triggers module warning" do
    assert {:ok, r} = Preflight.scan("import x from 'y'; console.log(x);")
    assert Enum.any?(r.warnings, &(&1.code == :module))
  end
end
