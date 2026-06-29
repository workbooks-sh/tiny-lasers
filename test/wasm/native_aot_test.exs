defmodule TinyLasers.WasmNativeAotTest do
  @moduledoc """
  **The multi-language AOT set is complete: C, C++, Rust, AND Go all run on tiny-lasers via WASIX.**

  WASIX is just the ABI — any language with an AOT path to a `wasm32-wasip1` module runs on the runtime,
  its syscalls landing on our host imports (fs → VFS, etc.). The C + Rust binaries live in `wasix_c_test`;
  these add the two the user asked about:

    * **C++** — `cpp_stl.cpp` (`std::sort`/`vector`/`string`/`accumulate` + `printf`), compiled with the
      vendored wasi-sdk `clang++` + bundled `libc++`. Same toolchain as the shell, `-fno-exceptions`.
    * **Go** — `go_sort.go` (`sort.Ints`/`fmt.Printf`, the full Go runtime + GC + goroutine scheduler),
      compiled with the OFFICIAL Go `GOOS=wasip1 GOARCH=wasm` target (cleaner than TinyGo; no JS glue).

  Both print their result and `exit(42)`, IDENTICALLY in the interpreter and the asm/transpile lane.

  Rebuild fixtures (toolchains not required to run the committed `.wasm`):
    C++:  <wasi-sdk>/bin/clang++ --target=wasm32-wasip1 -O1 -fno-exceptions cpp_stl.cpp -o cpp_stl.wasm
    Go:   GOOS=wasip1 GOARCH=wasm go build -o go_sort.wasm go_sort.go
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Wasm

  @dir Path.join(__DIR__, "../conformance/native")

  defp run(mod, transpile?) do
    Process.put(:tl_argv, ["prog"])
    Process.put(:tl_stdin, "")

    try do
      Wasm.call_io(mod, "_start", [], transpile: transpile?, fuel: 1_000_000_000_000)
      :no_exit
    catch
      :throw, {:tl_exit, code} -> {:exit, code, Process.get(:tl_out) |> List.wrap() |> IO.iodata_to_binary()}
    end
  end

  @tag timeout: 300_000
  test "a C++ STL program (sort/vector/string via libc++) runs interp ≡ asm, exits 42" do
    {:ok, mod} = Wasm.decode(File.read!(Path.join(@dir, "cpp_stl.wasm")))
    interp = run(mod, false)
    asm = run(mod, true)
    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)}"
    assert interp == {:exit, 42, "sorted: 1 2 3 5 8 9 sum=28\n"}, "got #{inspect(interp)}"
  end

  @tag timeout: 300_000
  test "an official-Go wasip1 program (full runtime + GC) runs interp ≡ asm, exits 42" do
    {:ok, mod} = Wasm.decode(File.read!(Path.join(@dir, "go_sort.wasm")))

    names = MapSet.new(mod.imports, fn {_m, n, _t} -> n end)
    assert "clock_time_get" in names and "sched_yield" in names, "the Go runtime drives clock + scheduler"

    interp = run(mod, false)
    asm = run(mod, true)
    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)}"
    assert interp == {:exit, 42, "sorted: [1 2 3 5 8 9] sum=28\n"}, "got #{inspect(interp)}"
  end
end
