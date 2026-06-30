defmodule TinyLasers.Wasm.AsmOps.Floats do
  @moduledoc """
  **Float op-group for the BEAM-assembly lane (`TinyLasers.Wasm.TranspileAsm`).** Lowers wasm f32/f64 ops to
  BEAM assembly, **bit-identical to the interpreter** by construction: every op emits a `call_ext` to the
  SAME `TinyLasers.Wasm.Transpile`/`:erlang`/`:math`/`Float` helper the abstract-forms lane uses (or a `gc_bif`
  for the raw `+ - * /` the forms lane lowers to a plain operator on Erlang floats). No float math is
  re-derived here — the forms lane is the semantics, and we call into it.

  Frame model is the shared `TinyLasers.Wasm.AsmCtx` contract: operands live in `y`-registers; `x0`/`x1` are
  transient scratch. Each op loads operand(s) `y → x`, computes (gc_bif / call_ext), stores result `x → y`.

  Covered (all f32 + f64): `fconst` (incl. NaN/Inf `{:nonfinite,_,_}` literals); arithmetic add/sub/mul/div/
  min/max/abs/neg/sqrt/ceil/floor/trunc/nearest/copysign; compares eq/ne/lt/gt/le/ge (0/1 i32 via the test
  ops); conversions i32/i64.trunc_f*, f*.convert_i*, f32.demote_f64, f64.promote_f32; reinterprets. The lane
  caller only attempts i32→i32 signatures, so floats appear as intermediates. Any non-float op → `:unsupported`.
  """
  import TinyLasers.Wasm.AsmCtx

  @transpile :"Elixir.TinyLasers.Wasm.Transpile"
  @tinylasers :"Elixir.TinyLasers.Wasm"

  # ── float const ──────────────────────────────────────────────────────────────────────────────────
  # finite floats AND non-finite `{:nonfinite, bits, size}` tuples are stored as a literal move (BEAM asm
  # supports `{:move, {:literal, Term}, dst}`), matching what the interpreter / forms lane push.
  def handle({:fconst, v}, s), do: {:ok, push(emit(s, [{:move, {:literal, v}, yd(s, s.d)}]))}

  def handle({:op, opcode}, s) do
    cond do
      Map.has_key?(binops(), opcode) -> {:ok, fbinop(opcode, s)}
      Map.has_key?(compares(), opcode) -> {:ok, fcompare(opcode, s)}
      Map.has_key?(unops(), opcode) -> {:ok, funop(opcode, s)}
      true -> :unsupported
    end
  end

  # saturating float→int trunc (0xFC 0..7). n 0..3 → i32, 4..7 → i64. Mirrors the interpreter:
  # wtrunc_sat(a) (trunc if float, passthrough if int) masked to 32/64 bits.
  def handle({:trunc_sat, n}, s) when n in 0..7 do
    if s.d < 1, do: throw(:unsupported)
    top = s.d - 1
    mask = if n <= 3, do: 0xFFFFFFFF, else: 0xFFFFFFFFFFFFFFFF

    ops = [
      {:move, yd(s, top), {:x, 0}},
      {:call_ext, 1, {:extfunc, @transpile, :wtrunc_sat, 1}},
      {:gc_bif, :band, {:f, 0}, 1, [{:x, 0}, {:integer, mask}], {:x, 0}},
      {:move, {:x, 0}, yd(s, top)}
    ]

    {:ok, emit(s, ops)}
  end

  def handle(_instr, _s), do: :unsupported

  # ── binary float ops (pop 2, push 1) ───────────────────────────────────────────────────────────────
  # each value is a `{gc_bif | call_ext, f32round?}` spec; result computed into x0, optionally re-rounded
  # to single precision via Transpile.f32r/1 (the f32 lane), then stored back.
  defp binops do
    %{
      # f64 + - * / route through TinyLasers.Wasm.guest_farith (IEEE-754: div0/overflow/non-finite → ±Inf/NaN,
      # bit-identical to the interp) instead of a raw gc_bif that would raise ArithmeticError. guest_farith
      # rounds f32 via its `size` arg, so these specs carry the size and need no separate f32 round.
      0xA0 => {{:farith, :add, 64}, false},
      0xA1 => {{:farith, :sub, 64}, false},
      0xA2 => {{:farith, :mul, 64}, false},
      0xA3 => {{:farith, :div, 64}, false},
      0xA4 => {{:fminmax, :min, 64}, false},
      0xA5 => {{:fminmax, :max, 64}, false},
      0xA6 => {{:fcopysign, 64}, false},
      # f32: same IEEE math, guest_farith rounds the result to single precision (size 32)
      0x92 => {{:farith, :add, 32}, false},
      0x93 => {{:farith, :sub, 32}, false},
      0x94 => {{:farith, :mul, 32}, false},
      0x95 => {{:farith, :div, 32}, false},
      0x96 => {{:fminmax, :min, 32}, false},
      0x97 => {{:fminmax, :max, 32}, false},
      0x98 => {{:fcopysign, 32}, false}
    }
  end

  defp fbinop(opcode, s) do
    if s.d < 2, do: throw(:unsupported)
    {spec, round?} = binops()[opcode]
    load = [{:move, yd(s, s.d - 2), {:x, 0}}, {:move, yd(s, s.d - 1), {:x, 1}}]

    compute =
      case spec do
        {:farith, op, size} ->
          # guest_farith(a, b, op, size) — IEEE-correct, and rounds f32 internally (no extra f32round).
          [{:move, {:atom, op}, {:x, 2}}, {:move, {:integer, size}, {:x, 3}},
           {:call_ext, 4, {:extfunc, @tinylasers, :guest_farith, 4}}]

        {:fminmax, which, size} ->
          # guest_fminmax(a, b, which, size) — NaN-propagating min/max, non-finite-safe.
          [{:move, {:atom, which}, {:x, 2}}, {:move, {:integer, size}, {:x, 3}},
           {:call_ext, 4, {:extfunc, @tinylasers, :guest_fminmax, 4}}]

        {:fcopysign, size} ->
          # guest_fcopysign(a, b, size) — magnitude of a (incl. Inf/NaN) carrying the sign of b.
          [{:move, {:integer, size}, {:x, 2}}, {:call_ext, 3, {:extfunc, @tinylasers, :guest_fcopysign, 3}}]

        {:gc_bif, op} ->
          [{:gc_bif, op, {:f, 0}, 2, [{:x, 0}, {:x, 1}], {:x, 0}}]

        {:ext, m, f} ->
          [{:call_ext, 2, {:extfunc, ext_mod(m), f, 2}}]
      end

    # farith already applies single-precision rounding via its size arg; other specs use f32round(round?).
    round_ops = case spec do
      {:farith, _, _} -> []
      _ -> f32round(round?)
    end

    store = [{:move, {:x, 0}, yd(s, s.d - 2)}]
    %{emit(s, load ++ compute ++ round_ops ++ store) | d: s.d - 1}
  end

  # ── unary float ops (pop 1, push 1) ────────────────────────────────────────────────────────────────
  # spec is a chain of stages applied to x0 in order. stages:
  #   {:gc_bif, op, arg}            — unary gc_bif on x0 (neg)
  #   {:ext, mod, fun}             — call_ext/1 on x0
  #   {:ext2lit, mod, fun, lit}    — call_ext/2 with x0 + a literal-integer second arg (trunc range checks)
  #   :s32 | :s64                  — signed-N of x0 in place (for signed int→float convert)
  #   {:fmul1}                     — x0 * 1.0  (int→float)
  #   {:band, mask}                — x0 band mask (reinterpret-from-int width mask)
  #   :f32r                        — round x0 to single precision
  defp unops do
    %{
      # f64 abs/neg/sqrt — IEEE non-finite-safe (sqrt(-x)=NaN, abs/neg of ±Inf) via guest_* mirrors.
      0x99 => [{:gfun, :guest_fabs, 64}],
      0x9A => [{:gfun, :guest_fneg, 64}],
      0x9F => [{:gfun, :guest_fsqrt, 64}],
      # f32 abs/neg/sqrt — guest_* rounds to single precision via size 32 (no separate :f32r needed).
      0x8B => [{:gfun, :guest_fabs, 32}],
      0x8C => [{:gfun, :guest_fneg, 32}],
      0x91 => [{:gfun, :guest_fsqrt, 32}],
      # f64 ceil/floor/trunc/nearest
      0x9B => [{:gfun, :guest_fceil, 64}],
      0x9C => [{:gfun, :guest_ffloor, 64}],
      0x9D => [{:gfun, :guest_ftrunc, 64}],
      0x9E => [{:gfun, :guest_fnearest, 64}],
      # f32 ceil/floor/trunc/nearest (round)
      0x8D => [{:gfun, :guest_fceil, 32}],
      0x8E => [{:gfun, :guest_ffloor, 32}],
      0x8F => [{:gfun, :guest_ftrunc, 32}],
      0x90 => [{:gfun, :guest_fnearest, 32}],
      # float→int trunc (range-checked) then mask to width
      0xA8 => [{:trunc_int, -0x80000000, 0x7FFFFFFF, mask32()}],
      0xA9 => [{:trunc_int, 0, 0xFFFFFFFF, mask32()}],
      0xAA => [{:trunc_int, -0x80000000, 0x7FFFFFFF, mask32()}],
      0xAB => [{:trunc_int, 0, 0xFFFFFFFF, mask32()}],
      0xAE => [{:trunc_int, -0x8000000000000000, 0x7FFFFFFFFFFFFFFF, mask64()}],
      0xAF => [{:trunc_int, 0, 0xFFFFFFFFFFFFFFFF, mask64()}],
      0xB0 => [{:trunc_int, -0x8000000000000000, 0x7FFFFFFFFFFFFFFF, mask64()}],
      0xB1 => [{:trunc_int, 0, 0xFFFFFFFFFFFFFFFF, mask64()}],
      # int→float
      0xB2 => [:s32, :fmul1, :f32r],
      0xB3 => [:fmul1, :f32r],
      0xB4 => [:s64, :fmul1, :f32r],
      0xB5 => [:fmul1, :f32r],
      0xB7 => [:s32, :fmul1],
      0xB8 => [:fmul1],
      0xB9 => [:s64, :fmul1],
      0xBA => [:fmul1],
      # f32.demote_f64 (round), f64.promote_f32 (identity)
      0xB6 => [:f32r],
      0xBB => [],
      # reinterprets
      0xBC => [{:ext, @transpile, :f32_to_bits}],
      0xBD => [{:ext, @transpile, :f64_to_bits}],
      0xBE => [{:band, mask32()}, {:ext, @transpile, :f32_from_bits}],
      0xBF => [{:band, mask64()}, {:ext, @transpile, :f64_from_bits}]
    }
  end

  defp funop(opcode, s) do
    if s.d < 1, do: throw(:unsupported)
    stages = unops()[opcode]
    load = [{:move, yd(s, s.d - 1), {:x, 0}}]
    body = Enum.flat_map(stages, &stage/1)
    store = [{:move, {:x, 0}, yd(s, s.d - 1)}]
    emit(s, load ++ body ++ store)
  end

  # IEEE non-finite-safe unary via a TinyLasers.Wasm.guest_* mirror taking (x0, size).
  defp stage({:gfun, fun, size}), do: [{:move, {:integer, size}, {:x, 1}}, {:call_ext, 2, {:extfunc, @tinylasers, fun, 2}}]
  defp stage({:gc_bif, op, :unary}), do: [{:gc_bif, op, {:f, 0}, 1, [{:x, 0}], {:x, 0}}]
  defp stage({:ext, m, f}), do: [{:call_ext, 1, {:extfunc, ext_mod(m), f, 1}}]
  defp stage(:f32r), do: f32round(true)
  # signed-N of x0 in place (Live=1: only x0 is live in the unary convert path). Matches AsmCtx.signed_ops
  # math but with the correct live count for this single-operand context.
  defp stage(:s32), do: signed1({:x, 0}, 0x80000000, mask32())
  defp stage(:s64), do: signed1({:x, 0}, 0x8000000000000000, mask64())

  defp signed1(r, sign, mask) do
    [
      {:gc_bif, :+, {:f, 0}, 1, [r, {:integer, sign}], r},
      {:gc_bif, :band, {:f, 0}, 1, [r, {:integer, mask}], r},
      {:gc_bif, :-, {:f, 0}, 1, [r, {:integer, sign}], r}
    ]
  end
  defp stage(:fmul1), do: [{:gc_bif, :*, {:f, 0}, 1, [{:x, 0}, {:float, 1.0}], {:x, 0}}]
  defp stage({:band, mask}), do: [{:gc_bif, :band, {:f, 0}, 1, [{:x, 0}, {:integer, mask}], {:x, 0}}]

  defp stage({:trunc_int, lo, hi, mask}) do
    [
      {:move, {:integer, lo}, {:x, 1}},
      {:move, {:integer, hi}, {:x, 2}},
      {:call_ext, 3, {:extfunc, ext_mod(@transpile), :ftrunc_int, 3}},
      {:gc_bif, :band, {:f, 0}, 1, [{:x, 0}, {:integer, mask}], {:x, 0}}
    ]
  end

  # ── float compares (pop 2, push 0/1) ───────────────────────────────────────────────────────────────
  # Fast path: BOTH operands finite Erlang floats (the common case — Porffor f64 compares are on
  # pointers/positions, never ±Inf/NaN) → a BEAM `test` directly yields 0/1, no call_ext. Slow path: either
  # operand is a `{:nonfinite,…}` tuple (is_float fails) → fall back to guest_fcmp (IEEE NaN-unordered, the
  # SAME fcmp the interp uses; BEAM term order would mis-rank a nonfinite tuple vs the interp). Bit-identical
  # because an Erlang float (is_float true) is always finite here — decode_f boxes Inf/NaN as tuples.
  defp compares do
    %{
      0x61 => :eq, 0x62 => :ne, 0x63 => :lt, 0x64 => :gt, 0x65 => :le, 0x66 => :ge,
      0x5B => :eq, 0x5C => :ne, 0x5D => :lt, 0x5E => :gt, 0x5F => :le, 0x60 => :ge
    }
  end

  # fcmp op → {BEAM test, swap-args?}. `is_eq`/`is_ne` (not _exact) so -0.0 == 0.0 matches the interp's
  # fcompare({:fin,-0.0},{:fin,0.0})==0 → :eq true. gt/le via is_lt/is_ge with swapped operands.
  defp fcmp_test(:eq), do: {:is_eq, false}
  defp fcmp_test(:ne), do: {:is_ne, false}
  defp fcmp_test(:lt), do: {:is_lt, false}
  defp fcmp_test(:gt), do: {:is_lt, true}
  defp fcmp_test(:le), do: {:is_ge, true}
  defp fcmp_test(:ge), do: {:is_ge, false}

  defp fcompare(opcode, s) do
    if s.d < 2, do: throw(:unsupported)
    op = compares()[opcode]
    {test_op, swap?} = fcmp_test(op)
    l_slow = s.lbl
    l_fail = s.lbl + 1
    l_end = s.lbl + 2
    args = if swap?, do: [{:x, 1}, {:x, 0}], else: [{:x, 0}, {:x, 1}]

    ops = [
      {:move, yd(s, s.d - 2), {:x, 0}},
      {:move, yd(s, s.d - 1), {:x, 1}},
      # guard: both operands must be finite floats; a {:nonfinite,…} tuple → slow path
      {:test, :is_float, {:f, l_slow}, [{:x, 0}]},
      {:test, :is_float, {:f, l_slow}, [{:x, 1}]},
      # fast: test_op falls through on TRUE → 1, jumps to l_fail on FALSE → 0
      {:test, test_op, {:f, l_fail}, args},
      {:move, {:integer, 1}, {:x, 0}},
      {:jump, {:f, l_end}},
      {:label, l_fail},
      {:move, {:integer, 0}, {:x, 0}},
      {:jump, {:f, l_end}},
      {:label, l_slow},
      {:move, {:atom, op}, {:x, 2}},
      {:call_ext, 3, {:extfunc, @tinylasers, :guest_fcmp, 3}},
      {:label, l_end},
      {:move, {:x, 0}, yd(s, s.d - 2)}
    ]

    %{emit(s, ops) | d: s.d - 1} |> bump_labels(3)
  end

  # f32 single-precision rounding via Transpile.f32r/1 (clobbers x0, Live=1 transient input).
  defp f32round(false), do: []
  defp f32round(true), do: [{:call_ext, 1, {:extfunc, ext_mod(@transpile), :f32r, 1}}]

  # erlc/from_asm needs the fully-qualified `Elixir.`-prefixed atom for Elixir modules; plain Erlang
  # modules (:erlang/:math) are already correct atoms.
  defp ext_mod(m) when m in [:erlang, :math], do: m
  defp ext_mod(m) when is_atom(m) do
    s = Atom.to_string(m)
    if String.starts_with?(s, "Elixir."), do: m, else: :"Elixir.#{s}"
  end
end
