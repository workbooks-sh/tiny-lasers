defmodule TinyLasers.Js.GeneratorHost do
  @moduledoc """
  **Host import handlers that wire a Porffor-compiled JS generator onto a TinyLasers.Wasm suspension fiber.**

  Three host imports — declared in `compiler/wrap.js`, registered into `:tl_imports` via `imports/0` —
  drive a generator instance as PURE CONTROL-FLOW signals. NO values cross the wasm boundary:

    * `__porffor_gen_start(funcref) -> handle` — the FIRST `it.next()`: spawn the generator body on a fiber
      and run it to its first `yield` (lazy — nothing runs until the first `next`, and a generator that is
      created but never driven holds no process). Returns the fiber handle, or `0` if the body returned
      without yielding (already done).
    * `__porffor_gen_yield() -> 0` — `yield` inside the body (runs ON THE FIBER): park until resumed.
    * `__porffor_gen_resume(handle) -> done` — a later `it.next(v)`: resume the fiber; `0` = it yielded
      again, `1` = the body returned (done). The fiber is reaped the moment the body returns.

  The yielded / sent / return values live in shared `any` module globals (`__genYielded` / `__genSent` /
  `__genReturn`) the fiber and parent BOTH see — the fiber adopts the parent's globals (`gen_capture_context`
  shares, not copies). So values round-trip as real JS values with full runtime types — objects included —
  with zero marshaling, and the host never touches guest data (also strictly better for isolation). The body
  rewrite (vertical 3) writes `__genYielded` before each `yield` and reads `__genSent` after; the iterator
  reads `__genYielded` after each call.

  Isolation comes from `GeneratorFiber` (process-local handles, per-run live cap, kill-set registration in
  `:tl_thread_pids`) over `AsyncFiber` (single-active baton, bounded handoff, unforgeable wake channel),
  plus `gen_capture_context`'s shared per-run fuel (invariant 4). Fibers park on the `make_ref` message
  channel — never a guest-writable futex addr — so they leave no `:tl_futex` rows (invariant 7 by
  construction). Single-active means only one of {parent, fiber} touches the shared globals at any instant.
  """

  alias TinyLasers.Js.{AsyncFiber, GeneratorFiber}

  # Imports are declared f64 (Porffor valtype), so every handler returns a FLOAT — an integer result reaches
  # the guest as an f64 the runtime later float-reinterprets (and crashes on).
  @bad_funcref -1.0
  @done_on_start 0.0
  @resume_yielded 0.0
  @resume_done 1.0

  @doc "The Porffor-lane `:tl_imports` entries for the three generator host imports (idents f/g/h)."
  @spec imports() :: %{optional(String.t()) => (list -> float)}
  def imports do
    %{
      "f" => &__MODULE__.gen_start/1,
      "g" => &__MODULE__.gen_yield/1,
      "h" => &__MODULE__.gen_resume/1
    }
  end

  # ── __porffor_gen_start(funcref) -> handle  (runs on the CONTROLLER — the first it.next()) ─────────────
  @doc false
  def gen_start([funcref_f64 | _]) do
    rt = Process.get(:tl_rt) || raise "__porffor_gen_start outside a TinyLasers.Wasm run"

    case Map.get(rt.table, trunc(funcref_f64)) do
      nil ->
        @bad_funcref

      gfidx ->
        ctx = TinyLasers.Wasm.gen_capture_context()
        args = funcref_call_args(rt, gfidx)

        case GeneratorFiber.spawn(gen_body_thunk(ctx, gfidx, args)) do
          # parked at its first yield — the yielded value is already in __genYielded (shared global). The
          # carried value is the fiber's (possibly grown) :tl_mem — adopt it (see adopt_mem).
          {:yield, handle, fiber_mem} -> adopt_mem(fiber_mem); handle * 1.0
          # the body completed; unpack the tagged result (normal return vs a thrown exception to propagate).
          {:done, completion} -> finish(completion, @done_on_start)
          {:error, _} -> @done_on_start
        end
    end
  end

  # The fiber body: adopt the run context, run the wasm generator function, and return a TAGGED completion so
  # the controller can both adopt the body's final memory AND propagate a thrown exception. A guest `throw e`
  # is an Elixir `throw({:wasm_exc, …})`; we catch it (with the body's mem) and hand it back rather than let
  # AsyncFiber collapse it to an opaque {:error} — so the consumer's `next()` re-raises the ORIGINAL value.
  defp gen_body_thunk(ctx, gfidx, args) do
    fn ->
      TinyLasers.Wasm.gen_adopt_context(ctx)

      try do
        TinyLasers.Wasm.call_local(gfidx, args)
        # wasm return value is unused — a generator's return value rides the __genReturn global. Carry the
        # body's FINAL :tl_mem so the controller adopts it if the body grew memory (a return-value or
        # exception object may live in the grown region).
        {:gen_return, Process.get(:tl_mem)}
      catch
        :throw, {:wasm_exc, _tag, _vals} = exc -> {:gen_raise, exc, Process.get(:tl_mem)}
      end
    end
  end

  # Apply a {:done, completion} result: adopt the carried mem, then either report `done_signal` (normal) or
  # re-raise the body's exception in THIS (the consumer's) process so its `next()` call throws the original.
  defp finish({:gen_return, fiber_mem}, done_signal), do: (adopt_mem(fiber_mem); done_signal)
  defp finish({:gen_raise, exc, fiber_mem}, _done_signal), do: (adopt_mem(fiber_mem); throw(exc))
  # defensive: an untagged completion (shouldn't happen) → just report done.
  defp finish(_other, done_signal), do: done_signal

  # ── __porffor_gen_yield() -> 0  (runs ON THE FIBER, inside the suspended body) ─────────────────────────
  @doc false
  def gen_yield(_args) do
    # hand control back to the controller and block until resumed. The yielded value is in __genYielded and
    # the sent value will be in __genSent — both shared globals — so the carried value is the MEMORY backing:
    # memory.grow REALLOCATES :tl_mem (per-process), so the fiber hands its current mem OUT to the
    # controller and adopts the controller's mem on the way back, keeping the single shared heap coherent
    # across the handoff. (globals — incl. the malloc bump cursor — are a shared atomics, so they auto-sync.)
    resumed_mem = AsyncFiber.park(Process.get(:tl_mem))
    adopt_mem(resumed_mem)
    @resume_yielded
  end

  # ── __porffor_gen_resume(handle) -> done  (runs on the CONTROLLER — a later it.next(v)) ────────────────
  @doc false
  def gen_resume([handle_f64 | _]) do
    case GeneratorFiber.resume(trunc(handle_f64), Process.get(:tl_mem)) do
      {:yield, fiber_mem} -> adopt_mem(fiber_mem); @resume_yielded
      # the body completed; re-raise a thrown exception (so next() throws) or report done.
      {:done, completion} -> finish(completion, @resume_done)
      # an unknown/dead handle: report done (inert — the consumer stops).
      {:error, _} -> @resume_done
    end
  end

  # Adopt a :tl_mem backing handed across the park/resume handoff (only if the other side grew it). The
  # caller and fiber alternate (single-active), so whoever ran last owns the authoritative backing.
  defp adopt_mem(mem) when not is_nil(mem), do: Process.put(:tl_mem, mem)
  defp adopt_mem(_), do: :ok

  # The funcref resolved to its `#indirect_<name>` wrapper — the wrapperArgc=16 ABI (argc i32 + 16 arg
  # value/type pairs + this + new.target). For a 0-arg generator we pass type-matched UNDEFINED: 0 for an
  # i32 slot, 0.0 for an f64 slot. `call_local` reverses args into the locals tuple, so build in param order
  # and reverse here. (v3 follow-up: a generator WITH params marshals the real call args into the slots.)
  defp funcref_call_args(rt, gfidx) do
    tyidx = Enum.at(rt.mod.funcs, gfidx - rt.ni)
    {params, _results} = Enum.at(rt.mod.types, tyidx)

    params
    |> Enum.map(fn
      124 -> 0.0
      _ -> 0
    end)
    |> Enum.reverse()
  end
end
