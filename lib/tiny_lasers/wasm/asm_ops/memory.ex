defmodule TinyLasers.Wasm.AsmOps.Memory do
  @moduledoc """
  **BEAM-assembly lowering of wasm linear-MEMORY ops (epic wb-wzdq).** An `AsmOps.*` op-group handler
  for `TinyLasers.Wasm.TranspileAsm`: lowers integer loads/stores of every width plus the bulk-memory and
  memory.size/grow ops to BEAM *assembly*, **bit-identical to the interpreter / the abstract-forms lane**.

  ## Design — call into the host seams, don't re-derive the byte math in asm
  The forms lane (`TinyLasers.Wasm.Transpile`) and the interpreter share ONE memory model: a packed
  `:atomics` (`:tl_mem` in the process dict), little-endian byte layout, a bounds-check that traps
  `:out_of_bounds` against `pages*65536`. Rather than hand-emit that read-modify-write + fast-path +
  bounds-case as raw asm tuples (fragile, easy to drift from the oracle), each op lowers to a single
  `call_ext` to a small `TinyLasers.Wasm` host helper that already implements the EXACT interpreter
  semantics (`guest_load/2`, `guest_load_s/2`, `guest_store/3`, `guest_memory_size/0`,
  `guest_memory_grow/1`, `guest_memory_copy/3`, `guest_memory_fill/3`). DRY: one home for the byte math,
  the oracle guards equality. Traps propagate as the same `TinyLasers.Wasm.Trap` exception the other lanes
  raise (the helper raises it), so the differential fuzzer sees identical faults.

  ## Frame model (see `TinyLasers.Wasm.AsmCtx`)
  Operands live in y-registers; x0/x1/x2 are transient. For a `call_ext` we load operands from `y` into
  `x0..` (args in call order), call the helper, then store the x0 result back into the right `y` slot.
  The frame is pre-allocated and call-safe, so no spilling.

  ## Ops handled
  loads:  `:i32_load` (4) · `:i32_load8u`/`:i32_load8s` (1) · `:i32_load16u`/`:i32_load16s` (2) · `:f32_load` (4) · `:f64_load` (8)
  stores: `:i32_store` (4) · `:i32_store8` (1) · `:i32_store16` (2) · `:f32_store` (4) · `:f64_store` (8)
  bulk/size: `:memory_size` · `:memory_grow` · `:memory_copy` · `:memory_fill` · `:data_drop`

  i64 loads/stores (uniform `{:i64_load, off, n, signed?}` / `{:i64_store, off, n}`) are handled below.
  """
  import TinyLasers.Wasm.AsmCtx

  @tinylasers tinylasers()

  # width (bytes) and signedness per load opcode
  @loads %{
    i32_load: {4, :u},
    i32_load8u: {1, :u},
    i32_load8s: {1, :s},
    i32_load16u: {2, :u},
    i32_load16s: {2, :s}
  }

  @stores %{i32_store: 4, i32_store8: 1, i32_store16: 2}

  @doc "Lower one memory instr. `{:ok, s}` if handled, `:unsupported` otherwise."
  def handle(instr, s)

  # ── integer loads ── pop addr, push value. eff_addr = addr + static offset.
  def handle({op, offset}, s) when is_map_key(@loads, op) do
    if s.d < 1, do: throw(:unsupported)
    {n, signw} = @loads[op]
    top = s.d - 1
    fun = if signw == :s, do: :guest_load_s, else: :guest_load

    # x0 = addr + offset ; x1 = n ; call guest_load*/2 -> x0 ; store x0 to top slot
    ops =
      addr_into_x0(s, top, offset) ++
        [
          {:move, {:integer, n}, {:x, 1}},
          {:call_ext, 2, {:extfunc, @tinylasers, fun, 2}},
          {:move, {:x, 0}, yd(s, top)}
        ]

    {:ok, emit(s, ops)}
  end

  # ── integer stores ── pop [addr, val] (val on top), push nothing. Stack order: addr below, val above.
  def handle({op, offset}, s) when is_map_key(@stores, op) do
    if s.d < 2, do: throw(:unsupported)
    n = @stores[op]
    addr_pos = s.d - 2
    val_pos = s.d - 1

    # x0 = addr + offset ; x1 = val ; x2 = n ; call guest_store/3
    ops =
      addr_into_x0(s, addr_pos, offset) ++
        [
          {:move, yd(s, val_pos), {:x, 1}},
          {:move, {:integer, n}, {:x, 2}},
          {:call_ext, 3, {:extfunc, @tinylasers, :guest_store, 3}}
        ]

    # store pops BOTH addr and val (2 operands, pushes nothing) — `d - 2`, NOT `d - 1`. The interpreter
    # (`step({:i32_store,…}, [v, a | s])`) pops two; an off-by-one here desyncs every later operand slot
    # (the wb-95w7 §8 divergence: dlmalloc returned a garbage pointer in asm only).
    {:ok, %{emit(s, ops) | d: s.d - 2}}
  end

  # ── i64 loads ── uniform tuple {:i64_load, offset, width, signed?}, width ∈ 1/2/4/8. pop addr, push i64.
  def handle({:i64_load, offset, n, signed}, s) do
    if s.d < 1, do: throw(:unsupported)
    top = s.d - 1
    fun = if signed, do: :guest_load_s64, else: :guest_load

    ops =
      addr_into_x0(s, top, offset) ++
        [
          {:move, {:integer, n}, {:x, 1}},
          {:call_ext, 2, {:extfunc, @tinylasers, fun, 2}},
          {:move, {:x, 0}, yd(s, top)}
        ]

    {:ok, emit(s, ops)}
  end

  # ── i64 stores ── {:i64_store, offset, width}; store the low `n` bytes of val. Stack: addr below, val above.
  def handle({:i64_store, offset, n}, s) do
    if s.d < 2, do: throw(:unsupported)
    addr_pos = s.d - 2
    val_pos = s.d - 1

    ops =
      addr_into_x0(s, addr_pos, offset) ++
        [
          {:move, yd(s, val_pos), {:x, 1}},
          {:move, {:integer, n}, {:x, 2}},
          {:call_ext, 3, {:extfunc, @tinylasers, :guest_store, 3}}
        ]

    # i64 store also pops BOTH addr and val — `d - 2` (same wb-95w7 fix as the i32 store above).
    {:ok, %{emit(s, ops) | d: s.d - 2}}
  end

  # ── f32/f64 loads ── pop addr, push the decoded float (or {:nonfinite,bits,size}). n ∈ 4|8. Bit-identical
  # to the interpreter's `gfload` (host `guest_fload/2` = `fload` → `decode_f`).
  def handle({op, offset}, s) when op in [:f32_load, :f64_load] do
    if s.d < 1, do: throw(:unsupported)
    n = if op == :f32_load, do: 4, else: 8
    top = s.d - 1

    ops =
      addr_into_x0(s, top, offset) ++
        [
          {:move, {:integer, n}, {:x, 1}},
          {:call_ext, 2, {:extfunc, @tinylasers, :guest_fload, 2}},
          {:move, {:x, 0}, yd(s, top)}
        ]

    {:ok, emit(s, ops)}
  end

  # ── f32/f64 stores ── pop [addr, val] (val on top), push nothing. n ∈ 4|8. Bit-identical to `gfstore`.
  def handle({op, offset}, s) when op in [:f32_store, :f64_store] do
    if s.d < 2, do: throw(:unsupported)
    n = if op == :f32_store, do: 4, else: 8
    addr_pos = s.d - 2
    val_pos = s.d - 1

    ops =
      addr_into_x0(s, addr_pos, offset) ++
        [
          {:move, yd(s, val_pos), {:x, 1}},
          {:move, {:integer, n}, {:x, 2}},
          {:call_ext, 3, {:extfunc, @tinylasers, :guest_fstore, 3}}
        ]

    {:ok, %{emit(s, ops) | d: s.d - 2}}
  end

  # ── memory.size ── push the current page count (no operands consumed).
  def handle({:memory_size}, s) do
    ops = [{:call_ext, 0, {:extfunc, @tinylasers, :guest_memory_size, 0}}, {:move, {:x, 0}, yd(s, s.d)}]
    {:ok, push(emit(s, ops))}
  end

  # ── memory.grow(n) ── pop n, push old-page-count-or-(-1).
  def handle({:memory_grow}, s) do
    if s.d < 1, do: throw(:unsupported)
    top = s.d - 1

    ops = [
      {:move, yd(s, top), {:x, 0}},
      {:call_ext, 1, {:extfunc, @tinylasers, :guest_memory_grow, 1}},
      {:move, {:x, 0}, yd(s, top)}
    ]

    {:ok, emit(s, ops)}
  end

  # ── memory.copy ── pop [dst, src, n] (n on top, then src, then dst). VOID. Helper arity is (dst,src,n).
  def handle({:memory_copy}, s) do
    if s.d < 3, do: throw(:unsupported)
    dst = s.d - 3
    src = s.d - 2
    n = s.d - 1

    ops = [
      {:move, yd(s, dst), {:x, 0}},
      {:move, yd(s, src), {:x, 1}},
      {:move, yd(s, n), {:x, 2}},
      {:call_ext, 3, {:extfunc, @tinylasers, :guest_memory_copy, 3}}
    ]

    {:ok, %{emit(s, ops) | d: s.d - 3}}
  end

  # ── memory.fill ── pop [dst, val, n] (n on top, then val, then dst). VOID. Helper arity is (dst,val,n).
  def handle({:memory_fill}, s) do
    if s.d < 3, do: throw(:unsupported)
    dst = s.d - 3
    val = s.d - 2
    n = s.d - 1

    ops = [
      {:move, yd(s, dst), {:x, 0}},
      {:move, yd(s, val), {:x, 1}},
      {:move, yd(s, n), {:x, 2}},
      {:call_ext, 3, {:extfunc, @tinylasers, :guest_memory_fill, 3}}
    ]

    {:ok, %{emit(s, ops) | d: s.d - 3}}
  end

  # ── memory.init ── pop [dst, src, n] (n on top). Copy n bytes from data segment `dataidx` (immutable in
  # mod.data, resolved HERE at compile time → passed as a literal binary) into memory at dst. VOID.
  def handle({:memory_init, dataidx}, s) do
    if s.d < 3, do: throw(:unsupported)

    bytes =
      case Enum.at(s.mod.data, dataidx) do
        {:passive, b} -> b
        {:active, _o, b} -> b
        _ -> <<>>
      end

    dst = s.d - 3
    src = s.d - 2
    n = s.d - 1

    ops = [
      {:move, {:literal, bytes}, {:x, 0}},
      {:move, yd(s, dst), {:x, 1}},
      {:move, yd(s, src), {:x, 2}},
      {:move, yd(s, n), {:x, 3}},
      {:call_ext, 4, {:extfunc, @tinylasers, :guest_memory_init, 4}}
    ]

    {:ok, %{emit(s, ops) | d: s.d - 3}}
  end

  # ── data.drop ── active-segment model has nothing to free → no-op (matches interp/forms).
  def handle({:data_drop}, s), do: {:ok, s}

  # everything else (i64/float loads-stores, anything not ours) — clean fallback.
  def handle(_instr, _s), do: :unsupported

  # Compute the effective byte address (operand at `pos` + static `offset`) into x0. The interpreter
  # never masks here — `addr + offset` flows straight into the bounds-check, and an out-of-range result
  # traps :out_of_bounds — so we add without masking to stay byte-identical (offset==0 is just a move).
  defp addr_into_x0(s, pos, 0), do: [{:move, yd(s, pos), {:x, 0}}]

  defp addr_into_x0(s, pos, offset) do
    [
      {:move, yd(s, pos), {:x, 0}},
      {:gc_bif, :+, {:f, 0}, 1, [{:x, 0}, {:integer, offset}], {:x, 0}}
    ]
  end
end
