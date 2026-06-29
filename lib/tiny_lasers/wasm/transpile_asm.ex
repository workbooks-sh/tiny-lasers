defmodule TinyLasers.Wasm.TranspileAsm do
  @moduledoc """
  **The BEAM-assembly emission lane (epic wb-wzdq).** Lowers a wasm function straight to BEAM *assembly*
  (`{function,...}` opcode tuples) and compiles it with `:compile.forms(asm, [:from_asm])` — skipping the
  Erlang frontend AND the superlinear `beam_ssa_opt` pass *by construction*, then letting BeamAsm JIT the
  result to native. wasm opcodes ↔ BEAM asm opcodes is a near-1:1 transliteration; the compile is ~linear.
  See `nexus/reference/beam/` for the ground-truth instruction set + the validated API.

  **Register model — FRAME-based (the call-safe model).** A function gets a stack frame (`allocate`/
  `deallocate`); ALL persistent values live in `y`-registers (which survive calls): locals in `y0..y(L-1)`
  (params moved in from `x0..`; declared locals zero-init'd), and the wasm operand stack of depth `d` in
  `y(L)..y(L+d-1)`. `x0`/`x1` are transient scratch — values are loaded from `y`, the op runs, the result
  is stored back to `y`. This is what makes calls/fuel/memory work: a `call` clobbers `x` but the frame
  (`y`) is preserved, so no spilling dance is needed.

  **Supported ops:** i32 const, `local.get/set/tee`, `drop`, `nop`; i32 arith/bitwise (add/sub/mul/and/
  or/xor); all i32 compares (signed via branchless s32) + `eqz`; structured VOID control flow (block/loop/
  if + br/br_if via real labels/jumps) with **fuel charged per loop iteration** (traps `:out_of_fuel` like
  the interpreter). Out-of-scope (calls/memory/i64/floats/value-producing blocks/early-return) → returns
  `:unsupported`, caller falls back to the abstract-forms lane. The contract: bit-identical to interp.
  """
  import Bitwise
  import TinyLasers.Wasm.AsmCtx

  @mask32 0xFFFFFFFF
  @tinylasers :"Elixir.TinyLasers.Wasm"

  # Pluggable op-group handlers (the parallel-built AsmOps.* modules). Each exposes `handle(instr, s) ->
  # {:ok, s} | :unsupported`. step/2 tries them in order for any op the built-in i32 core doesn't cover.
  @op_handlers [TinyLasers.Wasm.AsmOps.Memory, TinyLasers.Wasm.AsmOps.I64, TinyLasers.Wasm.AsmOps.Floats, TinyLasers.Wasm.AsmOps.IntExt, TinyLasers.Wasm.AsmOps.Tables, TinyLasers.Wasm.AsmOps.Atomics, TinyLasers.Wasm.AsmOps.Exceptions]

  # wasm i32 opcode → {beam_gc_bif, needs_32bit_mask?}. add/sub/mul wrap mod 2^32 (mask); and/or/xor stay
  # in range. band of a negative (sub underflow) two's-complements to the correct unsigned wrap.
  @binops %{
    0x6A => {:+, true},
    0x6B => {:-, true},
    0x6C => {:*, true},
    0x71 => {:band, false},
    0x72 => {:bor, false},
    0x73 => {:bxor, false}
  }

  # wasm i32 comparison opcode → {operand-domain, beam-test, swap-args?}. `:u` compares unsigned stored
  # values directly; `:s` converts both to signed-32 first (branchless); `:eq`/`:ne` exact equality.
  @compares %{
    0x46 => {:eq, :is_eq_exact, false},
    0x47 => {:ne, :is_ne_exact, false},
    0x48 => {:s, :is_lt, false},
    0x49 => {:u, :is_lt, false},
    0x4A => {:s, :is_lt, true},
    0x4B => {:u, :is_lt, true},
    0x4C => {:s, :is_ge, true},
    0x4D => {:u, :is_ge, true},
    0x4E => {:s, :is_ge, false},
    0x4F => {:u, :is_ge, false}
  }

  @doc """
  Try to compile global-function-index `gfidx` via the BEAM-assembly lane. Returns `{:ok, {mod, fun,
  arity}}` (a loaded native MFA), `:unsupported` (op/shape outside scope — fall back), or `:error`.
  """
  def try_emit(mod, gfidx) do
    case compile_module(mod, [gfidx]) do
      {:ok, _mname, map, [], _tok} -> {:ok, Map.fetch!(map, gfidx)}
      {:ok, _mname, _map, [^gfidx], _tok} -> :unsupported
      :none -> :unsupported
      _ -> :error
    end
  end

  @doc """
  **Compile a SET of functions into ONE shared BEAM module (wb-65ak — the atom-table wall fix).** Minting
  a unique module-name atom *per function* exhausts the (never-GC'd) atom table at scale; batching a whole
  guest module's functions into one BEAM module collapses atom growth from O(functions) to O(guest modules).
  Each function gets a disjoint label range. Returns `{:ok, module_atom, %{gfidx => {module, fun, arity}},
  unsupported_gfidxs, pool_token}` (the loaded native MFAs for the lowerable functions, plus the pool
  generation token to pin in the cache for recycle-detection), `:none` (none lowerable), or `:error`.
  """
  def compile_module(mod, gfidxs) do
    # Draw the module name from the FIXED recycled atom pool (atom-table wall fix). `:exhausted` means
    # every pool slot currently carries a live, in-execution module — fall back to interpreting this chunk
    # (the caller treats `:none` as "nothing lowered"), never minting an unbounded fresh atom.
    case TinyLasers.Wasm.ModulePool.acquire() do
      {:ok, mname, tok} -> compile_module(mod, gfidxs, mname, tok)
      :exhausted -> :none
    end
  end

  defp compile_module(mod, gfidxs, mname, tok) do

    {funcs, exports, map, leftover, total} =
      Enum.reduce(gfidxs, {[], [], %{}, [], 0}, fn gfidx, {fs, exs, m, lo, off} ->
        case gen_function(mod, gfidx, mname) do
          {:ok, func, fname, arity, nlabels} ->
            # each function is generated standalone (labels 1..nlabels); shift its whole label range by
            # the labels already consumed so every function in the module is disjoint. Robust vs the
            # per-handler label threading (which is easy to get wrong → undefined_label).
            {[shift_func(func, off) | fs], [{fname, arity} | exs], Map.put(m, gfidx, {mname, fname, arity}), lo, off + nlabels}

          :unsupported ->
            {fs, exs, m, [gfidx | lo], off}
        end
      end)

    if funcs == [] do
      :none
    else
      asm = {mname, exports, [], Enum.reverse(funcs), total + 1}
      load_module(mname, asm, map, Enum.reverse(leftover), tok)
    end
  end

  # lower function `gfidx` standalone: labels 1 (func_info), 2 (entry), 3.. (body). Returns the function
  # tuple and the count of labels it uses (so the module assembler can shift it into a disjoint range).
  defp gen_function(mod, gfidx, mname) do
    ni = length(mod.imports)
    li = gfidx - ni
    {nlocals, instrs} = Enum.at(mod.code, li)
    {params, results} = Enum.at(mod.types, Enum.at(mod.funcs, li))
    arity = length(params)

    if supported_sig?(params, results) do
      l = arity + nlocals
      {body, next} = emit_body(instrs, l, arity, mod, ni, results)
      fname = :"wf_#{gfidx}"
      func =
        {:function, fname, arity, 2,
         [{:label, 1}, {:func_info, {:atom, mname}, {:atom, fname}, arity}, {:label, 2} | body]}

      # labels used = 1..(next-1) ⇒ (next-1) distinct labels.
      {:ok, func, fname, arity, next - 1}
    else
      :unsupported
    end
  catch
    :unsupported -> :unsupported
  end

  # Shift every label in a function tuple by `delta` (labels only appear as `{:label, N}` definitions and
  # `{:f, N}` references; `{:f, 0}` is "no fail label" and must NOT move; the entry is a bare integer).
  defp shift_func({:function, name, arity, entry, body}, delta),
    do: {:function, name, arity, entry + delta, Enum.map(body, &shift(&1, delta))}

  defp shift({:label, n}, d), do: {:label, n + d}
  defp shift({:f, 0}, _d), do: {:f, 0}
  defp shift({:f, n}, d), do: {:f, n + d}
  defp shift(t, d) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.map(&shift(&1, d)) |> List.to_tuple()
  defp shift(l, d) when is_list(l), do: Enum.map(l, &shift(&1, d))
  defp shift(x, _d), do: x

  # `:no_jopt` disables the `beam_jump` pass. We emit loop headers whose ONLY reference is the
  # back-edge `{jump,{f,Lstart}}` *below* the header (a natural wasm `loop` + `br 0` continue). When
  # such a loop sits in the fall-through path after an unconditional terminal (an early `return`, a
  # `br`, or an `unreachable` trap), `beam_jump`'s forward unreachable-code scan reaches the header
  # while it is still "unused" (its back-reference hasn't been seen yet), DELETES the header, yet keeps
  # the loop body + the surviving back-edge — leaving a dangling `{f,Lstart}` that `beam_clean` then
  # rejects with `{undefined_label,_}`. The labels we emit are already minimal and disjoint, so the
  # jump-optimisation pass buys us nothing here while being the sole source of this crash — turning it
  # off makes every such loop shape compile, with identical run-time semantics (BeamAsm still JITs the
  # result). See wb-bv4e for the full root-cause trace.
  @compile_opts [:from_asm, :binary, :return_errors, :no_jopt]
  @doc false
  # The `:compile.forms/2` options the asm lane uses (exposed for the wb-bv4e regression test, which
  # asserts a back-edge-loop shape that crashes `beam_jump` compiles cleanly under these opts).
  def compile_opts, do: @compile_opts
  # Output-side x-ray (gated by `Process.put(:tl_asm_dump, true)`): the counterpart to `wasm-tools print`
  # on the input. Captures, per loaded module, BOTH what we EMITTED (the `:from_asm` BEAM-assembly forms) and
  # what actually LOADED (`:beam_disasm.disasm/1` of the compiled `.beam` binary — these dynamically-loaded
  # pool modules don't retain object code, so `erts_debug:df`/`:code.get_object_code` can't reach them; the
  # binary at compile time is the only handle). Accumulates into `:tl_asm_dumps` for the caller to inspect
  # — so we can confirm our generated BEAM instructions are what we intended, and diff them against what the
  # OTP compiler emits for equivalent Elixir.
  defp maybe_dump_asm(mname, asm, bin) do
    if Process.get(:tl_asm_dump) do
      disasm =
        try do
          {:beam_file, _m, _exp, _attr, _ci, code} = :beam_disasm.file(bin)
          code
        rescue
          _ -> :disasm_failed
        catch
          _, _ -> :disasm_failed
        end

      {_name, _exports, _attrs, funcs, _lc} = asm
      Process.put(:tl_asm_dumps, [{mname, funcs, disasm} | Process.get(:tl_asm_dumps, [])])
    end
  end

  defp load_module(mname, asm, map, leftover, tok) do
    case :compile.forms(asm, @compile_opts) do
      {:ok, ^mname, bin} ->
        {:module, ^mname} = :code.load_binary(mname, ~c"nofile", bin)
        maybe_dump_asm(mname, asm, bin)
        {:ok, mname, map, leftover, tok}

      {:ok, ^mname, bin, _warns} ->
        {:module, ^mname} = :code.load_binary(mname, ~c"nofile", bin)
        maybe_dump_asm(mname, asm, bin)
        {:ok, mname, map, leftover, tok}

      other ->
        if System.get_env("WB_ASM_DEBUG"), do: IO.inspect({other, asm}, label: "asm-fail", limit: :infinity)
        :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # Accept any params over the scalar valtypes (i32=127, i64=126, f32=125, f64=124) and at most one
  # result. Values arrive/leave as Erlang terms (masked ints / floats) — the body op-handlers enforce the
  # actual op coverage, and bail :unsupported on anything they can't lower, so a permissive sig gate just
  # lets more functions be ATTEMPTED (the i32-only gate was the biggest coverage limiter). Multi-result
  # wasm returns (a tuple) are still out of scope.
  @valtypes [124, 125, 126, 127]
  # Allow MULTI-result functions: a multi-value return becomes a TOP-FIRST list (== interp `Enum.take`),
  # which the asm/interp `push_results/3` boundary consumes. Cap the result count at @max_block_results.
  defp supported_sig?(params, results) do
    length(results) <= @max_block_results and Enum.all?(params, &(&1 in @valtypes)) and
      Enum.all?(results, &(&1 in @valtypes))
  end

  # State `s`: acc (reverse-chronological instrs), d (operand depth), maxd (max depth, sizes the frame),
  # lbl (next free label), reachable, ctrl (control-frame stack), used (labels some br targets), l (#locals).
  # Body labels start at 3 (func_info=1, entry=2). Returns {body, next_free_label}; the module assembler
  # shifts the whole function's label range to keep functions disjoint.
  defp emit_body(instrs, l, arity, mod, ni, results) do
    s0 = %{acc: [], d: 0, maxd: 0, lbl: 3, reachable: true, ctrl: [], used: %{}, l: l, mod: mod, ni: ni,
           trydepth: 0, maxtry: 0, tryctx: [], nres: length(results)}
    s = lower_seq(instrs, s0)

    want = length(results)
    # The body may end REACHABLE (falls through with exactly `want` results on the stack — then we emit a
    # return tail) OR UNREACHABLE (every path already ended in a return/trap — no fall-through tail needed,
    # those emitted terminals are complete). Only reject a reachable body with the wrong stack height.
    if s.reachable and s.d != want, do: throw(:unsupported)
    # try_table slots sit ABOVE all operand slots: `maxtry` of them (each try-nesting level reserves a
    # block; see {:try_table,…}). The base is fixed; {:y, {:tryslot, t}} placeholders patch to base + t.
    opbase = l + max(s.maxd, 1)
    frame = opbase + s.maxtry
    # Prologue: allocate the frame, move params x→y, then zero-init EVERY remaining y-slot (declared
    # locals + operand-stack scratch). A call (charge_fuel/call_local) may GC and scans the whole frame,
    # so all y-slots must be initialized before the first call — even scratch slots written later.
    param_moves = for i <- 0..(arity - 1)//1, arity > 0, do: {:move, {:x, i}, {:y, i}}
    # The try-CONTEXT slots are initialized by the `try` op itself (as a try-tag) — pre-zeroing them with
    # an integer breaks the validator's tag tracking. Skip them; every other y-slot is zeroed up front.
    tryctx_abs = MapSet.new(s.tryctx, &(opbase + &1))
    zero = for i <- arity..(frame - 1)//1, i >= arity, not MapSet.member?(tryctx_abs, i), do: {:move, {:integer, 0}, {:y, i}}
    prologue = [{:allocate, frame, arity}] ++ param_moves ++ zero

    tail =
      cond do
        not s.reachable -> []
        want == 1 -> [{:move, {:y, l}, {:x, 0}}, {:deallocate, frame}, :return]
        want > 1 -> build_result_list(l, s.d, want) ++ [{:deallocate, frame}, :return]
        true -> [{:move, {:integer, 0}, {:x, 0}}, {:deallocate, frame}, :return]
      end

    body = prologue ++ Enum.reverse(s.acc) ++ tail
    {patch_dealloc(body, frame, opbase), s.lbl}
  end

  # Rewrite the two placeholders left by lowering: every {:deallocate, :ph} → the real frame size, and every
  # {:y, {:tryslot, t}} try-context slot ref → its absolute y-reg `opbase + t` (above all operand slots).
  defp patch_dealloc(body, frame, opbase) do
    Enum.map(body, fn instr -> patch_instr(instr, frame, opbase) end)
  end

  defp patch_instr({:deallocate, :ph}, frame, _opbase), do: {:deallocate, frame}
  defp patch_instr({:y, {:tryslot, t}}, _frame, opbase), do: {:y, opbase + t}
  defp patch_instr(tuple, frame, opbase) when is_tuple(tuple),
    do: List.to_tuple(Enum.map(Tuple.to_list(tuple), &patch_instr(&1, frame, opbase)))
  defp patch_instr(list, frame, opbase) when is_list(list),
    do: Enum.map(list, &patch_instr(&1, frame, opbase))
  defp patch_instr(other, _frame, _opbase), do: other

  # Build a TOP-FIRST result list of the top `n` operands (positions [d-n, d)) into x0 — the shape the
  # interpreter's `interp_invoke` returns and `push_results/3` consumes. Construct bottom-up so the head
  # ends up as the topmost operand: x0 := nil, then prepend y(l+d-n) … y(l+d-1) (top last ⇒ head = top).
  defp build_result_list(l, d, n) do
    [{:test_heap, 2 * n, 0}, {:move, nil, {:x, 0}}] ++
      Enum.flat_map((d - n)..(d - 1)//1, fn pos -> [{:put_list, {:y, l + pos}, {:x, 0}, {:x, 0}}] end)
  end

  # Unpack a TOP-FIRST result list (in x0) of `n` elements onto operand slots [base, base+n): the head
  # (top) goes to the HIGHEST slot base+n-1, the tail's last (bottom) to base. Walk the cons cells.
  defp unpack_result_list(s, n, base) do
    {lbad, s} = new_label(s)
    {lcont, s} = new_label(s)
    s = emit(s, [{:move, {:x, 0}, {:x, 1}}])

    s =
      Enum.reduce((n - 1)..0//-1, s, fn i, acc ->
        tail = if i == 0, do: {:x, 2}, else: {:x, 1}
        # `is_nonempty_list` narrows x1 to a cons BEFORE get_list — a bare get_list on a `call` return
        # (typed `:any`) is rejected by beam_validator (`bad_type: needed t_cons`). The result list is
        # always well-formed by construction, so the guard never fails in practice. Mirrors unpack_vals.
        emit(acc, [
          {:test, :is_nonempty_list, {:f, lbad}, [{:x, 1}]},
          {:get_list, {:x, 1}, {:x, 0}, tail},
          {:move, {:x, 0}, {:y, acc.l + base + i}}
        ])
      end)

    # Normal path skips the trap; lbad raises the same :unreachable trap the interpreter would, ending
    # in a dead deallocate+return so every path stays well-formed + dealloc-balanced (cf. {:unreachable}).
    emit(s, [
      {:jump, {:f, lcont}},
      {:label, lbad},
      {:move, {:atom, :unreachable}, {:x, 0}},
      {:call_ext, 1, {:extfunc, :"Elixir.TinyLasers.Wasm.Trap", :trap!, 1}},
      {:move, {:integer, 0}, {:x, 0}},
      {:deallocate, :ph},
      :return,
      {:label, lcont}
    ])
  end

  defp lower_seq(instrs, s), do: Enum.reduce(instrs, s, &step/2)

  # ── dead code: skip until a join label restores reachability ──
  defp step(_instr, %{reachable: false} = s), do: s

  # ── structured control flow. Supports VOID and SINGLE-RESULT block/loop/if (multi-value → :unsupported).
  # `used` is a map label→exit-depth: a `br`/`br_if` records the operand depth it carries to the target,
  # so a join's depth is known even when the body never falls through. All y-slots are zero-init'd up
  # front, so the validator never sees an uninitialized join register; correctness is just depth tracking.
  # A carried-result count (`delta`) must be 0 or 1. ──
  # A block/loop/if may carry up to @max_block_results values to its join. The slot model already handles
  # k>1: the k results occupy the top y-slots (y(l+entry)..y(l+entry+k-1)) on EVERY exit path (fall-through
  # and br), so depth tracking alone keeps them consistent — multi-value blocks just need a wider gate.
  @max_block_results 16
  defp ok_delta!(delta) when delta >= 0 and delta <= @max_block_results, do: :ok
  defp ok_delta!(_), do: throw(:unsupported)

  # ── try_table (catch side, WASIX §0). A BLOCK (its own ctrl frame; `br 0` in body exits it) wrapped in a
  # BEAM try/try_case. The body runs under `{:try, tslot, {:f, lcatch}}`; a normal exit (fall-through or
  # `br 0`) lands at `lbodyend`, runs `{:try_end, tslot}` (deactivate the catch ctx) and jumps to the block
  # join `lend`. A thrown wasm exception lands at `lcatch`, `{:try_case, tslot}` (x0=class,x1=reason,x2=stk),
  # and we dispatch the catch clauses, mirroring the interp's match_catch/handle_catch exactly. ──
  defp step({:try_table, catches, body}, s) do
    {lbodyend, s} = new_label(s)
    {lcatch, s} = new_label(s)
    {lend, s} = new_label(s)

    # Reserve 6 try-slots for THIS level: t0 = try-context (for try/try_end/try_case), t0+1..t0+3 =
    # class/reason/stacktrace (stashed before the guest_catch_match call, which clobbers x, and kept for a
    # possible reraise), t0+4..t0+5 = tag/vals of the decoded wasm exception (survive the per-clause calls).
    t0 = s.trydepth
    tslot = {:y, {:tryslot, t0}}
    s = %{s | trydepth: t0 + 6, maxtry: max(s.maxtry, t0 + 6), tryctx: [t0 | s.tryctx]}

    entry = s.d
    s = emit(s, [{:try, tslot, {:f, lcatch}}])
    acc_mark = length(s.acc)

    # body: a block frame whose label is lbodyend — so `br 0` exits the try_table THROUGH try_end.
    frame = %{label: lbodyend, entry: entry, loop?: false}
    s1 = lower_seq(body, %{s | ctrl: [frame | s.ctrl]})

    # A divergent guest call (throw/throw_ref/unreachable) inside the body emits a dead `deallocate+return`
    # terminator — but a plain `return` is INVALID while the try-tag is active. The call truly diverges, so
    # the terminator is dead; deactivate the try-tag (try_end) right before it to keep the path well-formed.
    s1 = %{s1 | acc: insert_try_end_before_dead_returns(s1.acc, acc_mark, tslot)}

    end_d = if s1.reachable, do: s1.d, else: Map.get(s1.used, lbodyend, entry)
    ok_delta!(end_d - entry)
    normal_reach = s1.reachable or Map.has_key?(s1.used, lbodyend)

    # normal-exit join: deactivate the catch ctx, then jump past the catch handler to the block join.
    s2 = %{s1 | ctrl: tl(s1.ctrl), used: Map.delete(s1.used, lbodyend)}
    s2 =
      if normal_reach,
        do: emit(%{s2 | reachable: true, d: end_d}, [{:label, lbodyend}, {:try_end, tslot}, {:jump, {:f, lend}}]),
        else: %{s2 | reachable: false}

    # catch handler: classify, dispatch each clause statically, else reraise. Restore trydepth (the 6 slots
    # are free again after the body) but keep maxtry — the slots were live across the body.
    s3 = emit(%{s2 | trydepth: t0}, [{:label, lcatch}, {:try_case, tslot}])
    cls = {:y, {:tryslot, t0 + 1}}
    rsn = {:y, {:tryslot, t0 + 2}}
    stk = {:y, {:tryslot, t0 + 3}}
    tag = {:y, {:tryslot, t0 + 4}}
    vals = {:y, {:tryslot, t0 + 5}}
    # stash class/reason/stacktrace; the raw try_case trace (x2) must be MATERIALIZED via build_stacktrace
    # before it can be re-raised, so do that first. Then guest_catch_match → {:exc,tag,vals} in x0 else :rethrow.
    s3 =
      emit(s3, [
        {:move, {:x, 0}, cls},
        {:move, {:x, 1}, rsn},
        {:move, {:x, 2}, {:x, 0}},
        :build_stacktrace,
        {:move, {:x, 0}, stk},
        {:move, cls, {:x, 0}},
        {:move, rsn, {:x, 1}},
        {:call_ext, 2, {:extfunc, @tinylasers, :guest_catch_match, 2}}
      ])

    # guest_catch_match returns {:exc,tag,vals} (a wasm exception we may catch) or :rethrow (not ours / not
    # caught). A single `lreraise` block re-raises with the original class+stacktrace; the :rethrow test and
    # the is_tuple guard (which also NARROWS x0 to a tuple for the validator) both branch there on no-catch.
    {ldispatch, s3} = new_label(s3)
    {lreraise, s3} = new_label(s3)
    s3 =
      emit(s3, [
        {:test, :is_eq_exact, {:f, ldispatch}, [{:x, 0}, {:atom, :rethrow}]},
        {:jump, {:f, lreraise}},
        {:label, ldispatch},
        # x0 must be the 3-tuple {:exc, tag, vals} now — assert tuple + arity 3 (narrows the type for the
        # validator) before get_tuple_element. The guard never fails in practice (guest_catch_match guarantees).
        {:test, :is_tuple, {:f, lreraise}, [{:x, 0}]},
        {:test, :test_arity, {:f, lreraise}, [{:x, 0}, 3]},
        {:get_tuple_element, {:x, 0}, 1, {:x, 1}},
        {:move, {:x, 1}, tag},
        {:get_tuple_element, {:x, 0}, 2, {:x, 1}},
        {:move, {:x, 1}, vals}
      ])

    # Per-clause static dispatch. Each clause may jump to lend (label 0) or an enclosing ctrl frame's label.
    {s4, catch_used} =
      Enum.reduce(catches, {s3, %{}}, fn clause, {sc, used_acc} ->
        emit_catch_clause(clause, tag, vals, entry, lend, lreraise, sc, used_acc)
      end)

    # fell through all clauses with no match → reraise (mirror match_catch returning nil → throw exc).
    s4 =
      emit(s4, [
        {:label, lreraise},
        {:move, cls, {:x, 0}},
        {:move, rsn, {:x, 1}},
        {:move, stk, {:x, 2}},
        {:call_ext, 3, {:extfunc, @tinylasers, :guest_reraise, 3}},
        {:deallocate, :ph},
        :return
      ])

    # block join lend: reachable if the normal exit reached it OR any catch clause jumped to it. Its depth
    # is whatever the reaching path carried — the normal exit's end_d, else a catch jump's recorded depth.
    reach = normal_reach or Map.has_key?(catch_used, lend)
    join_d =
      cond do
        normal_reach -> end_d
        Map.has_key?(catch_used, lend) -> Map.fetch!(catch_used, lend)
        true -> entry
      end
    ok_delta!(join_d - entry)
    used = catch_used |> Map.delete(lend) |> Map.delete(lbodyend)
    merged_used = Map.merge(s4.used, used)
    s5 = %{s4 | used: merged_used, reachable: reach, d: join_d, maxtry: max(s4.maxtry, s.maxtry)}
    emit(s5, [{:label, lend}])
  end

  # Emit one catch clause's static test + (on match) the value pushes + branch. `tag` holds the caught tag,
  # `vals` the vals list; `entry` is the try_table's operand base; `lend` is the block join (catch label 0).
  # Returns {state, used} where `used` records any join labels this clause's branch targets.
  defp emit_catch_clause(clause, tag, vals, entry, lend, lreraise, s, used) do
    {next_lbl, s} = new_label(s)
    {match_test, push_vals?, push_ref?, label} =
      case clause do
        {:catch, t, l}        -> {[{:test, :is_eq_exact, {:f, next_lbl}, [tag, {:integer, t}]}], true, false, l}
        {:catch_ref, t, l}    -> {[{:test, :is_eq_exact, {:f, next_lbl}, [tag, {:integer, t}]}], true, true, l}
        {:catch_all, l}       -> {[], false, false, l}
        {:catch_all_ref, l}   -> {[], false, false, l}
      end

    push_ref? = push_ref? or match?({:catch_all_ref, _}, clause)
    s = emit(s, match_test)

    # push vals v0..v(k-1) — v0 deepest at yd(entry)..v(k-1) at yd(entry+k-1); arity from the clause's tag.
    {s, depth} =
      if push_vals? do
        arity = TinyLasers.Wasm.tag_arity_of(s.mod, elem(clause, 1))
        s = unpack_vals(s, vals, entry, arity, lreraise)
        {s, entry + arity}
      else
        {s, entry}
      end

    # _ref clauses push an exnref {:exnref, tag, vals} on TOP (built native via guest_mk_exnref(tag, vals)).
    {s, depth} =
      if push_ref? do
        s =
          emit(s, [
            {:move, tag, {:x, 0}},
            {:move, vals, {:x, 1}},
            {:call_ext, 2, {:extfunc, @tinylasers, :guest_mk_exnref, 2}},
            {:move, {:x, 0}, ydn(s, depth)}
          ])

        {s, depth + 1}
      else
        {s, depth}
      end

    # branch target: label 0 → the try_table's own join (lend); L>0 → enclosing ctrl frame L-1's label.
    {target, exit_d} =
      if label == 0 do
        {lend, depth}
      else
        f = Enum.at(s.ctrl, label - 1) || throw(:unsupported)
        ed = if f.loop?, do: f.entry, else: depth
        ok_delta!(ed - f.entry)
        {f.label, ed}
      end

    s = emit(s, [{:jump, {:f, target}}, {:label, next_lbl}])
    {s, Map.put(used, target, exit_d)}
  end

  # y-reg for operand position `pos` independent of current depth tracking (the catch handler pushes to a
  # fixed base since `s.d` isn't being threaded through the static clause emission).
  defp ydn(s, pos), do: {:y, s.l + pos}

  # Unpack the first `arity` elements of the list in `src` into operand y-slots yd(base)..yd(base+arity-1),
  # v0 deepest. Walk the cons cells with get_list (head → slot, tail → x1 to continue).
  defp unpack_vals(s, _src, _base, 0, _lreraise), do: s
  defp unpack_vals(s, src, base, arity, lreraise) do
    s = emit(s, [{:move, src, {:x, 1}}])

    Enum.reduce(0..(arity - 1)//1, s, fn i, sc ->
      tail = if i == arity - 1, do: {:x, 2}, else: {:x, 1}
      # guard x1 is a cons before get_list (narrows the type for the validator; never fails in practice —
      # the tag's arity matches the vals length). On a malformed shape, fall back to the reraise path.
      emit(sc, [
        {:test, :is_nonempty_list, {:f, lreraise}, [{:x, 1}]},
        {:get_list, {:x, 1}, {:x, 0}, tail},
        {:move, {:x, 0}, ydn(sc, base + i)}
      ])
    end)
  end

  # Walk the body slice of the reverse-chronological acc (the `length(acc) - mark` most-recent entries) and,
  # before every dead `deallocate+return` terminator, splice a `{:try_end, tslot}`. In reverse order a
  # terminator is `[:return, {:deallocate,:ph} | rest]`; insert try_end after the deallocate.
  defp insert_try_end_before_dead_returns(acc, mark, tslot) do
    n = length(acc) - mark
    {slice, prefix} = Enum.split(acc, n)
    walk_dead_returns(slice, tslot) ++ prefix
  end

  defp walk_dead_returns([:return, {:deallocate, :ph} | rest], tslot),
    do: [:return, {:deallocate, :ph}, {:try_end, tslot} | walk_dead_returns(rest, tslot)]
  defp walk_dead_returns([h | t], tslot), do: [h | walk_dead_returns(t, tslot)]
  defp walk_dead_returns([], _tslot), do: []

  defp step({:block, nres, body}, s) do
    {lend, s} = new_label(s)
    frame = %{label: lend, entry: s.d, loop?: false, nres: nres}
    s1 = lower_seq(body, %{s | ctrl: [frame | s.ctrl]})
    end_d = if s1.reachable, do: s1.d, else: Map.get(s1.used, lend, frame.entry)
    ok_delta!(end_d - frame.entry)
    reach = s1.reachable or Map.has_key?(s1.used, lend)
    emit(%{s1 | ctrl: tl(s1.ctrl), d: end_d, reachable: reach, used: Map.delete(s1.used, lend)}, [{:label, lend}])
  end

  defp step({:loop, nres, body}, s) do
    {lstart, s} = new_label(s)
    # charge fuel on each iteration (entry) so a transpiled loop traps :out_of_fuel like the interpreter.
    s = emit(s, [{:label, lstart}, {:call_ext, 0, {:extfunc, @tinylasers, :charge_fuel, 0}}])
    frame = %{label: lstart, entry: s.d, loop?: true, nres: nres}
    s1 = lower_seq(body, %{s | ctrl: [frame | s.ctrl]})
    end_d = if s1.reachable, do: s1.d, else: frame.entry
    ok_delta!(end_d - frame.entry)
    %{s1 | ctrl: tl(s1.ctrl), d: end_d, used: Map.delete(s1.used, lstart)}
  end

  defp step({:if, nres, then_b, else_b}, s) do
    if s.d < 1, do: throw(:unsupported)
    d1 = s.d - 1
    {lelse, s} = new_label(s)
    {lend, s} = new_label(s)
    s = emit(s, [{:move, yd(s, s.d - 1), {:x, 0}}, {:test, :is_ne_exact, {:f, lelse}, [{:x, 0}, {:integer, 0}]}])
    frame = %{label: lend, entry: d1, loop?: false, nres: nres}
    st = lower_seq(then_b, %{s | d: d1, reachable: true, ctrl: [frame | s.ctrl]})
    then_reach = st.reachable
    then_d = if then_reach, do: st.d, else: Map.get(st.used, lend, d1)
    st = if then_reach, do: emit(st, [{:jump, {:f, lend}}]), else: st
    st = emit(st, [{:label, lelse}])
    se = lower_seq(else_b, %{st | d: d1, reachable: true})
    else_reach = se.reachable
    else_d = if else_reach, do: se.d, else: Map.get(se.used, lend, d1)
    # the two arms agree on result arity in valid wasm; take a reachable arm's depth (else a br's).
    end_d = cond do
      then_reach -> then_d
      else_reach -> else_d
      true -> Map.get(se.used, lend, d1)
    end
    ok_delta!(end_d - d1)
    reach = then_reach or else_reach or Map.has_key?(se.used, lend)
    emit(%{se | ctrl: tl(se.ctrl), d: end_d, reachable: reach, used: Map.delete(se.used, lend)}, [{:label, lend}])
  end

  defp step({:br, n}, s) do
    frame = Enum.at(s.ctrl, n) || throw(:unsupported)
    # The spec DROPS operands a `br` leaves above [target-entry ++ target-results]. A loop back-edge
    # targets the loop ENTRY (params=0 for non-multivalue loops). A block/if br carries `nres` results,
    # which we relocate from the stack top down to the target's result slots (wb-h9ad asm fix).
    {exit_d, s} =
      if frame.loop? do
        {frame.entry, s}
      else
        s2 = move_results(s, s.d, frame.entry, frame.nres)
        {frame.entry + frame.nres, s2}
      end

    ok_delta!(exit_d - frame.entry)
    s = emit(s, [{:jump, {:f, frame.label}}])
    %{s | reachable: false, used: Map.put(s.used, frame.label, exit_d)}
  end

  defp step({:br_if, n}, s) do
    if s.d < 1, do: throw(:unsupported)
    d1 = s.d - 1
    frame = Enum.at(s.ctrl, n) || throw(:unsupported)
    # br_if carries operands only on the (conditional) taken edge — relocating them with a straight-line
    # move would clobber the fall-through path. Support the cases that need NO relocation: a loop
    # back-edge (params 0), or a block/if whose results already sit exactly at the target slots
    # (d1 == entry + nres). Anything else (results above the target on a conditional edge) → interp.
    exit_d = if frame.loop?, do: frame.entry, else: frame.entry + frame.nres
    if not frame.loop? and frame.nres > 0 and d1 != frame.entry + frame.nres, do: throw(:unsupported)
    ok_delta!(exit_d - frame.entry)
    # branch to target iff cond != 0; is_eq_exact falls through (continue) when cond == 0.
    s = emit(s, [{:move, yd(s, s.d - 1), {:x, 0}}, {:test, :is_eq_exact, {:f, frame.label}, [{:x, 0}, {:integer, 0}]}])
    %{s | d: d1, used: Map.put(s.used, frame.label, exit_d)}
  end

  # move the top `nres` operands (at stack positions [cur_d-nres, cur_d)) down to the target block's
  # result slots [target_base, target_base+nres) — discarding whatever the `br` left in between.
  defp move_results(s, _cur_d, _base, 0), do: s

  defp move_results(s, cur_d, base, nres) do
    Enum.reduce(0..(nres - 1)//1, s, fn i, acc ->
      src = ydn(acc, cur_d - nres + i)
      dst = ydn(acc, base + i)
      if src == dst, do: acc, else: emit(acc, [{:move, src, dst}])
    end)
  end

  defp step({:return}, s) do
    n = s.nres
    if s.d < n, do: throw(:unsupported)

    ret =
      cond do
        n == 0 -> [{:move, {:integer, 0}, {:x, 0}}]
        n == 1 -> [{:move, yd(s, s.d - 1), {:x, 0}}]
        # multi-result: build the TOP-FIRST list (== interp Enum.take) the boundary expects.
        true -> build_result_list(s.l, s.d, n)
      end

    s = emit(s, ret ++ [{:deallocate, :ph}, :return])
    %{s | reachable: false}
  end

  # wasm `unreachable` (trap). Raise the SAME :unreachable trap the interpreter does, via the shared
  # seam. trap! never returns, but the validator can't know that — so emit a dead terminal (move/dealloc/
  # return) after it to keep every path well-formed + dealloc-balanced. Marks the path unreachable.
  defp step({:unreachable}, s) do
    s =
      emit(s, [
        {:move, {:atom, :unreachable}, {:x, 0}},
        {:call_ext, 1, {:extfunc, :"Elixir.TinyLasers.Wasm.Trap", :trap!, 1}},
        {:move, {:integer, 0}, {:x, 0}},
        {:deallocate, :ph},
        :return
      ])

    %{s | reachable: false}
  end

  # ── values / locals ──
  defp step({:i32_const, v}, s), do: push(emit(s, [{:move, {:integer, v &&& @mask32}, yd(s, s.d)}]))

  defp step({:local_get, i}, s), do: push(emit(s, [{:move, {:y, i}, {:x, 0}}, {:move, {:x, 0}, yd(s, s.d)}]))

  defp step({:local_set, i}, s) do
    if s.d < 1, do: throw(:unsupported)
    %{emit(s, [{:move, yd(s, s.d - 1), {:x, 0}}, {:move, {:x, 0}, {:y, i}}]) | d: s.d - 1}
  end

  defp step({:local_tee, i}, s) do
    if s.d < 1, do: throw(:unsupported)
    emit(s, [{:move, yd(s, s.d - 1), {:x, 0}}, {:move, {:x, 0}, {:y, i}}])
  end

  defp step({:drop}, s) do
    if s.d < 1, do: throw(:unsupported)
    %{s | d: s.d - 1}
  end

  defp step({:nop}, s), do: s

  defp step({:op, opcode} = instr, s) do
    cond do
      Map.has_key?(@binops, opcode) -> binop(opcode, s)
      Map.has_key?(@compares, opcode) -> compare(opcode, s)
      opcode == 0x45 -> eqz(s)
      true -> try_handlers(instr, s)
    end
  end

  # ── calls (direct). The frame (y) survives the call, so no spilling: build the args list from the top
  # y-slots, set the callee selector in x0, call_ext the trampoline. A LOCAL fn → call_local/2 (runs it on
  # the shared interp/native state); a host IMPORT → invoke_host/2 (same seam the interpreter uses). ──
  defp step({:call, fidx}, s) when fidx >= 0 do
    {params, results} = func_type(s.mod, s.ni, fidx)
    np = length(params)
    nr = length(results)
    # Any scalar (i32/i64/f32/f64) args/results. Values cross the call_local trampoline as Erlang terms
    # regardless of wasm type, so type doesn't matter — only arity does. A MULTI-result callee returns a
    # TOP-FIRST list (== interp `interp_invoke`); we unpack it onto the operand slots (push_results boundary).
    unless Enum.all?(params, &(&1 in @valtypes)) and Enum.all?(results, &(&1 in @valtypes)) and nr <= @max_block_results,
      do: throw(:unsupported)

    if s.d < np, do: throw(:unsupported)

    build = build_arglist(s, np)

    selector =
      if fidx < s.ni do
        [{:move, {:literal, Enum.at(s.mod.imports, fidx)}, {:x, 0}}, {:call_ext, 2, {:extfunc, @tinylasers, :invoke_host, 2}}]
      else
        [{:move, {:integer, fidx}, {:x, 0}}, {:call_ext, 2, {:extfunc, @tinylasers, :call_local, 2}}]
      end

    s1 = %{s | d: s.d - np}
    s1 = emit(s1, build ++ selector)

    cond do
      nr == 0 -> s1
      nr == 1 -> push(emit(s1, [{:move, {:x, 0}, yd(s1, s1.d)}]))
      true ->
        # unpack the result list (x0) onto slots [d, d+nr); bump depth by nr (track maxd for the frame).
        s2 = unpack_result_list(s1, nr, s1.d)
        %{s2 | d: s1.d + nr, maxd: max(s2.maxd, s1.d + nr)}
    end
  end

  defp step(instr, s), do: try_handlers(instr, s)

  # try each pluggable op-group handler; first that accepts wins, else the function falls back to forms.
  defp try_handlers(instr, s) do
    Enum.reduce_while(@op_handlers, :unsupported, fn mod, _ ->
      case mod.handle(instr, s) do
        {:ok, s2} -> {:halt, s2}
        :unsupported -> {:cont, :unsupported}
      end
    end)
    |> case do
      :unsupported -> throw(:unsupported)
      s2 -> s2
    end
  end

  # build the Erlang arg list [arg0, …, arg(np-1)] (in call order) into x1 from the top np operand slots.
  defp build_arglist(_s, 0), do: [{:move, nil, {:x, 1}}]

  defp build_arglist(s, np) do
    puts =
      for p <- (np - 1)..0//-1 do
        tail = if p == np - 1, do: nil, else: {:x, 1}
        [{:move, yd(s, s.d - np + p), {:x, 0}}, {:put_list, {:x, 0}, tail, {:x, 1}}]
      end

    [{:test_heap, 2 * np, 0} | List.flatten(puts)]
  end

  defp binop(opcode, s) do
    if s.d < 2, do: throw(:unsupported)
    {beam_op, mask?} = @binops[opcode]

    ops =
      [{:move, yd(s, s.d - 2), {:x, 0}}, {:move, yd(s, s.d - 1), {:x, 1}},
       {:gc_bif, beam_op, {:f, 0}, 2, [{:x, 0}, {:x, 1}], {:x, 0}}] ++
        if(mask?, do: [{:gc_bif, :band, {:f, 0}, 1, [{:x, 0}, {:integer, @mask32}], {:x, 0}}], else: []) ++
        [{:move, {:x, 0}, yd(s, s.d - 2)}]

    %{emit(s, ops) | d: s.d - 1}
  end

  defp compare(opcode, s) do
    if s.d < 2, do: throw(:unsupported)
    {domain, test_op, swap?} = @compares[opcode]
    load = [{:move, yd(s, s.d - 2), {:x, 0}}, {:move, yd(s, s.d - 1), {:x, 1}}]
    sconv = if domain == :s, do: signed_ops({:x, 0}, 32) ++ signed_ops({:x, 1}, 32), else: []
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

  # build the from_asm 5-tuple, compile in-memory, load native.
end
