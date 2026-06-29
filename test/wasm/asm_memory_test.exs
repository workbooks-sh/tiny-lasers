defmodule TinyLasers.WasmAsmMemoryTest do
  @moduledoc """
  **BEAM-assembly memory op-group (`TinyLasers.Wasm.AsmOps.Memory`, epic wb-wzdq).** A/Bs functions that
  store then load integers at various addresses/widths through THREE lanes — interpreter, forms-native,
  asm-native — and asserts all agree bit-identically, including unaligned + word-spanning addresses, all
  load/store widths, signed loads of negative bytes, an out-of-bounds access (must TRAP identically in
  both interp + asm), and memory.size/grow round-trips.
  """
  use ExUnit.Case, async: true

  alias TinyLasers.Wasm

  # i32 -> i32 function `f` (the only signature the asm lane attempts). `arg0`/`arg1` are the two i32 args.
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

  defp interp(m, args), do: elem(Wasm.call_io(m, "f", args, transpile: false), 0)

  defp asm(m, args),
    do: elem(Wasm.call_io(m, "f", args, transpile: true, tier_threshold: 1, tier_async: false), 0)

  defp agree(m, argsets) do
    for args <- argsets do
      i = interp(m, args)
      a = asm(m, args)
      assert i == a, "@ #{inspect(args)}: interp=#{inspect(i)} asm=#{inspect(a)}"
    end
  end

  @addrs [[0, 0], [1, 0], [3, 0], [4, 0], [7, 0], [8, 0], [13, 0], [100, 0], [4093, 0]]

  test "i32 store/load round-trips at aligned + unaligned + word-spanning addresses" do
    # f(addr, val): mem[addr] = val (i32); return mem[addr] (i32)
    m =
      build(0, [
        {:local_get, 0},
        {:local_get, 1},
        {:i32_store, 0},
        {:local_get, 0},
        {:i32_load, 0}
      ])

    sets = for [a, _] <- @addrs, v <- [0, 1, 0xDEADBEEF, 0xFFFFFFFF, 0x00FF00FF], do: [a, v]
    agree(m, sets)
  end

  test "store8/load8u + load8s sign-extension of negative bytes" do
    # store the low byte, then load it both unsigned and signed
    for {load_op, label} <- [{:i32_load8u, "u"}, {:i32_load8s, "s"}] do
      m =
        build(0, [
          {:local_get, 0},
          {:local_get, 1},
          {:i32_store8, 0},
          {:local_get, 0},
          {load_op, 0}
        ])

      sets = for a <- [0, 1, 7, 8, 50], v <- [0, 1, 0x7F, 0x80, 0xFF, 0x123], do: [a, v]
      agree(m, sets)
      assert label in ["u", "s"]
    end
  end

  test "store16/load16u + load16s sign-extension across word boundary" do
    for load_op <- [:i32_load16u, :i32_load16s] do
      m =
        build(0, [
          {:local_get, 0},
          {:local_get, 1},
          {:i32_store16, 0},
          {:local_get, 0},
          {load_op, 0}
        ])

      # addr 7 makes the 2-byte access SPAN two packed words (exercises the slow byte path)
      sets = for a <- [0, 1, 6, 7, 8, 30], v <- [0, 1, 0x7FFF, 0x8000, 0xFFFF, 0x12345], do: [a, v]
      agree(m, sets)
    end
  end

  test "non-zero static offset immediate folds into the effective address" do
    # f(addr, val): mem[addr+16] = val; return mem[addr+16]
    m =
      build(0, [
        {:local_get, 0},
        {:local_get, 1},
        {:i32_store, 16},
        {:local_get, 0},
        {:i32_load, 16}
      ])

    sets = for a <- [0, 3, 7, 64], v <- [0x11223344, 0xFFFFFFFF], do: [a, v]
    agree(m, sets)
  end

  test "out-of-bounds load traps identically in both lanes" do
    # f(addr, _): return mem[addr] (i32). addr near/over the 1-page (65536-byte) limit traps.
    m = build(0, [{:local_get, 0}, {:i32_load, 0}])

    for addr <- [65533, 65536, 70000, 0x7FFFFFFF] do
      i =
        try do
          {:ok, interp(m, [addr, 0])}
        rescue
          e in TinyLasers.Wasm.Trap -> {:trap, e.reason}
        end

      a =
        try do
          {:ok, asm(m, [addr, 0])}
        rescue
          e in TinyLasers.Wasm.Trap -> {:trap, e.reason}
        end

      assert i == a and i == {:trap, :out_of_bounds}, "@addr #{addr}: interp=#{inspect(i)} asm=#{inspect(a)}"
    end
  end

  test "out-of-bounds store traps identically in both lanes" do
    m = build(0, [{:local_get, 0}, {:local_get, 1}, {:i32_store, 0}, {:i32_const, 0}])

    for addr <- [65533, 65536, 99999] do
      trap = fn fun ->
        try do
          {:ok, fun.()}
        rescue
          e in TinyLasers.Wasm.Trap -> {:trap, e.reason}
        end
      end

      i = trap.(fn -> interp(m, [addr, 7]) end)
      a = trap.(fn -> asm(m, [addr, 7]) end)
      assert i == a and i == {:trap, :out_of_bounds}, "@addr #{addr}: interp=#{inspect(i)} asm=#{inspect(a)}"
    end
  end

  test "memory.size round-trip (returns current page count)" do
    m = build(0, [{:memory_size}, {:local_get, 0}, {:op, 0x6B}])
    # f(x,_) = memory.size - x ; with 1 page that's 1 - x
    agree(m, for(x <- [0, 1, 2], do: [x, 0]))
  end

  test "memory.grow then memory.size reflects the new page count" do
    # f(n, _): old = memory.grow(n); return memory.size  (== 1 + n on success, else still 1)
    m =
      build(1, [
        {:local_get, 0},
        {:memory_grow},
        {:local_set, 2},
        {:memory_size}
      ])

    agree(m, for(n <- [0, 1, 2, 3], do: [n, 0]))
  end

  test "memory.grow returns old page count (or -1 on failure)" do
    # f(n, _): return memory.grow(n)
    m = build(0, [{:local_get, 0}, {:memory_grow}])
    # n=0 -> 1 (old pages); huge n -> -1 (masked to 0xFFFFFFFF)
    agree(m, [[0, 0], [1, 0], [2, 0], [0xFFFFFFFF, 0]])
  end

  test "memory.fill then load reads the filled byte pattern" do
    # f(addr, val): memory.fill(addr, val, 8); return mem[addr] (i32, low 4 of the 8 filled bytes)
    m =
      build(0, [
        {:local_get, 0},
        {:local_get, 1},
        {:i32_const, 8},
        {:memory_fill},
        {:local_get, 0},
        {:i32_load, 0}
      ])

    agree(m, for(a <- [0, 3, 7, 64], v <- [0, 0xAB, 0xFF], do: [a, v]))
  end

  test "memory.copy duplicates a region" do
    # f(_, _): mem[0]=0x11223344; memory.copy(64, 0, 4); return mem[64]
    m =
      build(0, [
        {:i32_const, 0},
        {:i32_const, 0x11223344},
        {:i32_store, 0},
        {:i32_const, 64},
        {:i32_const, 0},
        {:i32_const, 4},
        {:memory_copy},
        {:i32_const, 64},
        {:i32_load, 0}
      ])

    agree(m, [[0, 0], [1, 1]])
  end

  test "data.drop is a no-op (followed by a normal load)" do
    m = build(0, [{:data_drop}, {:local_get, 0}, {:local_get, 1}, {:i32_store, 0}, {:local_get, 0}, {:i32_load, 0}])
    agree(m, [[0, 42], [16, 0xCAFE]])
  end

  # build with a passive data segment (the asm lane resolves the bytes from mod.data at compile time).
  defp build_data(bytes, nlocals, instrs) do
    %Wasm{
      build(nlocals, instrs)
      | data: [{:passive, bytes}],
        id: :crypto.hash(:sha256, :erlang.term_to_binary({:data, bytes, nlocals, instrs}))
    }
  end

  test "memory.init copies a data segment into memory == interp (incl. OOB-data trap)" do
    # f(dst, _): memory.init(dst, 0, 4) from segment 0; return mem[dst] (the 4 copied bytes as i32-LE)
    m =
      build_data(<<0x44, 0x33, 0x22, 0x11>>, 0, [
        {:local_get, 0}, {:i32_const, 0}, {:i32_const, 4}, {:memory_init, 0},
        {:local_get, 0}, {:i32_load, 0}
      ])

    assert {:ok, {_am, _af, _}} = TinyLasers.Wasm.TranspileAsm.try_emit(m, 0), "memory.init must lower in asm"
    agree(m, for(dst <- [0, 1, 7, 64, 4000], do: [dst, 0]))

    # src+n past the 4-byte segment → :out_of_bounds_data, identically in both lanes.
    over = build_data(<<1, 2, 3, 4>>, 0, [
      {:local_get, 0}, {:i32_const, 2}, {:i32_const, 4}, {:memory_init, 0}, {:i32_const, 0}
    ])

    trap = fn fun ->
      try do
        {:ok, fun.()}
      rescue
        e in TinyLasers.Wasm.Trap -> {:trap, e.reason}
      end
    end

    i = trap.(fn -> interp(over, [0, 0]) end)
    a = trap.(fn -> asm(over, [0, 0]) end)
    assert i == a and i == {:trap, :out_of_bounds_data}, "interp=#{inspect(i)} asm=#{inspect(a)}"
  end

  test "i64 store + full load round-trips an i64 through memory (wrapped to i32)" do
    # v = extend_u(a); store v @0 (8 bytes); load i64 @0; wrap to i32 -> a
    m =
      build(0, [
        {:i32_const, 0}, {:local_get, 0}, {:op, 0xAD}, {:i64_store, 0, 8},
        {:i32_const, 0}, {:i64_load, 0, 8, false}, {:op, 0xA7}
      ])

    agree(m, [[0, 0], [0xFFFFFFFF, 0], [0x12345678, 0]])
  end

  test "i64 partial loads (signed + unsigned widths) == interp" do
    for {n, signed} <- [{1, true}, {1, false}, {2, true}, {2, false}, {4, true}, {4, false}] do
      m =
        build(0, [
          {:i32_const, 0}, {:local_get, 0}, {:op, 0xAD}, {:i64_store, 0, 8},
          {:i32_const, 0}, {:i64_load, 0, n, signed}, {:op, 0xA7}
        ])

      agree(m, [[0xFFFFFF80, 0], [0x7F, 0], [0x8000, 0], [0xDEADBEEF, 0]])
    end
  end

  # ── wb-95w7 regression: a store must pop BOTH operands (addr + val), not one ──────────────────────────
  #
  # The §8 oracle (a real wasix-libc C binary) caught an interp≠asm divergence: a store's asm lowering
  # decremented the compile-time operand depth by ONE instead of TWO, so EVERY operand slot after a store
  # was off by one — corrupting later loads/locals (dlmalloc returned a garbage pointer in the asm lane
  # only). The interpreter (`step({:i32_store,…}, [v, a | s])`) is the oracle: a store consumes value AND
  # address. The earlier round-trip tests masked it because a store was always immediately followed by a
  # `local.get` that overwrote the desynced slot; these put real work AFTER the store.
  test "store consumes BOTH addr+val — later operand slots stay aligned (i32/8/16)" do
    for {store_op, mask} <- [{:i32_store, 0xFFFFFFFF}, {:i32_store8, 0xFF}, {:i32_store16, 0xFFFF}] do
      # f(a, v): mem[a]=v ; then compute (a + v + a) entirely from operands pushed AFTER the store —
      # if the store left the depth off-by-one these local.gets read the wrong slots.
      m =
        build(0, [
          {:local_get, 0}, {:local_get, 1}, {store_op, 0},
          {:local_get, 0}, {:local_get, 1}, {:op, 0x6A},
          {:local_get, 0}, {:op, 0x6A}
        ])

      sets = for a <- [0, 7, 8, 16, 100], v <- [0, 1, 0x7F, 0x80, 0xFF, 0x1234], do: [a, v]
      agree(m, sets)
      assert mask in [0xFFFFFFFF, 0xFF, 0xFFFF]
    end
  end

  test "i64 store consumes BOTH addr+val — later operand slots stay aligned" do
    # f(a, v): mem[a] = extend_u(v) (i64 store) ; then a + v + a from operands pushed after the store.
    m =
      build(0, [
        {:local_get, 0}, {:local_get, 1}, {:op, 0xAD}, {:i64_store, 0, 8},
        {:local_get, 0}, {:local_get, 1}, {:op, 0x6A},
        {:local_get, 0}, {:op, 0x6A}
      ])

    agree(m, for(a <- [0, 8, 64], v <- [0, 1, 255, 0x1234], do: [a, v]))
  end

  # ── f32/f64 store+load (epic: the asm lane lowered integer memory ops but bailed f32/f64 to the
  # interpreter, so Porffor's hot f64-value tokenizer loops ran interpreted → ~3x slower. These lock in
  # bit-identical f32/f64 memory parity: finite floats, ±Inf/NaN via {:nonfinite,…}, unaligned addresses,
  # static offset, OOB trap, and the wb-95w7 store-pops-both-operands shape for floats.
  defp build_f(nlocals, instrs, result \\ 124) do
    # (i32) -> f32|f64 : arg0 is the address.
    %Wasm{
      types: [{[127], [result]}],
      funcs: [0],
      code: [{nlocals, instrs}],
      exports: %{"f" => 0},
      mem: {1, nil},
      globals: [],
      data: [],
      imports: [],
      elements: [],
      id: :crypto.hash(:sha256, :erlang.term_to_binary({:f, result, nlocals, instrs}))
    }
  end

  @f64_vals [
    0.0,
    -0.0,
    1.0,
    -2.5,
    3.141592653589793,
    1.0e308,
    -1.0e-308,
    {:nonfinite, 0x7FF0000000000000, 64},  # +Inf
    {:nonfinite, 0xFFF0000000000000, 64},  # -Inf
    {:nonfinite, 0x7FF8000000000000, 64}   # NaN
  ]

  test "f64 store+load round-trips finite + nonfinite values at aligned/unaligned addresses" do
    for v <- @f64_vals do
      # f(addr): mem[addr] = v (f64); return mem[addr] (f64).  Store order: addr below, val on top.
      m =
        build_f(0, [
          {:local_get, 0},
          {:fconst, v},
          {:f64_store, 0},
          {:local_get, 0},
          {:f64_load, 0}
        ])

      agree(m, for(a <- [0, 1, 4, 7, 8, 13, 100, 4088], do: [a]))
    end
  end

  test "f64 static offset folds into the effective address" do
    for v <- [0.0, 1.5, -3.25, {:nonfinite, 0x7FF0000000000000, 64}] do
      m =
        build_f(0, [
          {:local_get, 0},
          {:fconst, v},
          {:f64_store, 16},
          {:local_get, 0},
          {:f64_load, 16}
        ])

      agree(m, for(a <- [0, 3, 7, 8, 64], do: [a]))
    end
  end

  test "f64 out-of-bounds load traps identically in both lanes" do
    m = build_f(0, [{:local_get, 0}, {:f64_load, 0}])

    for addr <- [65529, 65530, 65536, 70000, 0x7FFFFFFF] do
      i =
        try do
          {:ok, interp(m, [addr])}
        rescue
          e in TinyLasers.Wasm.Trap -> {:trap, e.reason}
        end

      a =
        try do
          {:ok, asm(m, [addr])}
        rescue
          e in TinyLasers.Wasm.Trap -> {:trap, e.reason}
        end

      assert i == a and i == {:trap, :out_of_bounds}, "@addr #{addr}: interp=#{inspect(i)} asm=#{inspect(a)}"
    end
  end

  test "f64 out-of-bounds store traps identically in both lanes" do
    # (i32)->i32: store 1.0 at addr; return 0. Use the i32 build (2 args, ignore arg1).
    m = build(0, [{:local_get, 0}, {:fconst, 1.0}, {:f64_store, 0}, {:i32_const, 0}])

    for addr <- [65529, 65536, 99999] do
      trap = fn fun ->
        try do
          {:ok, fun.()}
        rescue
          e in TinyLasers.Wasm.Trap -> {:trap, e.reason}
        end
      end

      i = trap.(fn -> interp(m, [addr, 0]) end)
      a = trap.(fn -> asm(m, [addr, 0]) end)
      assert i == a and i == {:trap, :out_of_bounds}, "@addr #{addr}: interp=#{inspect(i)} asm=#{inspect(a)}"
    end
  end

  test "f64 store consumes BOTH addr+val — later operand slots stay aligned" do
    # (i32,i32)->i32: mem[a]=1.5 (f64 store); then a + b + a from operands pushed AFTER the store.
    m =
      build(0, [
        {:local_get, 0}, {:fconst, 1.5}, {:f64_store, 0},
        {:local_get, 0}, {:local_get, 1}, {:op, 0x6A},
        {:local_get, 0}, {:op, 0x6A}
      ])

    agree(m, for(a <- [0, 7, 8, 16, 100], b <- [0, 1, 0x7F, 0x1234], do: [a, b]))
  end

  test "f32 store+load round-trips finite + nonfinite values" do
    f32_vals = [0.0, 1.0, -2.5, {:nonfinite, 0x7F800000, 32}, {:nonfinite, 0xFF800000, 32}]

    for v <- f32_vals do
      m =
        build_f(0, [
          {:local_get, 0},
          {:fconst, v},
          {:f32_store, 0},
          {:local_get, 0},
          {:f32_load, 0}
        ], 125)

      agree(m, for(a <- [0, 1, 2, 4, 7, 100], do: [a]))
    end
  end
end
