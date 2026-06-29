defmodule TinyLasers.Wasm.AsmOps.Atomics do
  @moduledoc """
  **BEAM-assembly lowering of the wasm ATOMICS ops (WASIX §0).** An `AsmOps.*` op-group handler for
  `TinyLasers.Wasm.TranspileAsm`. Like the Memory handler, each op lowers to a single `call_ext` into a
  `TinyLasers.Wasm` host helper that holds the EXACT interpreter byte-math (`guest_load`/`guest_store` for
  atomic load/store, `guest_atomic_rmw`/`guest_atomic_cmpxchg` for read-modify-write) — DRY, oracle-
  guarded bit-identical to the interpreter. On the single-threaded asm lane atomic loads/stores ARE the
  width-correct memory ops (loads zero-extend); `fence` is a no-op.

  Handled: `:atomic_load` · `:atomic_store` · `:atomic_rmw` (add/sub/and/or/xor/xchg + cmpxchg) ·
  `:atomic_fence` · `:atomic_wait` · `:atomic_notify`. The futex wait/notify (§2) lower to `call_ext`
  into `TinyLasers.Wasm.guest_atomic_wait`/`guest_atomic_notify` — the SAME impl the interpreter calls.
  """
  import TinyLasers.Wasm.AsmCtx

  @tinylasers tinylasers()
  @rmw_code %{add: 0, sub: 1, and: 2, or: 3, xor: 4, xchg: 5}

  @doc "Lower one atomic instr. `{:ok, s}` if handled, `:unsupported` otherwise."
  def handle(instr, s)

  # atomic load: pop addr, push value (net 0). Always zero-extends (guest_load).
  def handle({:atomic_load, offset, n}, s) do
    if s.d < 1, do: throw(:unsupported)
    top = s.d - 1

    ops =
      addr_into_x0(s, top, offset) ++
        [
          {:move, {:integer, n}, {:x, 1}},
          {:call_ext, 2, {:extfunc, @tinylasers, :guest_load, 2}},
          {:move, {:x, 0}, yd(s, top)}
        ]

    {:ok, emit(s, ops)}
  end

  # atomic store: pop [addr, val] (val on top), push nothing (net -2).
  def handle({:atomic_store, offset, n}, s) do
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

    {:ok, %{emit(s, ops) | d: s.d - 2}}
  end

  # atomic.fence: no-op.
  def handle({:atomic_fence}, s), do: {:ok, s}

  # cmpxchg: pop [addr, expected, repl] (repl on top), push old (net -2).
  def handle({:atomic_rmw, :cmpxchg, offset, n}, s) do
    if s.d < 3, do: throw(:unsupported)
    addr_pos = s.d - 3
    exp_pos = s.d - 2
    repl_pos = s.d - 1

    ops =
      addr_into_x0(s, addr_pos, offset) ++
        [
          {:move, yd(s, exp_pos), {:x, 1}},
          {:move, yd(s, repl_pos), {:x, 2}},
          {:move, {:integer, n}, {:x, 3}},
          {:call_ext, 4, {:extfunc, @tinylasers, :guest_atomic_cmpxchg, 4}},
          {:move, {:x, 0}, yd(s, addr_pos)}
        ]

    {:ok, %{emit(s, ops) | d: s.d - 2}}
  end

  # rmw add/sub/and/or/xor/xchg: pop [addr, val] (val on top), push old (net -1).
  def handle({:atomic_rmw, opname, offset, n}, s) when is_map_key(@rmw_code, opname) do
    if s.d < 2, do: throw(:unsupported)
    addr_pos = s.d - 2
    val_pos = s.d - 1

    ops =
      addr_into_x0(s, addr_pos, offset) ++
        [
          {:move, yd(s, val_pos), {:x, 1}},
          {:move, {:integer, n}, {:x, 2}},
          {:move, {:integer, @rmw_code[opname]}, {:x, 3}},
          {:call_ext, 4, {:extfunc, @tinylasers, :guest_atomic_rmw, 4}},
          {:move, {:x, 0}, yd(s, addr_pos)}
        ]

    {:ok, %{emit(s, ops) | d: s.d - 1}}
  end

  # atomic.wait(addr, expected, timeout) -> i32 (0 woken / 1 not-equal / 2 timed-out). pop 3, push 1
  # (net -2). ONE futex impl lives in TinyLasers.Wasm.guest_atomic_wait — DRY with the interpreter.
  def handle({:atomic_wait, n, offset}, s) do
    if s.d < 3, do: throw(:unsupported)
    addr_pos = s.d - 3
    exp_pos = s.d - 2
    timeout_pos = s.d - 1

    ops =
      addr_into_x0(s, addr_pos, offset) ++
        [
          {:move, yd(s, exp_pos), {:x, 1}},
          {:move, {:integer, n}, {:x, 2}},
          {:move, yd(s, timeout_pos), {:x, 3}},
          {:call_ext, 4, {:extfunc, @tinylasers, :guest_atomic_wait, 4}},
          {:move, {:x, 0}, yd(s, addr_pos)}
        ]

    {:ok, %{emit(s, ops) | d: s.d - 2}}
  end

  # atomic.notify(addr, count) -> i32 woken. pop 2, push 1 (net -1). guest_atomic_notify, shared impl.
  def handle({:atomic_notify, offset}, s) do
    if s.d < 2, do: throw(:unsupported)
    addr_pos = s.d - 2
    count_pos = s.d - 1

    ops =
      addr_into_x0(s, addr_pos, offset) ++
        [
          {:move, yd(s, count_pos), {:x, 1}},
          {:call_ext, 2, {:extfunc, @tinylasers, :guest_atomic_notify, 2}},
          {:move, {:x, 0}, yd(s, addr_pos)}
        ]

    {:ok, %{emit(s, ops) | d: s.d - 1}}
  end

  def handle(_instr, _s), do: :unsupported

  # eff_addr = addr + static offset into x0 (no masking — flows into the helper's bounds-check; an
  # out-of-range result traps :out_of_bounds, byte-identical to the interpreter / Memory handler).
  defp addr_into_x0(s, pos, 0), do: [{:move, yd(s, pos), {:x, 0}}]

  defp addr_into_x0(s, pos, offset) do
    [
      {:move, yd(s, pos), {:x, 0}},
      {:gc_bif, :+, {:f, 0}, 1, [{:x, 0}, {:integer, offset}], {:x, 0}}
    ]
  end
end
