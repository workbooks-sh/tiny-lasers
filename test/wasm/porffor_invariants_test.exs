defmodule TinyLasers.JsPorfforInvariantsTest do
  @moduledoc "Hard-fail gate: closure-conversion invariants on compile."
  use ExUnit.Case, async: false

  alias TinyLasers.Js.Porffor

  @moduletag :porffor

  setup_all do
    if File.regular?(Porffor.porf_entry()) and System.find_executable("node"),
      do: :ok,
      else: {:skip, "porffor/node absent"}
  end

  test "cc_generate closure programs compile with clean invariants" do
    script = Path.expand("compilers/js/porffor/cc_generate.cjs")

    assert File.regular?(script)

    {out, 0} = System.cmd("node", [script], cd: Path.expand("compilers/js/porffor"), stderr_to_stdout: true)

    assert out =~ "oracle"
  end

  test "known-good closure counter compiles" do
    src = "function c(){let n=0; return ()=>++n;} const f=c(); f(); console.log(f());"

    assert {:ok, _wasm} = Porffor.compile(src, "compilers", skip_invariants: false)
  end

  test "check_invariants returns clean for simple program" do
    src = "console.log(1+2);"
    assert {:ok, :clean} = Porffor.check_invariants(src)
  end
end
