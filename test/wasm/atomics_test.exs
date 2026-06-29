defmodule TinyLasers.WasmAtomicsTest do
  @moduledoc """
  WASIX §0 — the atomics / threads-proposal opcodes (0xFE prefix). On washy's `:atomics`-backed memory,
  single-thread atomic load/store/rmw/cmpxchg are just width-correct memory ops; `fence` is a no-op;
  `wait`/`notify` have their single-thread semantics (atomicity-under-contention + real futex parking
  land with threads, §2). Parser + interpreter here; the asm-lane lowering is the next increment, so we
  also assert the transpile lane agrees with the interpreter (it falls back cleanly on atomic ops).
  """
  use ExUnit.Case, async: true

  alias TinyLasers.Wasm
  alias TinyLasers.Wasm.TranspileAsm

  defp build(nlocals, instrs) do
    %Wasm{
      types: [{[127, 127], [127]}],
      funcs: [0],
      code: [{nlocals, instrs}],
      exports: %{"f" => 0},
      mem: {1, nil},
      globals: [],
      data: [],
      imports: [],
      elements: [],
      id: :crypto.hash(:sha256, :erlang.term_to_binary({nlocals, instrs}))
    }
  end

  defp interp(instrs, nlocals \\ 1) do
    {v, _} = Wasm.call_io(build(nlocals, instrs), "f", [0, 0], transpile: false)
    v
  end

  # store 42 @0, load @0
  test "atomic store + load round-trips" do
    assert interp([{:i32_const, 0}, {:i32_const, 42}, {:atomic_store, 0, 4}, {:i32_const, 0}, {:atomic_load, 0, 4}]) == 42
  end

  test "atomic load is zero-extended at sub-widths" do
    # store 0x000000FF as a byte @0, load8_u → 0xFF (255)
    assert interp([{:i32_const, 0}, {:i32_const, 0xFF}, {:atomic_store, 0, 1}, {:i32_const, 0}, {:atomic_load, 0, 1}]) == 0xFF
  end

  test "rmw.add returns the OLD value and writes the sum" do
    seq = [
      {:i32_const, 0}, {:i32_const, 42}, {:atomic_store, 0, 4},
      {:i32_const, 0}, {:i32_const, 8}, {:atomic_rmw, :add, 0, 4}
    ]
    # rmw result (old) = 42
    assert interp(seq) == 42
    # memory now holds 50
    assert interp(seq ++ [{:local_set, 2}, {:i32_const, 0}, {:atomic_load, 0, 4}]) == 50
  end

  test "rmw.sub / and / or / xor / xchg compute correctly" do
    base = fn op, v0, v ->
      interp([
        {:i32_const, 0}, {:i32_const, v0}, {:atomic_store, 0, 4},
        {:i32_const, 0}, {:i32_const, v}, {:atomic_rmw, op, 0, 4},
        {:local_set, 2}, {:i32_const, 0}, {:atomic_load, 0, 4}
      ])
    end

    assert base.(:sub, 50, 8) == 42
    assert base.(:and, 0b1100, 0b1010) == 0b1000
    assert base.(:or, 0b1100, 0b1010) == 0b1110
    assert base.(:xor, 0b1100, 0b1010) == 0b0110
    assert base.(:xchg, 42, 99) == 99
  end

  test "cmpxchg swaps on match, leaves memory on mismatch" do
    win = [
      {:i32_const, 0}, {:i32_const, 42}, {:atomic_store, 0, 4},
      {:i32_const, 0}, {:i32_const, 42}, {:i32_const, 99}, {:atomic_rmw, :cmpxchg, 0, 4}
    ]
    assert interp(win) == 42                                           # returns old
    assert interp(win ++ [{:local_set, 2}, {:i32_const, 0}, {:atomic_load, 0, 4}]) == 99  # swapped

    lose = [
      {:i32_const, 0}, {:i32_const, 42}, {:atomic_store, 0, 4},
      {:i32_const, 0}, {:i32_const, 7}, {:i32_const, 99}, {:atomic_rmw, :cmpxchg, 0, 4}
    ]
    assert interp(lose) == 42                                          # returns old
    assert interp(lose ++ [{:local_set, 2}, {:i32_const, 0}, {:atomic_load, 0, 4}]) == 42  # unchanged
  end

  test "fence is a no-op; wait reports not-equal; notify wakes nobody yet" do
    assert interp([{:i32_const, 1}, {:atomic_fence}]) == 1
    # mem=42, wait expecting 7 → 1 (not-equal); timeout slot ignored
    assert interp([{:i32_const, 0}, {:i32_const, 42}, {:atomic_store, 0, 4},
                   {:i32_const, 0}, {:i32_const, 7}, {:i32_const, 0}, {:atomic_wait, 4, 0}]) == 1
    # mem=42, wait expecting 42 → 2 (timed-out: no thread can notify us yet, §2)
    assert interp([{:i32_const, 0}, {:i32_const, 42}, {:atomic_store, 0, 4},
                   {:i32_const, 0}, {:i32_const, 42}, {:i32_const, 0}, {:atomic_wait, 4, 0}]) == 2
    # notify with no waiters → 0
    assert interp([{:i32_const, 0}, {:i32_const, 1}, {:atomic_notify, 0}]) == 0
  end

  # ── ORACLE: interpreter == forms-native == asm-native, bit-identical, for each atomic op ──
  @oracle [
    {"store+load", [{:i32_const, 0}, {:i32_const, 42}, {:atomic_store, 0, 4}, {:i32_const, 0}, {:atomic_load, 0, 4}], 42},
    {"rmw.add", [{:i32_const, 0}, {:i32_const, 42}, {:atomic_store, 0, 4}, {:i32_const, 0}, {:i32_const, 8}, {:atomic_rmw, :add, 0, 4}, {:local_set, 2}, {:i32_const, 0}, {:atomic_load, 0, 4}], 50},
    {"rmw.xor", [{:i32_const, 0}, {:i32_const, 0b1100}, {:atomic_store, 0, 4}, {:i32_const, 0}, {:i32_const, 0b1010}, {:atomic_rmw, :xor, 0, 4}, {:local_set, 2}, {:i32_const, 0}, {:atomic_load, 0, 4}], 0b0110},
    {"cmpxchg-hit", [{:i32_const, 0}, {:i32_const, 42}, {:atomic_store, 0, 4}, {:i32_const, 0}, {:i32_const, 42}, {:i32_const, 99}, {:atomic_rmw, :cmpxchg, 0, 4}, {:local_set, 2}, {:i32_const, 0}, {:atomic_load, 0, 4}], 99},
    {"fence", [{:i32_const, 7}, {:atomic_fence}], 7}
  ]

  test "asm-native == interpreter, bit-identical, across atomic ops (BOTH lanes)" do
    for {name, instrs, want} <- @oracle do
      m = build(1, instrs)
      # the atomics now LOWER to BEAM asm (not :unsupported) — so the tiered lane runs them natively.
      assert {:ok, {_am, _af, _}} = TranspileAsm.try_emit(m, 0), "#{name}: atomics should lower to asm"

      {interp, _} = Wasm.call_io(m, "f", [0, 0], transpile: false)
      {tiered, _} = Wasm.call_io(m, "f", [0, 0], transpile: true, tier_threshold: 1, tier_async: false)

      assert interp == want and interp == tiered,
             "#{name}: interp=#{inspect(interp)} tiered=#{inspect(tiered)} want=#{want}"
    end
  end
end
