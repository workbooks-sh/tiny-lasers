defmodule TinyLasers.JsPorfforAsmCoverageTest do
  @moduledoc "Reporting gate: ASM transpile coverage metric."
  use ExUnit.Case, async: false

  alias TinyLasers.Js.{AsmCoverage, Porffor}

  @moduletag :porffor
  @moduletag :asm_coverage_report

  setup_all do
    if File.regular?(Porffor.porf_entry()) and System.find_executable("node"),
      do: :ok,
      else: {:skip, "porffor/node absent"}
  end

  test "simple program has ASM coverage report" do
    src = "let s=0; for(let i=0;i<10;i++) s+=i; console.log(s);"

    assert {:ok, r} = AsmCoverage.analyze_source(src)
    assert r.total > 0
    assert r.asm_native + r.interp_fallback == r.total
    IO.puts(AsmCoverage.format(r))
  end
end
