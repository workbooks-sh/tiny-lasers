defmodule TinyLasers.Wasm.AsmOps.Exceptions do
  @moduledoc """
  **Exception ops (exnref, WASIX §0) for the BEAM-assembly lane.** Lowers `throw` and `throw_ref` to a
  `call_ext` of `TinyLasers.Wasm.guest_throw/2` / `guest_throw_ref/1` — the SAME `{:wasm_exc, tag, vals}`
  Elixir-throw the interpreter raises, so it propagates and is caught identically (a `try_table`, interp or
  asm, catches the same Erlang term; an uncaught one unwinds out of the function). Both ops are divergent
  ⇒ `reachable: false`, exactly like `{:br}`.

  `try_table` itself (the catch side — a BEAM `try`/`catch` around the body integrated with the operand
  stack + ctrl frames) is handled in `TranspileAsm` proper, not here, because it's a control-flow op.
  """
  import TinyLasers.Wasm.AsmCtx

  @tinylasers :"Elixir.TinyLasers.Wasm"

  def handle({:throw, tagidx}, s), do: do_throw(tagidx, s)
  def handle({:throw_ref}, s), do: throw_ref(s)
  def handle(_instr, _s), do: :unsupported

  # throw tag: pop `arity` operands (the tag's params), build them into a list, call guest_throw(tag, list).
  defp do_throw(tagidx, s) do
    arity = TinyLasers.Wasm.tag_arity_of(s.mod, tagidx)

    if s.d < arity do
      :unsupported
    else
      # build_arglist leaves the list (push order = the interp's Enum.reverse(vals)) in x1; tag → x0.
      build = build_arglist(s, arity)

      # guest_throw diverges, but BEAM treats the call_ext as returning — append a dealloc-balanced return
      # terminator (dead code) to keep the path well-formed, exactly like `unreachable`/`return`.
      ops =
        build ++
          [
            {:move, {:integer, tagidx}, {:x, 0}},
            {:call_ext, 2, {:extfunc, @tinylasers, :guest_throw, 2}},
            {:deallocate, :ph},
            :return
          ]

      {:ok, %{emit(s, ops) | d: s.d - arity, reachable: false}}
    end
  end

  # throw_ref: pop an exnref, re-raise its exception (or trap on null / non-exnref).
  defp throw_ref(%{d: d}) when d < 1, do: :unsupported

  defp throw_ref(s) do
    ops = [
      {:move, yd(s, s.d - 1), {:x, 0}},
      {:call_ext, 1, {:extfunc, @tinylasers, :guest_throw_ref, 1}},
      {:deallocate, :ph},
      :return
    ]

    {:ok, %{emit(s, ops) | d: s.d - 1, reachable: false}}
  end

  # build the Erlang list [v0, …, v(n-1)] (wasm push order) from the top n operand slots, into x1.
  defp build_arglist(_s, 0), do: [{:move, nil, {:x, 1}}]

  defp build_arglist(s, n) do
    puts =
      for p <- (n - 1)..0//-1 do
        tail = if p == n - 1, do: nil, else: {:x, 1}
        [{:move, yd(s, s.d - n + p), {:x, 0}}, {:put_list, {:x, 0}, tail, {:x, 1}}]
      end

    [{:test_heap, 2 * n, 0} | List.flatten(puts)]
  end
end
