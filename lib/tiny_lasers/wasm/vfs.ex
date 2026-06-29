defmodule TinyLasers.Wasm.VFS do
  @moduledoc """
  Wasm's **virtual filesystem seam** — the one home for every file read/write a guest performs
  through WASI (`path_open`/`fd_read`/`fd_write`/`fd_filestat_get`). The guest only ever sees
  *paths under the `/work` preopen*; this module decides where those bytes actually live.

  ## Why this is SAFE by construction

  A guest path is never a host path. WASI gives the guest a single preopened directory (`/work`);
  every `path_open` is *relative* to it, and Wasm hands the guest a fd that maps to a **string key**
  in this store — not an OS file descriptor, not a host path. So the classic escapes are meaningless
  here: `../../etc/passwd` is just a funny string key that selects (or creates) a row in the SAME
  tenant-scoped table. There is no filesystem to traverse out of, because there is no filesystem —
  only a key→bytes map mediated entirely in Elixir.

  Two backends, same interface:

    * `:map` (default) — a process-dict map (`:tl_vfs`). Zero deps, per-run, perfect for
      tests/spikes and the C/Rust generality proofs.
    * `{:store, tenant}` — rows in the tenant-partitioned SQLite store (`TinyLasers.Store`, the one
      persistent data unit). **Tenant isolation is enforced in the store, host-side** — the guest
      cannot name a tenant, only a key within its own partition (`TinyLasers.Store` fails closed on an
      omitted tenant, wb-lijn). Path traversal stays meaningless, and one guest can never read
      another tenant's bytes even with an identical key.

  Select the backend per-process: `Process.put(:tl_backend, {:store, tenant})` before running.
  Defaults to `:map`. (Content-addressing/dedup is an optional later optimization on the `:store`
  backend — it is NOT what makes this safe; the tenant partition is.)
  """

  @doc "Bytes at `rel`, or `nil` if absent."
  def get(rel), do: do_get(backend(), rel)

  @doc "Write `content` (bytes) at `rel`. Overwrites. → `:ok`."
  def put(rel, content), do: do_put(backend(), rel, content)

  @doc "Does `rel` exist?"
  def has?(rel), do: get(rel) != nil

  @doc "Remove `rel`. → `:ok` (no-op if absent)."
  def delete(rel), do: do_delete(backend(), rel)

  @doc "All file relpaths in the current backend (for directory listing / `fd_readdir`)."
  def list, do: do_list(backend())

  defp do_list(:map), do: Map.keys(Process.get(:tl_vfs, %{}))
  defp do_list({:store, tenant}), do: Enum.map(TinyLasers.Store.all(TinyLasers.Wasm.FileRow, tenant), & &1.path)

  @doc "The backend selected for this process (`:map` default | `{:store, tenant}`)."
  def backend, do: Process.get(:tl_backend, :map)

  # `:map` reads/writes the process-dict map (zero-dep, per-run).
  # `{:store, tenant}` reads/writes the tenant-partitioned SQLite store (durable, isolated).
  defp do_get(:map, rel), do: Map.get(Process.get(:tl_vfs, %{}), rel)

  defp do_get({:store, tenant}, rel) do
    case Enum.find(TinyLasers.Store.all(TinyLasers.Wasm.FileRow, tenant), &(&1.path == rel)) do
      %{content: c} -> c
      _ -> nil
    end
  end

  defp do_put(:map, rel, content) do
    Process.put(:tl_vfs, Map.put(Process.get(:tl_vfs, %{}), rel, content))
    :ok
  end

  defp do_put({:store, tenant} = b, rel, content) do
    if do_get(b, rel) == nil do
      TinyLasers.Store.create(TinyLasers.Wasm.FileRow, %{path: rel, content: content}, tenant)
    else
      TinyLasers.Store.update(TinyLasers.Wasm.FileRow, %{path: rel}, %{content: content}, tenant)
    end

    :ok
  end

  defp do_delete(:map, rel) do
    Process.put(:tl_vfs, Map.delete(Process.get(:tl_vfs, %{}), rel))
    :ok
  end

  defp do_delete({:store, tenant}, rel) do
    # store/4 has no per-row delete; rewrite the partition minus this key (small VFS tables).
    rows = Enum.reject(TinyLasers.Store.all(TinyLasers.Wasm.FileRow, tenant), &(&1.path == rel))
    TinyLasers.Store.clear(TinyLasers.Wasm.FileRow, tenant)
    Enum.each(rows, &TinyLasers.Store.create(TinyLasers.Wasm.FileRow, %{path: &1.path, content: &1.content}, tenant))
    :ok
  end
end

defmodule TinyLasers.Wasm.FileRow do
  @moduledoc """
  The `resource` shape for a Wasm VFS file row — `path → content` bytes, persisted tenant-scoped
  by `TinyLasers.Store` (one SQLite file, BEAM-owned). Minimal `__fields__/0` so `Nexus.Resource.validate/2`
  fields it like any declared resource; content is an opaque term blob (binary), `path` the string key.
  """
  defstruct path: "", content: ""

  def __fields__, do: [{:path, {:scalar, :text}}, {:content, {:scalar, :text}}]
end
