defmodule TinyLasers.WasmAsmFloatsTest do
  @moduledoc """
  **Float op-group for the BEAM-assembly lane (`TinyLasers.Wasm.AsmOps.Floats`).** The asm lane only attempts
  i32→i32 functions, so floats are exercised as INTERMEDIATES: args are converted i32→f64, float math runs,
  and the result is truncated back to i32. A/Bs interp vs asm-native (tier_threshold:1) — must be
  bit-identical — across arithmetic, compares, conversions, reinterprets, and a NaN/Inf path.
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

  # a, b are i32; convert to f64 (signed), run `body` (f64 ops), trunc result f64→i32_s back to i32.
  defp f64fn(body) do
    [{:local_get, 0}, {:op, 0xB7}, {:local_get, 1}, {:op, 0xB7}] ++ body ++ [{:op, 0xAA}]
  end

  defp assert_ab(name, instrs, argsets) do
    m = build(0, instrs)
    assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0), "#{name}: should emit via from_asm"

    for args <- argsets do
      {interp, _} = Wasm.call_io(m, "f", args, transpile: false)
      asm = apply(am, af, args)

      assert interp == asm,
             "#{name} @ #{inspect(args)}: interp=#{inspect(interp)} asm=#{inspect(asm)}"
    end
  end

  @ab [[7, 3], [3, 7], [10, 4], [0, 5], [5, 0], [100, 6], [0xFFFFFFFF, 2]]

  test "f64 arithmetic (add/sub/mul/div) as i32→f64→i32 intermediates == interp" do
    for {n, op} <- [{"add", 0xA0}, {"sub", 0xA1}, {"mul", 0xA2}, {"div", 0xA3}] do
      assert_ab("f64.#{n}", f64fn([{:op, op}]), Enum.reject(@ab, fn [_, b] -> op == 0xA3 and b == 0 end))
    end
  end

  test "f64 min/max/copysign == interp" do
    for {n, op} <- [{"min", 0xA4}, {"max", 0xA5}, {"copysign", 0xA6}] do
      assert_ab("f64.#{n}", f64fn([{:op, op}]), @ab)
    end
  end

  test "f64 unary abs/neg/sqrt/ceil/floor/trunc/nearest == interp" do
    # use (a/b) as a non-integer operand so ceil/floor/trunc/nearest differ
    pre = [{:local_get, 0}, {:op, 0xB7}, {:local_get, 1}, {:op, 0xB7}, {:op, 0xA3}]

    for {n, op} <- [{"abs", 0x99}, {"neg", 0x9A}, {"sqrt", 0x9F},
                    {"ceil", 0x9B}, {"floor", 0x9C}, {"trunc", 0x9D}, {"nearest", 0x9E}] do
      m = build(0, pre ++ [{:op, op}, {:op, 0xAA}])
      assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0), "f64.#{n}: should emit"

      for args <- [[7, 3], [3, 7], [10, 4], [9, 4], [11, 2], [100, 7]] do
        {interp, _} = Wasm.call_io(m, "f", args, transpile: false)
        assert interp == apply(am, af, args), "f64.#{n} @ #{inspect(args)}"
      end
    end
  end

  test "f64 compares (eq/ne/lt/gt/le/ge) → 0/1 == interp" do
    for {n, op} <- [{"eq", 0x61}, {"ne", 0x62}, {"lt", 0x63}, {"gt", 0x64}, {"le", 0x65}, {"ge", 0x66}] do
      # compare yields i32 0/1 directly; no trunc needed
      m = build(0, [{:local_get, 0}, {:op, 0xB7}, {:local_get, 1}, {:op, 0xB7}, {:op, op}])
      assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0), "f64.#{n}: should emit"

      for args <- [[5, 3], [3, 5], [5, 5], [0, 0], [0xFFFFFFFF, 1], [1, 1]] do
        {interp, _} = Wasm.call_io(m, "f", args, transpile: false)
        assert interp == apply(am, af, args), "f64.#{n} @ #{inspect(args)}"
      end
    end
  end

  test "f32 arithmetic + compares (single-precision rounding) == interp" do
    # convert via f32.convert_i32_s (0xB2), f32 math, then trunc f32→i32_s (0xA8)
    for {n, op} <- [{"add", 0x92}, {"sub", 0x93}, {"mul", 0x94}, {"div", 0x95},
                    {"min", 0x96}, {"max", 0x97}, {"copysign", 0x98}] do
      body = [{:local_get, 0}, {:op, 0xB2}, {:local_get, 1}, {:op, 0xB2}, {:op, op}, {:op, 0xA8}]
      assert_ab("f32.#{n}", body, Enum.reject(@ab, fn [_, b] -> op == 0x95 and b == 0 end))
    end

    for {n, op} <- [{"eq", 0x5B}, {"lt", 0x5D}, {"ge", 0x60}] do
      m = build(0, [{:local_get, 0}, {:op, 0xB2}, {:local_get, 1}, {:op, 0xB2}, {:op, op}])
      assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0), "f32.#{n}: should emit"
      for args <- [[5, 3], [3, 5], [5, 5]] do
        {interp, _} = Wasm.call_io(m, "f", args, transpile: false)
        assert interp == apply(am, af, args), "f32.#{n} @ #{inspect(args)}"
      end
    end
  end

  test "f32 unary abs/neg/sqrt/ceil/floor/trunc/nearest == interp" do
    pre = [{:local_get, 0}, {:op, 0xB2}, {:local_get, 1}, {:op, 0xB2}, {:op, 0x95}]

    for {n, op} <- [{"abs", 0x8B}, {"neg", 0x8C}, {"sqrt", 0x91},
                    {"ceil", 0x8D}, {"floor", 0x8E}, {"trunc", 0x8F}, {"nearest", 0x90}] do
      m = build(0, pre ++ [{:op, op}, {:op, 0xA8}])
      assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0), "f32.#{n}: should emit"
      for args <- [[7, 3], [3, 7], [10, 4], [9, 4]] do
        {interp, _} = Wasm.call_io(m, "f", args, transpile: false)
        assert interp == apply(am, af, args), "f32.#{n} @ #{inspect(args)}"
      end
    end
  end

  test "conversions: convert_i32_u, demote/promote, reinterprets == interp" do
    # f64.convert_i32_u (0xB8): unsigned, so 0xFFFFFFFF stays large
    assert_ab("f64.convert_i32_u", [{:local_get, 0}, {:op, 0xB8}, {:op, 0xAB}, {:local_get, 1}, {:op, 0x6A}], @ab)

    # demote f64→f32 (0xB6) then promote f32→f64 (0xBB), round-trip (avoid div-by-zero: use mul not div)
    assert_ab(
      "demote/promote",
      [{:local_get, 0}, {:op, 0xB7}, {:local_get, 1}, {:op, 0xB7}, {:op, 0xA2}, {:op, 0xB6}, {:op, 0xBB}, {:op, 0xAA}],
      @ab
    )

    # i32.reinterpret_f32 (0xBC) of f32.convert(a): bit pattern back to i32
    assert_ab("i32.reinterpret_f32", [{:local_get, 0}, {:op, 0xB2}, {:op, 0xBC}, {:local_get, 1}, {:op, 0x6A}], @ab)

    # f32.reinterpret_i32 (0xBE) then i32.reinterpret_f32 (0xBC): round-trip bits. Includes NON-FINITE f32
    # bit patterns (±Inf 0x7F800000/0xFF800000, NaN 0x7FC00000) — the asm float<->bits helpers carry these
    # as the interpreter's {:nonfinite, bits, size} placeholder (wb-95w7: f32_from_bits/f32_to_bits were
    # raising "construction of binary failed" / a float-match failure on these, desyncing conformance).
    assert_ab(
      "reinterpret roundtrip",
      [{:local_get, 0}, {:op, 0xBE}, {:op, 0xBC}, {:local_get, 1}, {:op, 0x6A}],
      [[0x3F800000, 0], [0x40490FDB, 1], [0, 2], [0xC0000000, 3],
       [0x7F800000, 0], [0xFF800000, 1], [0x7FC00000, 2]]
    )
  end

  test "i64 conversion path: f64.convert_i64_s then i64.trunc_f64_s, wrap to i32 == interp" do
    # i64.extend_i32_s (0xAC) → f64.convert_i64_s (0xB9) → i64.trunc_f64_s (0xB0) → i32.wrap_i64 (0xA7)
    assert_ab(
      "i64 convert/trunc",
      [{:local_get, 0}, {:op, 0xAC}, {:op, 0xB9}, {:op, 0xB0}, {:op, 0xA7}, {:local_get, 1}, {:op, 0x6A}],
      @ab
    )
  end

  test "f64 reinterpret of non-finite bit patterns round-trips == interp (wb-95w7)" do
    # i64.const bits → f64.reinterpret_i64 (0xBF → f64_from_bits) → i64.reinterpret_f64 (0xBD → f64_to_bits)
    # → i32.wrap_i64. The high f64 bits (±Inf/NaN) must survive as {:nonfinite,_,64} through BOTH asm helpers
    # and come back bit-identical to the interpreter — the latent crash the store-depth fix exposed.
    for {name, bits} <- [{"+Inf", 0x7FF0000000000000}, {"-Inf", 0xFFF0000000000000}, {"NaN", 0x7FF8000000000000}] do
      m = build(0, [{:i64_const, bits}, {:op, 0xBF}, {:op, 0xBD}, {:op, 0xA7}, {:local_get, 0}, {:op, 0x6A}])
      assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0), "#{name}: should emit"

      for args <- [[0, 0], [7, 1]] do
        {interp, _} = Wasm.call_io(m, "f", args, transpile: false)
        assert interp == apply(am, af, args), "#{name} @ #{inspect(args)}: interp=#{inspect(interp)}"
      end
    end
  end

  test "NaN/Inf fconst literal (nonfinite tuple) + compares == interp" do
    # this interpreter carries NaN/Inf as `{:nonfinite, bits, size}` (BEAM has no real NaN/Inf). A float
    # const decoding to non-finite is pushed as that literal; the asm lane stores it via {:move,{:literal,_}}.
    nan = {:nonfinite, 0x7FF8000000000000, 64}
    inf = {:nonfinite, 0x7FF0000000000000, 64}

    # compare a non-finite const against the finite f64(a). Both lanes fall to BEAM term ordering for the
    # tuple operand (number < tuple), so eq/ne/lt/gt/le/ge agree bit-for-bit.
    for {kind, c} <- [{"nan", nan}, {"inf", inf}], {n, op} <- [{"eq", 0x61}, {"ne", 0x62}, {"lt", 0x63}, {"ge", 0x66}] do
      m = build(0, [{:fconst, c}, {:local_get, 0}, {:op, 0xB7}, {:op, op}])
      assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0), "#{kind}.#{n}: should emit"

      for args <- [[5, 0], [0, 0], [0xFFFFFFFF, 1]] do
        {interp, _} = Wasm.call_io(m, "f", args, transpile: false)
        assert interp == apply(am, af, args), "#{kind}.#{n} @ #{inspect(args)}: interp=#{inspect(interp)}"
      end
    end
  end

  # ── IEEE-754 non-finite arithmetic (wb-8mdz.3): div0 / overflow / non-finite operands now run NATIVE in
  # the asm lane (guest_farith) instead of raising. f64/f32-returning so the result IS the ±Inf/NaN. ──
  defp fbin_mod(op, type) do
    %Wasm{
      types: [type], funcs: [0],
      code: [{0, [{:local_get, 0}, {:local_get, 1}, {:op, op}]}],
      exports: %{"f" => 0}, mem: {1, nil}, globals: [], data: [], imports: [], elements: [],
      id: :crypto.hash(:sha256, :erlang.term_to_binary({op, type}))
    }
  end

  @pinf64 {:nonfinite, 0x7FF0000000000000, 64}

  test "f64 add/sub/mul/div: div0 / overflow / non-finite operand — asm-native (no fallback) AND == interp" do
    cases = [
      {0xA3, [6.0, 2.0]}, {0xA3, [1.0, 0.0]}, {0xA3, [-1.0, 0.0]}, {0xA3, [0.0, 0.0]},
      {0xA2, [1.0e308, 100.0]}, {0xA0, [1.0e308, 1.0e308]}, {0xA1, [1.0e308, -1.0e308]},
      {0xA3, [@pinf64, 2.0]}, {0xA2, [@pinf64, 0.0]}
    ]

    for {op, args} <- cases do
      m = fbin_mod(op, {[124, 124], [124]})
      assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0), "f64 0x#{Integer.to_string(op, 16)}: asm must emit"
      {interp, _} = Wasm.call_io(m, "f", args, transpile: false)
      assert interp == apply(am, af, args), "f64 0x#{Integer.to_string(op, 16)} @ #{inspect(args)}: interp=#{inspect(interp)}"
    end
  end

  test "f32 div0 + overflow: asm-native AND == interp (single precision)" do
    for {op, args} <- [{0x95, [1.0, 0.0]}, {0x95, [6.0, 2.0]}, {0x94, [3.0e38, 100.0]}, {0x92, [3.0e38, 3.0e38]}] do
      m = fbin_mod(op, {[125, 125], [125]})
      assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0), "f32 0x#{Integer.to_string(op, 16)}: asm must emit"
      {interp, _} = Wasm.call_io(m, "f", args, transpile: false)
      assert interp == apply(am, af, args), "f32 0x#{Integer.to_string(op, 16)} @ #{inspect(args)}: interp=#{inspect(interp)}"
    end
  end

  @nan64 {:nonfinite, 0x7FF8000000000000, 64}

  test "f64 min/max with NaN/Inf operands: asm-native AND == interp" do
    for {op, args} <- [
          {0xA4, [5.0, 3.0]}, {0xA5, [5.0, 3.0]},
          {0xA4, [@nan64, 1.0]}, {0xA5, [1.0, @nan64]},
          {0xA4, [@pinf64, 1.0]}, {0xA5, [@pinf64, 1.0]}
        ] do
      m = fbin_mod(op, {[124, 124], [124]})
      assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0), "min/max 0x#{Integer.to_string(op, 16)}: asm must emit"
      {interp, _} = Wasm.call_io(m, "f", args, transpile: false)
      assert interp == apply(am, af, args), "0x#{Integer.to_string(op, 16)} @ #{inspect(args)}: interp=#{inspect(interp)}"
    end
  end

  defp funary_mod(op) do
    %Wasm{
      types: [{[124], [124]}], funcs: [0],
      code: [{0, [{:local_get, 0}, {:op, op}]}],
      exports: %{"f" => 0}, mem: {1, nil}, globals: [], data: [], imports: [], elements: [],
      id: :crypto.hash(:sha256, :erlang.term_to_binary({:unary, op}))
    }
  end

  test "f64 abs/neg/sqrt on finite + ±Inf + NaN + sqrt(-1): asm-native AND == interp" do
    for {op, args} <- [
          {0x99, [-5.0]}, {0x99, [@pinf64]},                    # abs
          {0x9A, [5.0]}, {0x9A, [@pinf64]}, {0x9A, [@nan64]},   # neg
          {0x9F, [4.0]}, {0x9F, [-1.0]}, {0x9F, [@pinf64]}      # sqrt (sqrt(-1)=NaN)
        ] do
      m = funary_mod(op)
      assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0), "unary 0x#{Integer.to_string(op, 16)}: asm must emit"
      {interp, _} = Wasm.call_io(m, "f", args, transpile: false)
      assert interp == apply(am, af, args), "0x#{Integer.to_string(op, 16)} @ #{inspect(args)}: interp=#{inspect(interp)}"
    end
  end

  test "f64 ceil/floor/trunc/nearest + copysign on finite/±Inf/NaN: asm-native AND == interp" do
    # unary rounding ops
    for {op, args} <- [
          {0x9B, [2.3]}, {0x9B, [@pinf64]}, {0x9B, [@nan64]},   # ceil
          {0x9C, [2.7]}, {0x9C, [@pinf64]},                     # floor
          {0x9D, [2.9]}, {0x9D, [@pinf64]},                     # trunc
          {0x9E, [2.5]}, {0x9E, [@pinf64]}                      # nearest (ties-even)
        ] do
      m = funary_mod(op)
      assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0), "round 0x#{Integer.to_string(op, 16)}: asm must emit"
      {interp, _} = Wasm.call_io(m, "f", args, transpile: false)
      assert interp == apply(am, af, args), "0x#{Integer.to_string(op, 16)} @ #{inspect(args)}: interp=#{inspect(interp)}"
    end

    # copysign (binary): magnitude of a, sign of b — incl. non-finite a
    for args <- [[5.0, -1.0], [5.0, 1.0], [@pinf64, -1.0], [5.0, @nan64], [@nan64, -1.0]] do
      m = fbin_mod(0xA6, {[124, 124], [124]})
      assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0), "copysign: asm must emit"
      {interp, _} = Wasm.call_io(m, "f", args, transpile: false)
      assert interp == apply(am, af, args), "copysign @ #{inspect(args)}: interp=#{inspect(interp)}"
    end
  end
end
