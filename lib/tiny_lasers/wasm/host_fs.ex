defmodule TinyLasers.Wasm.HostFs do
  @moduledoc """
  The `fs` concern (Node Wave-1, wb-xd13) — the REFERENCE I/O module proving the Wave-0 fan-out seam: a
  whole Node core module added as pure Elixir (`call/2`) + pure JS (`node/55_fs.js`), touching NO shared
  file (no `harness_run.c`, no `washy.ex`). Reuses the existing `TinyLasers.Wasm.VFS` (string-key → bytes,
  tenant-safe by construction) — no new filesystem. Bytes cross the bridge base64-encoded (binary-safe
  through the JSON envelope). The guest's path is normalized to a VFS key host-side too (defence in depth).

  Routed here by `TinyLasers.Wasm.HostIO` because the import name is `fs_*`. VFS reads/writes are synchronous
  (in-memory or SQLite), so `fs` rides the SYNC bridge (`__host`); `fs.promises`/callbacks are sync results
  deferred to a microtask in the JS shim. (Cross-message persistence over the `:map` backend is a follow-up;
  the `{:store, tenant}` backend already persists.)
  """

  @doc "Handle one `fs_*` host call. `args` is the decoded JSON list; returns a JSON-able result map."
  def call("fs_read", [path]) do
    case TinyLasers.Wasm.VFS.get(norm(path)) do
      nil -> %{"ok" => false, "err" => "ENOENT"}
      bytes -> %{"ok" => true, "b64" => Base.encode64(bytes)}
    end
  end

  def call("fs_write", [path, b64]) do
    TinyLasers.Wasm.VFS.put(norm(path), Base.decode64!(b64))
    %{"ok" => true}
  end

  def call("fs_exists", [path]), do: %{"ok" => TinyLasers.Wasm.VFS.has?(norm(path))}

  def call("fs_unlink", [path]) do
    TinyLasers.Wasm.VFS.delete(norm(path))
    %{"ok" => true}
  end

  def call("fs_stat", [path]) do
    case TinyLasers.Wasm.VFS.get(norm(path)) do
      nil -> %{"ok" => false, "err" => "ENOENT"}
      bytes -> %{"ok" => true, "size" => byte_size(bytes), "isFile" => true, "isDirectory" => false}
    end
  end

  # readdir: VFS has no real dirs (flat key space) — return the immediate child names under the prefix.
  def call("fs_list", [path]) do
    prefix = case norm(path) do "" -> ""; p -> p <> "/" end

    entries =
      TinyLasers.Wasm.VFS.list()
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.map(&(String.replace_prefix(&1, prefix, "") |> String.split("/") |> hd()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    %{"ok" => true, "entries" => entries}
  end

  def call("fs_mkdir", [_path]), do: %{"ok" => true}

  # a guest path (/work/foo, ./foo, foo) → a flat VFS key. Mirrors the JS-side normalization; harmless
  # if doubled. Path traversal is meaningless here (the key selects a row in the tenant's own partition).
  defp norm(path) do
    path
    |> to_string()
    |> String.replace_prefix("/work/", "")
    |> String.replace_prefix("/work", "")
    |> String.replace_prefix("./", "")
    |> String.replace_prefix("/", "")
  end
end
