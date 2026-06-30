defmodule TinyLasers.Wasm.Transpile.AsyncCompiler do
  @moduledoc """
  **Bounded background compile QUEUE for the async tier lane** (`TinyLasers.Wasm.Transpile.compile_one_async/2`).

  Problem this fixes: the old `compile_one_async` gated inflight compiles with an `:atomics` counter
  (`@max_inflight_compiles`) and **silently DROPPED** every hot function that crossed the threshold while
  the gate was full (`:atomics.sub` + return, no spawn). A dropped function stayed `:pending` in the
  per-run `:tl_jit` dict, and on every subsequent call the `:pending` branch polled `cached_one/2` →
  `:miss` forever → it ran **interpreted for ALL of its calls**. On a compile storm (many functions
  crossing the hotness threshold in quick succession — e.g. acorn's parse dispatchers), MOST hot
  functions were dropped, so the async tier only ever compiled a handful and the rest stayed interpreted
  — the "~17% of invocations still interpreted despite being statically lowerable" symptom.

  Fix: a real QUEUE. `enqueue/2` pushes `{mod, gfidx}` (deduped by `{mod.id, gfidx}`); the GenServer
  spawns up to `@max_inflight` workers and, each time a worker finishes (`:done`), drains the next
  queued item. NO hot function is ever dropped — it merely waits its turn. The `@max_inflight` cap is
  preserved so compilation never starves the interpreter of CPU (the original intent). Workers call
  `Transpile.compile_one/2`, which caches the whole chunk's outcome in `JitCache`; the in-flight run
  adopts it via `cached_one/2` the moment it lands (`:pending` branch).

  Idempotent under races: a `{mod.id, gfidx}` already queued/in-flight is a no-op. `compile_one`
  itself is cache-short-circuited, so two enqueues for functions in the SAME chunk compile the chunk
  once and the second is a fast cache hit.
  """
  use GenServer

  # Configurable via `config :nexus, TinyLasers.Wasm.Transpile.AsyncCompiler, max_inflight: n`.
  defp max_inflight, do: Application.get_env(:nexus, __MODULE__, [])[:max_inflight] || 2

  ## supervision / start

  def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  defp server do
    case Process.whereis(__MODULE__) do
      nil ->
        # Not started (e.g. `mix run --no-start` / a bare test) — start an unsupervised instance so the
        # queue still works. Idempotent under races.
        case start_link([]) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      pid ->
        pid
    end
  end

  ## public API

  @doc """
  Fire-and-forget: queue `gfidx` for a background compile. Returns `:ok` immediately (the run never
  stalls on the compile). The result lands in the persistent `JitCache`, where the in-flight run picks
  it up via `cached_one/2`. Idempotent — a re-enqueue of an already-queued/in-flight `{mod.id, gfidx}`
  is a no-op. Modules without an `id` (can't cache/dedup) bypass the queue and spawn directly.
  """
  def enqueue(mod, gfidx) do
    case mod.id do
      nil ->
        spawn(fn -> TinyLasers.Wasm.Transpile.compile_one(mod, gfidx) end)
        :ok

      mod_id ->
        GenServer.cast(server(), {:enqueue, mod, mod_id, gfidx})
        :ok
    end
  end

  @doc "Runtime-tune the max concurrent background compiles (drains the queue faster on multi-core)."
  def set_max(n) when is_integer(n) and n > 0, do: GenServer.call(server(), {:set_max, n})

  ## GenServer

  @impl true
  def init(_) do
    {:ok, %{queue: :queue.new(), inflight: 0, max: max_inflight(), seen: MapSet.new()}}
  end

  @impl true
  def handle_call({:set_max, n}, _from, state) do
    state = %{state | max: n}
    {:reply, :ok, maybe_spawn(state)}
  end

  @impl true
  def handle_cast({:enqueue, mod, mod_id, gfidx}, state) do
    key = {mod_id, gfidx}

    if MapSet.member?(state.seen, key) do
      {:noreply, state}
    else
      state = %{state | queue: :queue.in({mod, key}, state.queue), seen: MapSet.put(state.seen, key)}
      {:noreply, maybe_spawn(state)}
    end
  end

  @impl true
  def handle_info({:done, key}, state) do
    state = %{state | inflight: state.inflight - 1, seen: MapSet.delete(state.seen, key)}
    {:noreply, maybe_spawn(state)}
  end

  defp maybe_spawn(%{inflight: inflight, max: max, queue: q} = state) when inflight < max do
    case :queue.out(q) do
      {{:value, {mod, key}}, q2} ->
        spawn_worker(mod, key)
        maybe_spawn(%{state | inflight: inflight + 1, queue: q2})

      {:empty, _} ->
        state
    end
  end

  defp maybe_spawn(state), do: state

  defp spawn_worker(mod, key) do
    server = self()

    spawn(fn ->
      try do
        TinyLasers.Wasm.Transpile.compile_one(mod, elem(key, 1))
      after
        send(server, {:done, key})
      end
    end)
  end
end
