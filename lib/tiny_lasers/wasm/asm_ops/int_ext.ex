defmodule TinyLasers.Wasm.AsmOps.IntExt do
  @moduledoc """
  **Extended-integer op-group for the BEAM-assembly lane (`TinyLasers.Wasm.TranspileAsm`).** Lowers the i32
  ops the core i32 path doesn't cover — globals, `select`, shifts/rotates, div/rem, and bitcount — to BEAM
  assembly, **bit-identical to the interpreter (`TinyLasers.Wasm`) and the abstract-forms lane
  (`TinyLasers.Wasm.Transpile`)** by construction. i32 values are stored UNSIGNED in `0..2^32-1`.

  Frame model per `TinyLasers.Wasm.AsmCtx`: persistent values in y-registers, `x0`/`x1` scratch, operand at
  stack pos `yd(s, pos)`, TOP at `yd(s, s.d - 1)`. Returns `{:ok, s}` for ops it owns, `:unsupported`
  for everything else.

  Covered (all i32):
    * GLOBALS `global.get`/`global.set` — atomics over `:washy_globals` (slot = index + 1); `set` masks 32.
    * `select` (0x1B) — 3 operands; pops [c, b, a] from top, result = c≠0 ? a : b.
    * shifts/rotates — shl 0x74, shr_s 0x75, shr_u 0x76, rotl 0x77, rotr 0x78 (count masked by 31).
    * div/rem — div_s 0x6D, div_u 0x6E, rem_s 0x6F, rem_u 0x70 (trap on /0; div_s traps INT32_MIN/-1).
    * bitcount — clz 0x67, ctz 0x68, popcnt 0x69 (call_ext to the interpreter's public wclz/wctz/wpopcnt).

  div/rem and rotl/rotr trap/wrap exactly like the interpreter; the asm calls the module-local helpers
  below (`div_s/2`, …, `rotl/2`, `rotr/2`), which reuse `TinyLasers.Wasm.Trap` for div-by-zero / signed
  overflow — so the raised exception is identical to the interpreter's `trap!`.
  """
  import Bitwise
  import TinyLasers.Wasm.AsmCtx

  @transpile :"Elixir.TinyLasers.Wasm.Transpile"
  @washy :"Elixir.TinyLasers.Wasm"
  @mask32 0xFFFFFFFF

  # sign-extension (§0): opcode → TinyLasers.Wasm.guest_* mirror (i32/i64.extend8_s/16_s/32_s).
  @sign_ext %{
    0xC0 => :guest_i32_extend8_s, 0xC1 => :guest_i32_extend16_s,
    0xC2 => :guest_i64_extend8_s, 0xC3 => :guest_i64_extend16_s, 0xC4 => :guest_i64_extend32_s
  }

  # i32 shifts: opcode → handler tag.
  @shifts %{0x74 => :shl, 0x75 => :shr_s, 0x76 => :shr_u, 0x77 => :rotl, 0x78 => :rotr}
  # div/rem: opcode → module-local trapping helper.
  @divs %{0x6D => :div_s, 0x6E => :div_u, 0x6F => :rem_s, 0x70 => :rem_u}
  # bitcount: opcode → {public Transpile helper, arity} called via call_ext.
  @bits %{0x67 => :wclz, 0x68 => :wctz, 0x69 => :wpopcnt}

  @doc "Op-group entry: `handle(instr, s) -> {:ok, s} | :unsupported`."
  def handle({:global_get, i}, s), do: {:ok, global_get(i, s)}
  def handle({:global_set, i}, s), do: {:ok, global_set(i, s)}

  def handle({:op, opcode}, s) do
    cond do
      opcode == 0x1B -> {:ok, select(s)}
      Map.has_key?(@shifts, opcode) -> {:ok, shift(@shifts[opcode], s)}
      Map.has_key?(@divs, opcode) -> {:ok, divrem(@divs[opcode], s)}
      Map.has_key?(@bits, opcode) -> {:ok, bitcount(opcode, s)}
      Map.has_key?(@sign_ext, opcode) -> {:ok, sext_op(opcode, s)}
      true -> :unsupported
    end
  end

  def handle(_instr, _s), do: :unsupported

  # sign-extend (pop 1, push 1, in place) via a unary TinyLasers.Wasm.guest_* call_ext mirror of the interp.
  defp sext_op(opcode, s) do
    if s.d < 1, do: throw(:unsupported)
    top = s.d - 1

    ops = [
      {:move, yd(s, top), {:x, 0}},
      {:call_ext, 1, {:extfunc, @washy, @sign_ext[opcode], 1}},
      {:move, {:x, 0}, yd(s, top)}
    ]

    emit(s, ops)
  end

  # ── Live-aware primitives (the shared AsmCtx variants hardcode Live=2; here only x0 is live). ──
  defp band32(reg, live), do: {:gc_bif, :band, {:f, 0}, live, [reg, {:integer, @mask32}], reg}

  # branchless signed-32 of `reg` in place: ((reg + 2^31) band mask32) - 2^31
  defp s32(reg, live) do
    [
      {:gc_bif, :+, {:f, 0}, live, [reg, {:integer, 0x80000000}], reg},
      {:gc_bif, :band, {:f, 0}, live, [reg, {:integer, @mask32}], reg},
      {:gc_bif, :-, {:f, 0}, live, [reg, {:integer, 0x80000000}], reg}
    ]
  end

  # ── globals (atomics over :washy_globals, slot = index + 1) ──
  # x0 := atomics:get(erlang:get(washy_globals), i+1)
  defp global_get(i, s) do
    vt = elem(TinyLasers.Wasm.global_types(s.mod), i)

    read = [
      {:move, {:atom, :washy_globals}, {:x, 0}},
      {:call_ext, 1, {:extfunc, :erlang, :get, 1}},
      {:move, {:integer, i + 1}, {:x, 1}},
      {:call_ext, 2, {:extfunc, :atomics, :get, 2}}
    ]

    # x0 now holds the raw 64-bit storage bits. i32 (127) stores the value verbatim, so it IS the value;
    # f64/f32/i64 store an encoded bit pattern → decode via the interp's gval (bit-identical).
    decode =
      if vt == 127,
        do: [],
        else: [{:move, {:integer, vt}, {:x, 1}}, {:call_ext, 2, {:extfunc, :"Elixir.TinyLasers.Wasm", :gval, 2}}]

    push(emit(s, read ++ decode ++ [{:move, {:x, 0}, yd(s, s.d)}]))
  end

  # atomics:put(erlang:get(washy_globals), i+1, top band mask32)
  defp global_set(i, s) do
    if s.d < 1, do: throw(:unsupported)
    vt = elem(TinyLasers.Wasm.global_types(s.mod), i)

    # f64/f32/i64: encode value→storage bits via the interp's gbits. It's a CALL (clobbers x-regs), so do
    # it FIRST and stash the bits back into the value's y-slot, where they survive the erlang:get/1 below
    # (atomics can't hold a float, and a `band` mask on a float crashes — the original i32-only bug).
    pre =
      if vt == 127,
        do: [],
        else: [
          {:move, yd(s, s.d - 1), {:x, 0}},
          {:move, {:integer, vt}, {:x, 1}},
          {:call_ext, 2, {:extfunc, :"Elixir.TinyLasers.Wasm", :gbits, 2}},
          {:move, {:x, 0}, yd(s, s.d - 1)}
        ]

    # Compute the atomics:put/3 args x0=ref, x1=slot, x2=value in order, setting x2 LAST so the
    # intervening erlang:get/1 (Live=1) doesn't leave x2 declared dead at the call (validator: not_live).
    # i32 keeps the inline 32-bit mask (fast path); other valtypes already encoded their bits above.
    mask = if vt == 127, do: [band32({:x, 2}, 3)], else: []

    ops =
      pre ++
        [
          {:move, {:atom, :washy_globals}, {:x, 0}},
          {:call_ext, 1, {:extfunc, :erlang, :get, 1}},
          {:move, {:integer, i + 1}, {:x, 1}},
          {:move, yd(s, s.d - 1), {:x, 2}}
        ] ++ mask ++ [{:call_ext, 3, {:extfunc, :atomics, :put, 3}}]

    %{emit(s, ops) | d: s.d - 1}
  end

  # ── select (0x1B): pop [c, b, a] from top; result = c≠0 ? a : b. ──
  # Stack: a at d-3, b at d-2, c at d-1 (top). Branch on c; pick a or b into x0; store at d-3.
  defp select(s) do
    if s.d < 3, do: throw(:unsupported)
    lf = s.lbl
    le = s.lbl + 1

    # BEAM `test` jumps to the fail label when the comparison is FALSE. `is_eq_exact [c,0]` falls through
    # when c==0 (→ pick b) and jumps to lf when c≠0 (→ pick a). Result = c≠0 ? a : b, as the interpreter.
    ops = [
      {:move, yd(s, s.d - 1), {:x, 0}},
      {:test, :is_eq_exact, {:f, lf}, [{:x, 0}, {:integer, 0}]},
      {:move, yd(s, s.d - 2), {:x, 0}},
      {:jump, {:f, le}},
      {:label, lf},
      {:move, yd(s, s.d - 3), {:x, 0}},
      {:label, le},
      {:move, {:x, 0}, yd(s, s.d - 3)}
    ]

    %{emit(s, ops) | d: s.d - 2} |> bump_labels(2)
  end

  # ── shifts / rotates (count masked by 31) ──
  defp shift(tag, s) do
    if s.d < 2, do: throw(:unsupported)
    load = [{:move, yd(s, s.d - 2), {:x, 0}}, {:move, yd(s, s.d - 1), {:x, 1}}]
    store = [{:move, {:x, 0}, yd(s, s.d - 2)}]
    %{emit(s, load ++ shift_body(tag) ++ store) | d: s.d - 1}
  end

  # shl: (a bsl (b band 31)) band mask32
  defp shift_body(:shl) do
    [
      {:gc_bif, :band, {:f, 0}, 2, [{:x, 1}, {:integer, 31}], {:x, 1}},
      {:gc_bif, :bsl, {:f, 0}, 2, [{:x, 0}, {:x, 1}], {:x, 0}},
      band32({:x, 0}, 1)
    ]
  end

  # shr_u: a bsr (b band 31) — a unsigned in range, result already in range.
  defp shift_body(:shr_u) do
    [
      {:gc_bif, :band, {:f, 0}, 2, [{:x, 1}, {:integer, 31}], {:x, 1}},
      {:gc_bif, :bsr, {:f, 0}, 2, [{:x, 0}, {:x, 1}], {:x, 0}}
    ]
  end

  # shr_s: (s32(a) bsr (b band 31)) band mask32
  defp shift_body(:shr_s) do
    s32({:x, 0}, 2) ++
      [
        {:gc_bif, :band, {:f, 0}, 2, [{:x, 1}, {:integer, 31}], {:x, 1}},
        {:gc_bif, :bsr, {:f, 0}, 2, [{:x, 0}, {:x, 1}], {:x, 0}},
        band32({:x, 0}, 1)
      ]
  end

  # rotl/rotr via call_ext to the trapping/wrapping helpers (x0=a, x1=b, result→x0).
  defp shift_body(:rotl), do: [{:call_ext, 2, {:extfunc, __MODULE__, :rotl, 2}}]
  defp shift_body(:rotr), do: [{:call_ext, 2, {:extfunc, __MODULE__, :rotr, 2}}]

  # ── div / rem via call_ext to our trapping helpers (x0=a, x1=b, result→x0) ──
  defp divrem(fun, s) do
    if s.d < 2, do: throw(:unsupported)

    ops = [
      {:move, yd(s, s.d - 2), {:x, 0}},
      {:move, yd(s, s.d - 1), {:x, 1}},
      {:call_ext, 2, {:extfunc, __MODULE__, fun, 2}},
      {:move, {:x, 0}, yd(s, s.d - 2)}
    ]

    %{emit(s, ops) | d: s.d - 1}
  end

  # ── clz / ctz / popcnt via call_ext to the interpreter's public helpers ──
  defp bitcount(0x69, s), do: bitcall(:wpopcnt, [], s)
  defp bitcount(opcode, s), do: bitcall(@bits[opcode], [{:move, {:integer, 32}, {:x, 1}}], s)

  defp bitcall(fun, extra_arg, s) do
    if s.d < 1, do: throw(:unsupported)
    arity = 1 + length(extra_arg)

    ops =
      [{:move, yd(s, s.d - 1), {:x, 0}}] ++
        extra_arg ++
        [
          {:call_ext, arity, {:extfunc, @transpile, fun, arity}},
          {:move, {:x, 0}, yd(s, s.d - 1)}
        ]

    emit(s, ops)
  end

  # ── runtime helpers (called from the emitted asm) — mirror the interpreter EXACTLY ──
  @doc false
  def div_s(a, b), do: idiv(i32s(a), i32s(b)) &&& @mask32
  @doc false
  def div_u(_a, 0), do: TinyLasers.Wasm.Trap.trap!(:div_by_zero)
  def div_u(a, b), do: div(a, b) &&& @mask32
  @doc false
  def rem_s(a, b), do: irem(i32s(a), i32s(b)) &&& @mask32
  @doc false
  def rem_u(_a, 0), do: TinyLasers.Wasm.Trap.trap!(:div_by_zero)
  def rem_u(a, b), do: rem(a, b) &&& @mask32

  @doc false
  def rotl(a, b), do: rot32(a, b &&& 31, :l)
  @doc false
  def rotr(a, b), do: rot32(a, b &&& 31, :r)

  defp idiv(_a, 0), do: TinyLasers.Wasm.Trap.trap!(:div_by_zero)
  defp idiv(a, -1) when a == -0x80000000, do: TinyLasers.Wasm.Trap.trap!(:int_overflow)
  defp idiv(a, b), do: div(a, b)

  defp irem(_a, 0), do: TinyLasers.Wasm.Trap.trap!(:div_by_zero)
  defp irem(a, b), do: rem(a, b)

  defp i32s(x) when x >= 0x80000000, do: x - 0x100000000
  defp i32s(x), do: x

  defp rot32(a, 0, _dir), do: a
  defp rot32(a, n, :l), do: ((a <<< n) ||| (a >>> (32 - n))) &&& @mask32
  defp rot32(a, n, :r), do: ((a >>> n) ||| (a <<< (32 - n))) &&& @mask32
end
