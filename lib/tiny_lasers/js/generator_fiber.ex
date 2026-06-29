defmodule TinyLasers.Js.GeneratorFiber do
  @moduledoc """
  **Host-side driver for JS generators lowered onto TinyLasers.Wasm suspension fibers.**

  A generator INSTANCE is a fiber (see `TinyLasers.Js.AsyncFiber`): `g()` spawns it, `it.next(v)` resumes it,
  `yield e` parks it (handing `e` out). The consumer references a live generator by an integer **handle**.

  This module is the thin generator-specific layer over the raw `AsyncFiber` handoff. It bakes in the three
  isolation requirements the async-fiber red-team flagged as *must-be-in-the-wiring, not-retrofit*:

    * **process-local handle table** (handle → fiber) — handles live in the driving process's dict, so a
      leaked handle integer is inert in any other process (exactly like a leaked linear-memory pointer);
    * **per-run live-fiber CAP** — a guest cannot spawn unbounded fibers (each is a real BEAM process);
    * **kill-set registration** (`:tl_thread_pids`) — the run reaps every generator fiber at teardown via
      `kill_run_threads`, so a generator parked at a `yield` when the guest's main exits is never orphaned.

  Single-active execution, bounded handoff, and unforgeable wake channels come from `AsyncFiber`; shared fuel
  comes from the run context the fiber body adopts (it reuses the parent's one `:tl_last_fuel` atomics, so
  a guest can't shard compute across fibers to dodge the fuel bound).

  The `body` passed to `spawn/1` is responsible for adopting the TinyLasers.Wasm run context and invoking the
  generator's compiled wasm function (calling `AsyncFiber.park/1` at each `yield`). This module is agnostic to
  that body — proven here with plain-Elixir bodies, the real wasm-invoking body layers on in the host-import
  wiring, exactly as `AsyncFiber` itself was built.
  """

  alias TinyLasers.Js.AsyncFiber

  @default_cap 1024

  @doc """
  Spawn a generator fiber running `body` and drive it to its first `yield`. Returns:

    * `{:yield, handle, value}` — parked at a `yield`; `value` is the yielded value, `handle` references it;
    * `{:done, result}` — the generator returned without ever yielding (`result` is the return value);
    * `{:error, reason}` — the body threw / the fiber crashed / the handoff timed out.
  """
  @spec spawn((-> any)) :: {:yield, pos_integer, any} | {:done, any} | {:error, any}
  def spawn(body) when is_function(body, 0) do
    enforce_cap!()

    case AsyncFiber.spawn_fiber(body) do
      {:parked, fiber, value} ->
        track(fiber.pid)
        {:yield, put_handle(fiber), value}

      {:done, result} ->
        release()
        {:done, result}

      {:error, reason} ->
        release()
        {:error, reason}
    end
  end

  @doc """
  Resume generator `handle` with `value` (the `it.next(value)` argument — becomes the result of the `yield`
  the fiber is parked on). Returns `{:yield, value}` (next yield), `{:done, result}` (the generator's return
  value — handle is freed), `{:error, reason}`, or `{:error, :unknown_generator_handle}` for a stale/forged
  handle (inert — the whole point of process-local handles).
  """
  @spec resume(pos_integer, any) :: {:yield, any} | {:done, any} | {:error, any}
  def resume(handle, value) do
    case get_handle(handle) do
      nil ->
        {:error, :unknown_generator_handle}

      fiber ->
        case AsyncFiber.resume(fiber, value) do
          {:parked, _fiber, value} ->
            {:yield, value}

          {:done, result} ->
            finish(handle)
            {:done, result}

          {:error, reason} ->
            finish(handle)
            {:error, reason}
        end
    end
  end

  @doc """
  Forcibly finish a generator (iterator `.return()` / GC / abandoned consumer) — kill its fiber and free the
  handle, cap slot, and kill-set tracking. Idempotent.
  """
  @spec close(pos_integer) :: :ok
  def close(handle) do
    case get_handle(handle) do
      nil ->
        :ok

      fiber ->
        AsyncFiber.kill(fiber)
        finish(handle)
        :ok
    end
  end

  @doc "Live generator-fiber count in the current process (for the cap + tests)."
  @spec live() :: non_neg_integer
  def live, do: Process.get(:tl_gen_live, 0)

  @doc """
  Allocate a fresh handle integer from the same process-local counter as live fibers, WITHOUT registering a
  fiber. Used for an already-finished generator (a body with no `yield`) so the caller still has a unique
  handle to drive its iterator — `get_handle/1` returns nil for it (no fiber), holds no cap slot.
  """
  @spec reserve_handle() :: pos_integer
  def reserve_handle do
    h = Process.get(:tl_gen_next_handle, 1)
    Process.put(:tl_gen_next_handle, h + 1)
    h
  end

  # a completed/killed generator: drop its handle and release its cap slot. The fiber process is already
  # dead (body returned / killed), so leaving its pid in :tl_thread_pids is harmless — kill_run_threads
  # Process.exit's a dead pid as a no-op; we only need the cap counter to come back down.
  defp finish(handle) do
    drop_handle(handle)
    release()
  end

  # ── process-local handle table ──────────────────────────────────────────────────────────────────────
  defp put_handle(fiber) do
    tbl = Process.get(:tl_gen_handles, %{})
    h = Process.get(:tl_gen_next_handle, 1)
    Process.put(:tl_gen_handles, Map.put(tbl, h, fiber))
    Process.put(:tl_gen_next_handle, h + 1)
    h
  end

  defp get_handle(h), do: Process.get(:tl_gen_handles, %{}) |> Map.get(h)

  defp drop_handle(h),
    do: Process.put(:tl_gen_handles, Map.delete(Process.get(:tl_gen_handles, %{}), h))

  # ── live-fiber cap (per driving process / per run) ──────────────────────────────────────────────────
  # Default overridable via `:tl_gen_fiber_cap` in the process dict (the run setup wires it from config).
  defp cap, do: Process.get(:tl_gen_fiber_cap, @default_cap)

  defp enforce_cap! do
    n = Process.get(:tl_gen_live, 0)

    if n >= cap() do
      raise "generator-fiber cap exceeded (#{cap()} live) — a guest may not spawn unbounded generators"
    end

    Process.put(:tl_gen_live, n + 1)
  end

  defp release, do: Process.put(:tl_gen_live, max(Process.get(:tl_gen_live, 0) - 1, 0))

  # ── kill-set: the run reaps these fibers at teardown (kill_run_threads reads :tl_thread_pids) ──────
  defp track(pid), do: Process.put(:tl_thread_pids, [pid | Process.get(:tl_thread_pids, [])])
end
