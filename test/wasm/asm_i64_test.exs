defmodule TinyLasers.WasmAsmI64Test do
  @moduledoc """
  **i64 op-group for the BEAM-assembly lane (`TinyLasers.Wasm.AsmOps.I64`).** The asm lane only attempts
  functions whose signature is i32-params → i32-result (`supported_sig?`), so every i64 op is exercised
  as an INTERMEDIATE inside an i32→i32 function: extend the i32 args to i64, do the i64 op, then
  `i32.wrap_i64` back to an i32 result. Each case is A/B'd interp vs asm-native (via the tiering path),
  bit-identical, across edge values (0, max, sign boundaries 2^63, overflow wrap, div-by-zero trap,
  negative signed shifts).
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

  # opcodes
  @extend_s 0xAC
  @extend_u 0xAD
  @wrap 0xA7

  # f(a,b): (extend_kind a) <i64op> (extend_kind b) then wrap_i64 → i32
  defp binop_mod(i64op, ext) do
    build(0, [
      {:local_get, 0}, {:op, ext},
      {:local_get, 1}, {:op, ext},
      {:op, i64op},
      {:op, @wrap}
    ])
  end

  # f(a,b): bool( (extend_kind a) <cmp> (extend_kind b) ) — already i32 (0/1), no wrap needed
  defp cmp_mod(i64op, ext) do
    build(0, [
      {:local_get, 0}, {:op, ext},
      {:local_get, 1}, {:op, ext},
      {:op, i64op}
    ])
  end

  defp agree(m, args) do
    {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0)
    {interp, _} = Wasm.call_io(m, "f", args, transpile: false)
    asm = apply(am, af, args)
    assert interp == asm, "@ #{inspect(args)}: interp=#{inspect(interp)} asm=#{inspect(asm)}"
  end

  @edge [
    [0, 0], [1, 1], [5, 3], [3, 5],
    [0xFFFFFFFF, 1], [1, 0xFFFFFFFF], [0xFFFFFFFF, 0xFFFFFFFF],
    [0x80000000, 1], [0x7FFFFFFF, 0x80000000], [0x80000000, 0x80000000],
    [0, 0xFFFFFFFF], [12345, 67890]
  ]

  test "i64 const + arithmetic (add/sub/mul) wraps mod 2^64, bit-identical (via extend_s)" do
    for op <- [0x7C, 0x7D, 0x7E], args <- @edge do
      agree(binop_mod(op, @extend_s), args)
    end
  end

  test "i64 bitwise (and/or/xor) bit-identical (via extend_u)" do
    for op <- [0x83, 0x84, 0x85], args <- @edge do
      agree(binop_mod(op, @extend_u), args)
    end
  end

  test "i64 shifts (shl/shr_u/shr_s) mask count by 63, bit-identical incl. negative signed values" do
    # shr_s on a sign-extended negative must propagate the sign bit
    for op <- [0x86, 0x88, 0x87], args <- @edge do
      agree(binop_mod(op, @extend_s), args)
    end
  end

  test "i64 rotates (rotl/rotr) bit-identical" do
    for op <- [0x89, 0x8A], args <- @edge do
      agree(binop_mod(op, @extend_u), args)
    end
  end

  test "i64 div_u/rem_u bit-identical, non-zero divisors" do
    nz = Enum.filter(@edge, fn [_, b] -> b != 0 end)
    for op <- [0x80, 0x82], args <- nz do
      agree(binop_mod(op, @extend_u), args)
    end
  end

  test "i64 div_s/rem_s bit-identical, incl. sign-extended negatives" do
    nz = Enum.filter(@edge, fn [_, b] -> b != 0 end)
    for op <- [0x7F, 0x81], args <- nz do
      agree(binop_mod(op, @extend_s), args)
    end
  end

  test "i64 div/rem trap on divide-by-zero exactly like the interpreter" do
    for op <- [0x7F, 0x80, 0x81, 0x82], ext <- [@extend_s, @extend_u] do
      m = binop_mod(op, ext)
      {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0)
      assert_raise TinyLasers.Wasm.Trap, fn -> apply(am, af, [5, 0]) end
    end
  end

  test "i64.div_s INT64_MIN / -1 traps :int_overflow like the interpreter" do
    # build i64 INT64_MIN directly: extend_s(0x80000000) << 32  (== 0x8000000000000000),
    # divide by extend_s(0xFFFFFFFF) (== -1). Both via shl path.
    instrs = [
      {:local_get, 0}, {:op, @extend_s},
      {:i64_const, 32}, {:op, 0x86},
      {:local_get, 1}, {:op, @extend_s},
      {:op, 0x7F},
      {:op, @wrap}
    ]
    m = build(0, instrs)
    {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0)
    # a=0x80000000 -> shl 32 -> 0x8000000000000000; b=0xFFFFFFFF -> extend_s -> -1
    assert_raise TinyLasers.Wasm.Trap, fn -> apply(am, af, [0x80000000, 0xFFFFFFFF]) end
  end

  test "i64 comparisons (signed + unsigned) bit-identical across sign boundaries" do
    cmps = [0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A]
    for op <- cmps, ext <- [@extend_s, @extend_u], args <- @edge do
      agree(cmp_mod(op, ext), args)
    end
  end

  test "i64.eqz bit-identical" do
    for ext <- [@extend_s, @extend_u], args <- [[0, 0], [1, 0], [0xFFFFFFFF, 0], [0x80000000, 0]] do
      m = build(0, [{:local_get, 0}, {:op, ext}, {:op, 0x50}])
      agree(m, args)
    end
  end

  test "conversions i32.wrap_i64 / extend_i32_s / extend_i32_u bit-identical, incl. 2^63 boundary" do
    # extend_s then wrap should round-trip the low 32 bits; extend_u likewise.
    for ext <- [@extend_s, @extend_u], args <- @edge do
      m = build(0, [{:local_get, 0}, {:op, ext}, {:op, @wrap}])
      agree(m, args)
    end
  end

  test "the i64 ops are intermediates: a full mixed expression matches interp" do
    # f(a,b) = wrap( ((extend_s a) * (extend_s b)) +64 ((extend_u a) shr_u 3) )
    instrs = [
      {:local_get, 0}, {:op, @extend_s},
      {:local_get, 1}, {:op, @extend_s},
      {:op, 0x7E},
      {:local_get, 0}, {:op, @extend_u},
      {:i64_const, 3}, {:op, 0x88},
      {:op, 0x7C},
      {:op, @wrap}
    ]
    m = build(0, instrs)
    for args <- @edge, do: agree(m, args)
  end
end
