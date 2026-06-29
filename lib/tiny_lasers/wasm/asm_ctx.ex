defmodule TinyLasers.Wasm.AsmCtx do
  @moduledoc """
  **Shared frame-model context for the BEAM-assembly lane (`TinyLasers.Wasm.TranspileAsm`).** Every op-group
  handler (`AsmOps.*`) builds against THIS contract so they compose into one module without reinventing
  the register/stack model. See `nexus/reference/beam/` for the ground-truth instruction set.

  ## The frame (y-register) model
  A function gets a stack frame (`allocate`/`deallocate`). ALL persistent values live in `y`-registers
  (which survive calls): locals in `y0..y(L-1)`, the wasm operand stack of depth `d` in `y(L)..y(L+d-1)`.
  `x0`/`x1` are TRANSIENT scratch — load an operand from `y` into `x`, run the op, store the result back
  to `y`. A `call` clobbers `x` but the frame (`y`) is preserved, so no spilling.

  ## State `s` (a plain map — every handler takes and returns it)
  - `acc`   — emitted instrs in REVERSE-chronological order (use `emit/2`; never prepend by hand)
  - `d`     — current operand-stack depth
  - `maxd`  — max depth seen (sizes the frame); maintained by `push/1`
  - `lbl`   — next free label number (function labels 1,2 are the entry; body labels start at 3)
  - `reachable` — false in dead code after an unconditional br/return
  - `ctrl`  — control-frame stack (head = innermost): `%{label:, entry:, loop?:}`
  - `used`  — MapSet of labels some `br` targets (tells a join whether it's reachable)
  - `l`     — number of locals L (== where the operand stack begins in `y`)
  - `mod`, `ni` — the decoded module + import count (for `func_type/3`, globals, etc.)

  ## Conventions
  - Operand at stack position `pos` (0-based) lives at `yd(s, pos)`. The TOP is `yd(s, s.d - 1)`.
  - To pop N and push 1: read `yd(s, s.d-N)..yd(s, s.d-1)`, write result to `yd(s, s.d-N)`, then set
    `d` to `s.d - N + 1` (use `push/1` after setting `d = s.d - N`).
  - `throw(:unsupported)` for any op/shape outside a handler's scope — the caller falls back to forms.
  - Anything that emits a `test`/`jump` allocates labels via the `s.lbl` counter; if you use the
    `branch01` 2-label pattern, the helper consumes `s.lbl` and `s.lbl+1` — you MUST `bump_labels(s, 2)`.
  - GC-relevant ops (`gc_bif`, `call_ext`, `test_heap`) need a correct `Live` (number of live x-regs).
    Since persistent values are in `y`, live x is just the transient inputs — `1` or `2` is right.
  """
  import Bitwise

  @mask32 0xFFFFFFFF
  @mask64 0xFFFFFFFFFFFFFFFF
  @sign32 0x80000000
  @sign64 0x8000000000000000
  @washy :"Elixir.TinyLasers.Wasm"

  def mask32, do: @mask32
  def mask64, do: @mask64
  def washy, do: @washy

  @doc "Append `ops` (chronological list) to the reverse-chronological accumulator."
  def emit(s, ops), do: %{s | acc: Enum.reverse(ops) ++ s.acc}

  @doc "Allocate a fresh label; returns `{label, s}`."
  def new_label(s), do: {s.lbl, %{s | lbl: s.lbl + 1}}

  @doc "Reserve `n` labels already consumed inline (e.g. by `branch01`)."
  def bump_labels(s, n), do: %{s | lbl: s.lbl + n}

  @doc "The y-register holding operand-stack position `pos` (0-based from the frame base)."
  def yd(s, pos), do: {:y, s.l + pos}

  @doc "Increment depth and track the max (sizes the frame). Call AFTER writing the new top slot."
  def push(s), do: %{s | d: s.d + 1, maxd: max(s.maxd, s.d + 1)}

  @doc "Resolved `{params, results}` (lists of wasm valtypes) for a global func index (import or local)."
  def func_type(mod, ni, fidx) do
    tidx = if fidx < ni, do: elem(Enum.at(mod.imports, fidx), 2), else: Enum.at(mod.funcs, fidx - ni)
    Enum.at(mod.types, tidx)
  end

  @doc """
  Branchless signed-N of register `r` IN PLACE: `s(r) = ((r + 2^(N-1)) band (2^N-1)) - 2^(N-1)`.
  `bits` is 32 or 64. Returns the gc_bif instruction list (Live=2, safe when x0/x1 both hold operands).
  """
  def signed_ops(r, 32), do: signed_ops(r, @sign32, @mask32)
  def signed_ops(r, 64), do: signed_ops(r, @sign64, @mask64)

  defp signed_ops(r, sign, mask) do
    [
      {:gc_bif, :+, {:f, 0}, 2, [r, {:integer, sign}], r},
      {:gc_bif, :band, {:f, 0}, 2, [r, {:integer, mask}], r},
      {:gc_bif, :-, {:f, 0}, 2, [r, {:integer, sign}], r}
    ]
  end

  @doc """
  Value-producing comparison pattern: `dst := 1` if the `test` falls through, else `0`. Consumes
  `s.lbl` and `s.lbl+1` — the CALLER must `bump_labels(s, 2)` after emitting. Returns the instr list.
  """
  def branch01(test_op, args, dst, s) do
    lf = s.lbl
    le = s.lbl + 1

    [
      {:test, test_op, {:f, lf}, args},
      {:move, {:integer, 1}, dst},
      {:jump, {:f, le}},
      {:label, lf},
      {:move, {:integer, 0}, dst},
      {:label, le}
    ]
  end

  @doc "Mask a register to N bits in place (32 or 64). Returns the instr list."
  def mask_ops(r, 32), do: [{:gc_bif, :band, {:f, 0}, 2, [r, {:integer, @mask32}], r}]
  def mask_ops(r, 64), do: [{:gc_bif, :band, {:f, 0}, 2, [r, {:integer, @mask64}], r}]
end
