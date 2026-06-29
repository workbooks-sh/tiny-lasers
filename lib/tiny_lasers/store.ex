defmodule TinyLasers.Store do
  @moduledoc """
  Minimal in-process Store — placeholder for the `{:store, tenant}` VFS backend.

  The real tenant-partitioned persistent store is part of the pending WASIX/Linux-ABI
  rebuild. Until then, `TinyLasers.Wasm.VFS` defaults to its zero-dep `:map` backend, and
  this provides a faithful in-process implementation of the 4 functions VFS calls so the
  `{:store, _}` path also works for tests/spikes without dragging in any nexus dependency.
  """

  defp k(mod, tenant), do: {:tl_store, mod, tenant}

  def all(mod, tenant), do: Process.get(k(mod, tenant), [])

  def count(mod, tenant), do: length(all(mod, tenant))

  def create(mod, attrs, tenant) do
    Process.put(k(mod, tenant), all(mod, tenant) ++ [struct(mod, attrs)])
    :ok
  end

  def update(mod, match, attrs, tenant) do
    rows =
      Enum.map(all(mod, tenant), fn r ->
        if Map.take(Map.from_struct(r), Map.keys(match)) == match, do: struct(r, attrs), else: r
      end)

    Process.put(k(mod, tenant), rows)
    :ok
  end

  def clear(mod, tenant) do
    Process.put(k(mod, tenant), [])
    :ok
  end
end
