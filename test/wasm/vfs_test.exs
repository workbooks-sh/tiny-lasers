defmodule TinyLasers.WasmVfsTest do
  @moduledoc """
  The virtual filesystem is **pluggable** and **tenant-safe** — the seam every guest fs operation
  (and, ultimately, rollup reading modules / writing a bundle) backs onto. The `:map` backend is
  per-run process state (zero-dep, the default); the `{:store, tenant}` backend persists into the
  tenant-partitioned store. These prove (1) the seam round-trips, (2) the SAME guest path in two
  tenants resolves to two disjoint byte-stores — there is no filesystem to escape, only a key in
  your own partition. Migrated from nexus's `washy_vfs_test.exs`.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Wasm.{VFS, FileRow}

  setup do
    TinyLasers.Store.clear(FileRow, "tenant-a")
    TinyLasers.Store.clear(FileRow, "tenant-b")
    on_exit(fn -> Process.delete(:washy_backend) end)
    :ok
  end

  test ":map backend round-trips (default, zero-dep)" do
    Process.delete(:washy_backend)
    Process.put(:washy_vfs, %{})
    assert VFS.get("a.txt") == nil
    refute VFS.has?("a.txt")
    VFS.put("a.txt", "hello")
    assert VFS.get("a.txt") == "hello"
    assert VFS.has?("a.txt")
    VFS.delete("a.txt")
    assert VFS.get("a.txt") == nil
  end

  test "{:store, tenant} backend persists into the tenant-partitioned store" do
    Process.put(:washy_backend, {:store, "tenant-a"})
    VFS.put("notes.txt", "durable bytes")
    assert VFS.get("notes.txt") == "durable bytes"
    # overwrite-in-place (no duplicate row)
    VFS.put("notes.txt", "v2")
    assert VFS.get("notes.txt") == "v2"
    assert TinyLasers.Store.count(FileRow, "tenant-a") == 1
    VFS.delete("notes.txt")
    assert VFS.get("notes.txt") == nil
    assert TinyLasers.Store.count(FileRow, "tenant-a") == 0
  end

  test "SAFETY: the SAME guest path in two tenants is two disjoint stores" do
    # path traversal is meaningless: '../../etc/passwd' is just a string key in YOUR partition.
    escape = "../../etc/passwd"

    Process.put(:washy_backend, {:store, "tenant-a"})
    VFS.put(escape, "A-secret")
    VFS.put("shared.txt", "A-data")

    Process.put(:washy_backend, {:store, "tenant-b"})
    # tenant B cannot see tenant A's bytes, even with an identical key
    assert VFS.get(escape) == nil
    assert VFS.get("shared.txt") == nil
    VFS.put("shared.txt", "B-data")

    # each tenant reads only its own partition
    Process.put(:washy_backend, {:store, "tenant-a"})
    assert VFS.get("shared.txt") == "A-data"
    assert VFS.get(escape) == "A-secret"

    Process.put(:washy_backend, {:store, "tenant-b"})
    assert VFS.get("shared.txt") == "B-data"
  end
end
