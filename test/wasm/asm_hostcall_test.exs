defmodule TinyLasers.WasmAsmHostcallTest do
  @moduledoc """
  **Proof that WASI/host-import calls are ASM-NATIVE, not an interp fallback (the §0-B I/O bar).**

  A guest `call` to an IMPORTED function (a WASI syscall like `fd_write`/`poll_oneoff`/`sched_yield`) is
  lowered by `TranspileAsm` to a `call_ext` into `TinyLasers.Wasm.invoke_host/2` — a native BEAM call across
  the guest/host boundary. The transpiled guest function does NOT drop to the interpreter; `invoke_host`
  is the HOST side of the WASI ABI (native Elixir in both lanes, exactly like wasmtime's host fns are
  native Rust), which is the boundary, not a fallback.

  So "the transpiler runs everything as pure BEAM assembly with zero interp fallback" holds for the I/O
  path: the guest's own instruction stream — INCLUDING the syscall call-site — is asm; the syscall body is
  the host. This test pins that: a function whose body is a host-import call must `try_emit == {:ok}` (fully
  asm-lowered, no fallback) AND run bit-identically interp≡asm.
  """
  use ExUnit.Case, async: true

  alias TinyLasers.Wasm
  alias TinyLasers.Wasm.TranspileAsm

  # f() -> i32  =  return sched_yield()  (import 0 :: () -> i32, a real WASI host call returning 0).
  defp hostcall_mod do
    %Wasm{
      types: [{[], [127]}],
      imports: [{"wasi_snapshot_preview1", "sched_yield", 0}],
      funcs: [0],
      code: [{0, [{:call, 0}]}],
      exports: %{"f" => 0},
      mem: {1, nil},
      globals: [],
      data: [],
      elements: [],
      tags: [],
      id: :crypto.hash(:sha256, "hostcall_mod")
    }
  end

  test "a guest function whose body is a WASI host-import call lowers to ASM (no interp fallback)" do
    m = hostcall_mod()

    # {:ok, ...} ⇒ the WHOLE function — including the `call 0` to the host import — was emitted as BEAM
    # assembly. (:unsupported would mean it fell back to forms/interp; that is NOT what happens here.)
    assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0),
           "host-import call must lower in the asm lane — the syscall call-site is native call_ext invoke_host"

    # And the asm result equals the interp oracle: sched_yield → 0, identically.
    interp = Wasm.call_io(m, "f", [], transpile: false) |> elem(0)
    asm = apply(am, af, [])

    assert interp == asm
    assert interp == 0
  end
end
