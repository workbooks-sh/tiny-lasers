defmodule TinyLasers.Wasm.AsmOps.I64 do
  @moduledoc """
  **i64 op-group for the BEAM-assembly lane (`TinyLasers.Wasm.TranspileAsm`).** Lowers wasm 64-bit-integer
  ops to BEAM assembly, bit-identical to the interpreter (`TinyLasers.Wasm`) and the abstract-forms lane
  (`TinyLasers.Wasm.Transpile`). i64 values are stored UNSIGNED in `0..2^64-1`; arithmetic wraps mod 2^64
  (`band` mask64); signed compares/div go through branchless `signed_ops(_, 64)`; shifts mask the count
  by 63. Conversions: `i32.wrap_i64` = `band mask32`; `i64.extend_i32_s` = sign-extend a 32-bit value to
  64-bit unsigned; `i64.extend_i32_u` = identity (already an unsigned i32).

  Frame model per `TinyLasers.Wasm.AsmCtx`: persistent values in y-registers, `x0`/`x1` scratch, operand at
  stack pos `yd(s, pos)`, TOP at `yd(s, s.d - 1)`. Returns `{:ok, s}` for ops it owns, `:unsupported`
  for anything else (floats, memory, i32-only ops the core handles).

  div/rem and rotl/rotr trap/wrap exactly like the interpreter; the asm calls the public helpers below
  (`div_s/2`, `div_u/2`, `rem_s/2`, `rem_u/2`, `rotl/2`, `rotr/2`), which reuse `TinyLasers.Wasm.Trap` for
  div-by-zero / signed-overflow — so the raised exception is identical to the interp's `trap!`.
  """
  import Bitwise
  import TinyLasers.Wasm.AsmCtx

  # ── i64 binops via gc_bif, mask mod 2^64 when arithmetic. add/sub/mul wrap; and/or/xor stay in range. ──
  # opcode → {beam_gc_bif, needs_64bit_mask?}
  @binops %{
    0x7C => {:+, true},
    0x7D => {:-, true},
    0x7E => {:*, true},
    0x83 => {:band, false},
    0x84 => {:bor, false},
    0x85 => {:bxor, false}
  }

  # i64 comparisons → {operand-domain, beam-test, swap-args?}. :u compares unsigned stored values
  # directly; :s converts both to signed-64 first (branchless); :eq/:ne exact equality.
  @compares %{
    0x51 => {:eq, :is_eq_exact, false},
    0x52 => {:ne, :is_ne_exact, false},
    0x53 => {:s, :is_lt, false},
    0x54 => {:u, :is_lt, false},
    0x55 => {:s, :is_lt, true},
    0x56 => {:u, :is_lt, true},
    0x57 => {:s, :is_ge, true},
    0x58 => {:u, :is_ge, true},
    0x59 => {:s, :is_ge, false},
    0x5A => {:u, :is_ge, false}
  }

  # div/rem: opcode → {helper-fun, signed?} — emitted as a 2-arg call_ext to our trapping helper.
  @divs %{
    0x7F => {:div_s, true},
    0x80 => {:div_u, false},
    0x81 => {:rem_s, true},
    0x82 => {:rem_u, false}
  }

  # rotates: opcode → helper-fun (count masked by 63 inside the helper).
  @rots %{0x89 => :rotl, 0x8A => :rotr}

  @doc "Op-group entry: `handle(instr, s) -> {:ok, s} | :unsupported`."
  def handle({:i64_const, v}, s), do: {:ok, push(emit(s, [{:move, {:integer, v &&& mask64()}, yd(s, s.d)}]))}

  def handle({:op, opcode}, s) do
    cond do
      Map.has_key?(@binops, opcode) -> {:ok, binop(opcode, s)}
      Map.has_key?(@compares, opcode) -> {:ok, compare(opcode, s)}
      Map.has_key?(@divs, opcode) -> {:ok, divrem(opcode, s)}
      Map.has_key?(@rots, opcode) -> {:ok, rotate(opcode, s)}
      opcode == 0x50 -> {:ok, eqz(s)}
      opcode == 0x86 -> {:ok, shl(s)}
      opcode == 0x88 -> {:ok, shr_u(s)}
      opcode == 0x87 -> {:ok, shr_s(s)}
      opcode == 0xA7 -> {:ok, wrap_i64(s)}
      opcode == 0xAC -> {:ok, extend_s(s)}
      opcode == 0xAD -> {:ok, extend_u(s)}
      true -> :unsupported
    end
  end

  def handle(_instr, _s), do: :unsupported

  # Local Live-aware primitives. The shared AsmCtx `mask_ops`/`signed_ops` hardcode Live=2, which the
  # BEAM validator rejects when x1 is no longer live (e.g. masking a gc_bif/call result where only x0
  # is live). These take an explicit `live` count so each emit declares the right number of live x-regs.
  defp band64(reg, live), do: {:gc_bif, :band, {:f, 0}, live, [reg, {:integer, mask64()}], reg}
  defp band32(reg, live), do: {:gc_bif, :band, {:f, 0}, live, [reg, {:integer, mask32()}], reg}

  # branchless signed-N of `reg` in place: ((reg + 2^(N-1)) band (2^N-1)) - 2^(N-1)
  defp s_ops(reg, 32, live), do: s_ops(reg, 0x80000000, mask32(), live)
  defp s_ops(reg, 64, live), do: s_ops(reg, 0x8000000000000000, mask64(), live)

  defp s_ops(reg, sign, mask, live) do
    [
      {:gc_bif, :+, {:f, 0}, live, [reg, {:integer, sign}], reg},
      {:gc_bif, :band, {:f, 0}, live, [reg, {:integer, mask}], reg},
      {:gc_bif, :-, {:f, 0}, live, [reg, {:integer, sign}], reg}
    ]
  end

  # ── arithmetic / bitwise ──
  defp binop(opcode, s) do
    if s.d < 2, do: throw(:unsupported)
    {beam_op, mask?} = @binops[opcode]

    ops =
      [{:move, yd(s, s.d - 2), {:x, 0}}, {:move, yd(s, s.d - 1), {:x, 1}},
       {:gc_bif, beam_op, {:f, 0}, 2, [{:x, 0}, {:x, 1}], {:x, 0}}] ++
        if(mask?, do: [band64({:x, 0}, 1)], else: []) ++
        [{:move, {:x, 0}, yd(s, s.d - 2)}]

    %{emit(s, ops) | d: s.d - 1}
  end

  # ── comparisons ──
  defp compare(opcode, s) do
    if s.d < 2, do: throw(:unsupported)
    {domain, test_op, swap?} = @compares[opcode]
    load = [{:move, yd(s, s.d - 2), {:x, 0}}, {:move, yd(s, s.d - 1), {:x, 1}}]
    # both x0,x1 hold operands across the conversions → Live=2
    sconv = if domain == :s, do: s_ops({:x, 0}, 64, 2) ++ s_ops({:x, 1}, 64, 2), else: []
    args = if swap?, do: [{:x, 1}, {:x, 0}], else: [{:x, 0}, {:x, 1}]
    store = [{:move, {:x, 0}, yd(s, s.d - 2)}]
    %{emit(s, load ++ sconv ++ branch01(test_op, args, {:x, 0}, s) ++ store) | d: s.d - 1} |> bump_labels(2)
  end

  defp eqz(s) do
    if s.d < 1, do: throw(:unsupported)
    load = [{:move, yd(s, s.d - 1), {:x, 0}}]
    store = [{:move, {:x, 0}, yd(s, s.d - 1)}]
    bump_labels(emit(s, load ++ branch01(:is_eq_exact, [{:x, 0}, {:integer, 0}], {:x, 0}, s) ++ store), 2)
  end

  # ── shifts (count masked by 63) ──
  # i64.shl: (a bsl (b band 63)) band mask64
  defp shl(s) do
    if s.d < 2, do: throw(:unsupported)
    ops =
      [{:move, yd(s, s.d - 2), {:x, 0}}, {:move, yd(s, s.d - 1), {:x, 1}},
       {:gc_bif, :band, {:f, 0}, 2, [{:x, 1}, {:integer, 63}], {:x, 1}},
       {:gc_bif, :bsl, {:f, 0}, 2, [{:x, 0}, {:x, 1}], {:x, 0}},
       band64({:x, 0}, 1),
       {:move, {:x, 0}, yd(s, s.d - 2)}]

    %{emit(s, ops) | d: s.d - 1}
  end

  # i64.shr_u: a bsr (b band 63) — a is unsigned in range, result already in range.
  defp shr_u(s) do
    if s.d < 2, do: throw(:unsupported)
    ops =
      [{:move, yd(s, s.d - 2), {:x, 0}}, {:move, yd(s, s.d - 1), {:x, 1}},
       {:gc_bif, :band, {:f, 0}, 2, [{:x, 1}, {:integer, 63}], {:x, 1}},
       {:gc_bif, :bsr, {:f, 0}, 2, [{:x, 0}, {:x, 1}], {:x, 0}},
       {:move, {:x, 0}, yd(s, s.d - 2)}]

    %{emit(s, ops) | d: s.d - 1}
  end

  # i64.shr_s: (s64(a) bsr (b band 63)) band mask64
  defp shr_s(s) do
    if s.d < 2, do: throw(:unsupported)
    ops =
      [{:move, yd(s, s.d - 2), {:x, 0}}, {:move, yd(s, s.d - 1), {:x, 1}}] ++
        s_ops({:x, 0}, 64, 2) ++
        [{:gc_bif, :band, {:f, 0}, 2, [{:x, 1}, {:integer, 63}], {:x, 1}},
         {:gc_bif, :bsr, {:f, 0}, 2, [{:x, 0}, {:x, 1}], {:x, 0}},
         band64({:x, 0}, 1),
         {:move, {:x, 0}, yd(s, s.d - 2)}]

    %{emit(s, ops) | d: s.d - 1}
  end

  # ── rotates / div / rem via call_ext to our trapping/wrapping helpers (x0=a, x1=b, result→x0) ──
  defp rotate(opcode, s) do
    if s.d < 2, do: throw(:unsupported)
    fun = @rots[opcode]
    ops =
      [{:move, yd(s, s.d - 2), {:x, 0}}, {:move, yd(s, s.d - 1), {:x, 1}},
       {:call_ext, 2, {:extfunc, __MODULE__, fun, 2}},
       {:move, {:x, 0}, yd(s, s.d - 2)}]

    %{emit(s, ops) | d: s.d - 1}
  end

  defp divrem(opcode, s) do
    if s.d < 2, do: throw(:unsupported)
    {fun, _signed?} = @divs[opcode]
    ops =
      [{:move, yd(s, s.d - 2), {:x, 0}}, {:move, yd(s, s.d - 1), {:x, 1}},
       {:call_ext, 2, {:extfunc, __MODULE__, fun, 2}},
       {:move, {:x, 0}, yd(s, s.d - 2)}]

    %{emit(s, ops) | d: s.d - 1}
  end

  # ── conversions ──
  # i32.wrap_i64: a band mask32
  defp wrap_i64(s) do
    if s.d < 1, do: throw(:unsupported)
    ops =
      [{:move, yd(s, s.d - 1), {:x, 0}}, band32({:x, 0}, 1), {:move, {:x, 0}, yd(s, s.d - 1)}]

    emit(s, ops)
  end

  # i64.extend_i32_s: sign-extend a 32-bit value into 64-bit unsigned (s_ops/32 then band mask64).
  defp extend_s(s) do
    if s.d < 1, do: throw(:unsupported)
    ops =
      [{:move, yd(s, s.d - 1), {:x, 0}}] ++
        s_ops({:x, 0}, 32, 1) ++
        [band64({:x, 0}, 1), {:move, {:x, 0}, yd(s, s.d - 1)}]

    emit(s, ops)
  end

  # i64.extend_i32_u: value already an unsigned i32 in range — identity.
  defp extend_u(s) do
    if s.d < 1, do: throw(:unsupported)
    s
  end

  # ── runtime helpers (called from the emitted asm) — mirror the interpreter EXACTLY ──
  @mask64 0xFFFFFFFFFFFFFFFF

  @doc false
  def div_s(a, b), do: idiv(s64(a), s64(b)) &&& @mask64
  @doc false
  def div_u(_a, 0), do: TinyLasers.Wasm.Trap.trap!(:div_by_zero)
  def div_u(a, b), do: div(a, b) &&& @mask64
  @doc false
  def rem_s(a, b), do: irem(s64(a), s64(b)) &&& @mask64
  @doc false
  def rem_u(_a, 0), do: TinyLasers.Wasm.Trap.trap!(:div_by_zero)
  def rem_u(a, b), do: rem(a, b) &&& @mask64

  @doc false
  def rotl(a, b), do: rotl64(a, b &&& 63)
  @doc false
  def rotr(a, b), do: rotr64(a, b &&& 63)

  defp idiv(_a, 0), do: TinyLasers.Wasm.Trap.trap!(:div_by_zero)
  defp idiv(a, -1) when a == -0x8000000000000000, do: TinyLasers.Wasm.Trap.trap!(:int_overflow)
  defp idiv(a, b), do: div(a, b)

  defp irem(_a, 0), do: TinyLasers.Wasm.Trap.trap!(:div_by_zero)
  defp irem(a, b), do: rem(a, b)

  defp s64(x) when x >= 0x8000000000000000, do: x - 0x10000000000000000
  defp s64(x), do: x

  defp rotl64(a, 0), do: a
  defp rotl64(a, n), do: ((a <<< n) ||| (a >>> (64 - n))) &&& @mask64
  defp rotr64(a, 0), do: a
  defp rotr64(a, n), do: ((a >>> n) ||| (a <<< (64 - n))) &&& @mask64
end
