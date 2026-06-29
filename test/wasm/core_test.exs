defmodule TinyLasers.WasmCoreTest do
  @moduledoc """
  The foundational milestone — decode a real wasm binary and run it entirely on the BEAM
  (no NIF, no native runtime): integer arithmetic, a function calling a function, linear
  memory, a real loop, if/else, a WASI host import (fd_write → stdout), and the isolation
  payoff: a trap is a caught exception in one process, never a VM crash.

  Migrated faithfully from nexus's `washy_test.exs` — the runtime is byte-for-byte the same,
  only the namespace changed (`Nexus.Washy` → `TinyLasers.Wasm`).
  """
  use ExUnit.Case, async: true

  alias TinyLasers.Wasm

  # hand-encoded wasm module: func0 add(i32,i32)->i32 ; func1 dbl(i32)->i32 = add(x,x)
  @mod <<
    0, 97, 115, 109, 1, 0, 0, 0,
    # type: (i32,i32)->i32 ; (i32)->i32
    1, 12, 2, 96, 2, 127, 127, 1, 127, 96, 1, 127, 1, 127,
    # function: func0:type0, func1:type1
    3, 3, 2, 0, 1,
    # export: "add"->0, "dbl"->1
    7, 13, 2, 3, 97, 100, 100, 0, 0, 3, 100, 98, 108, 0, 1,
    # code: add = local.get 0; local.get 1; i32.add ; dbl = local.get 0; local.get 0; call 0
    10, 18, 2, 7, 0, 32, 0, 32, 1, 106, 11, 8, 0, 32, 0, 32, 0, 16, 0, 11
  >>

  test "decode + run integer arithmetic in pure Elixir" do
    {:ok, mod} = Wasm.decode(@mod)
    assert Wasm.call(mod, "add", [3, 4]) == 7
    assert Wasm.call(mod, "add", [100, 23]) == 123
  end

  test "a function calling another function (call opcode)" do
    {:ok, mod} = Wasm.decode(@mod)
    assert Wasm.call(mod, "dbl", [5]) == 10
    assert Wasm.call(mod, "dbl", [21]) == 42
  end

  test "i32 add wraps at 32 bits (real wasm semantics)" do
    {:ok, mod} = Wasm.decode(@mod)
    assert Wasm.call(mod, "add", [0xFFFFFFFF, 1]) == 0
  end

  # module with 1 page of memory; memtest() stores 42 at addr 100 then loads it back -> 42.
  # NB: i32.const 100 is signed-LEB `0xE4 0x00` (a bare 0x64 would decode as -28 — bit 6 is the sign bit).
  @memmod <<
    0, 97, 115, 109, 1, 0, 0, 0,
    1, 5, 1, 96, 0, 1, 127,
    3, 2, 1, 0,
    5, 3, 1, 0, 1,
    7, 11, 1, 7, 109, 101, 109, 116, 101, 115, 116, 0, 0,
    10, 18, 1, 16, 0, 65, 228, 0, 65, 42, 54, 0, 0, 65, 228, 0, 40, 0, 0, 11
  >>

  test "linear memory (:atomics) — store then load roundtrips in pure Elixir" do
    {:ok, mod} = Wasm.decode(@memmod)
    assert Wasm.call(mod, "memtest", []) == 42
  end

  # sumto(n) = n + (n-1) + ... + 1, via block/loop/br_if/br + i32.eqz/add/sub (a real loop)
  @loopmod <<
    0, 97, 115, 109, 1, 0, 0, 0,
    1, 6, 1, 96, 1, 127, 1, 127,
    3, 2, 1, 0,
    7, 9, 1, 5, 115, 117, 109, 116, 111, 0, 0,
    10, 35, 1, 33, 1, 1, 127,
    2, 64, 3, 64, 32, 0, 69, 13, 1, 32, 1, 32, 0, 106, 33, 1, 32, 0, 65, 1, 107, 33, 0, 12, 0, 11, 11, 32, 1, 11
  >>

  test "control flow: a real loop (block/loop/br_if/br + comparison) computes 1..n" do
    {:ok, mod} = Wasm.decode(@loopmod)
    assert Wasm.call(mod, "sumto", [5]) == 15
    assert Wasm.call(mod, "sumto", [10]) == 55
    assert Wasm.call(mod, "sumto", [0]) == 0
    assert Wasm.call(mod, "sumto", [100]) == 5050
  end

  # pick(c) = 100 if c else 200 (if/else)
  @ifmod <<
    0, 97, 115, 109, 1, 0, 0, 0,
    1, 6, 1, 96, 1, 127, 1, 127,
    3, 2, 1, 0,
    7, 8, 1, 4, 112, 105, 99, 107, 0, 0,
    10, 16, 1, 14, 0, 32, 0, 4, 127, 65, 228, 0, 5, 65, 200, 1, 11, 11
  >>

  test "control flow: if/else picks a branch" do
    {:ok, mod} = Wasm.decode(@ifmod)
    assert Wasm.call(mod, "pick", [1]) == 100
    assert Wasm.call(mod, "pick", [0]) == 200
  end

  # imports wasi_snapshot_preview1.fd_write; print() writes "Hi" to mem, sets up an iovec, calls fd_write(1,…)
  @wasimod <<
    0, 97, 115, 109, 1, 0, 0, 0,
    1, 12, 2, 96, 4, 127, 127, 127, 127, 1, 127, 96, 0, 0,
    2, 35, 1, 22, 119, 97, 115, 105, 95, 115, 110, 97, 112, 115, 104, 111, 116, 95, 112, 114, 101, 118, 105, 101, 119, 49,
    8, 102, 100, 95, 119, 114, 105, 116, 101, 0, 0,
    3, 2, 1, 1,
    5, 3, 1, 0, 1,
    7, 9, 1, 5, 112, 114, 105, 110, 116, 0, 1,
    10, 45, 1, 43, 0,
    65, 8, 65, 200, 0, 58, 0, 0, 65, 9, 65, 233, 0, 58, 0, 0,
    65, 0, 65, 8, 54, 0, 0, 65, 4, 65, 2, 54, 0, 0,
    65, 1, 65, 0, 65, 1, 65, 16, 16, 0, 26, 11
  >>

  test "WASI host import: fd_write captures stdout — a real syscall handled in pure Elixir" do
    {:ok, mod} = Wasm.decode(@wasimod)
    {result, out} = Wasm.call_io(mod, "print", [])
    assert out == "Hi"
    assert result == nil
  end

  test "BEAM isolation: a trap is a caught exception in ONE process, not a VM crash" do
    # a body with an unimplemented opcode raises — but the test VM keeps running, proving fault isolation.
    bad = <<0, 97, 115, 109, 1, 0, 0, 0,
            1, 5, 1, 96, 0, 1, 127,
            3, 2, 1, 0,
            7, 7, 1, 3, 98, 97, 100, 0, 0,
            10, 5, 1, 3, 0, 141, 11>>
    {:ok, mod} = Wasm.decode(bad)
    parent = self()
    # run it in its OWN process; the crash stays there
    pid = spawn(fn -> send(parent, {:result, (try do Wasm.call(mod, "bad", []) rescue e -> {:trapped, Exception.message(e)} end)}) end)
    ref = Process.monitor(pid)
    assert_receive {:result, {:trapped, msg}}, 1000
    assert msg =~ "unimplemented"
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    # the test process is alive and well — the trap did not take down the VM
    assert Process.alive?(self())
  end
end
