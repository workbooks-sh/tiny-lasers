defmodule TinyLasers.Wasm.JitCache do
  @moduledoc """
  **The JIT compiled-code cache (wb-4fym).** A public ETS table (NOT `:persistent_term`).

  The transpiler caches each compiled function/module so it builds at most once ever. `:persistent_term`
  was the wrong home: every `put`/`delete` triggers a GLOBAL GC scan forcing every ref-holding process to
  fullsweep (2 at a time) — at thousands of concurrent guests that's continuous global heap scans and
  scheduler stalls (deep-research report §3 Wall #2). ETS gives lock-free concurrent reads, O(1) evictable
  writes, and zero process-GC impact. The values are loaded native MFAs `{module, fun, arity}` (or `:error`
  / `{:ok, ...}`), so they're tiny and copy-cheap on lookup.

  Owned by a supervised GenServer so the table outlives any guest process. Falls back to a lazily-created
  table when the app isn't started (e.g. `mix run --no-start` scripts).
  """
  use GenServer

  @table :tl_jit_cache

  def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    create()
    {:ok, nil}
  end

  @doc "Look up `key`; returns the cached value or `default` (`:miss`)."
  def get(key, default \\ :miss) do
    ensure()

    case :ets.lookup(@table, key) do
      [{_, v}] -> v
      [] -> default
    end
  end

  @doc "Cache `val` under `key`. Returns `val`."
  def put(key, val) do
    ensure()
    :ets.insert(@table, {key, val})
    val
  end

  @doc "Drop a cached entry (evictable, unlike persistent_term)."
  def delete(key) do
    ensure()
    :ets.delete(@table, key)
    :ok
  end

  defp ensure do
    if :ets.whereis(@table) == :undefined, do: create()
    :ok
  end

  defp create do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
  rescue
    ArgumentError -> :ok
  catch
    _, _ -> :ok
  end
end
