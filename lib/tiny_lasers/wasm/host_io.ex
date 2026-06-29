defmodule TinyLasers.Wasm.HostIO do
  @moduledoc """
  The **host-import delegation seam** — the Wave-0 mechanism that makes the host side fan-out-shaped, so
  parallel I/O agents never collide on `wasm.ex` *or* the C harness.

  Every Node I/O concern reaches the host through ONE generic bridge (no per-concern C wrapper, no
  `wasm.ex` edit): the guest calls `__host(name, args)` (sync) or `__host_async(name, args)` (async,
  returns a Promise). `TinyLasers.Wasm`'s `host_call` / `host_call_async` clauses parse the JSON `name`+`args`
  and hand them here; `dispatch_call/2` / `dispatch_async/3` resolve `<concern>_<op>` to a module **by
  convention** — prefix `fs` → `TinyLasers.Wasm.HostFs`, `net` → `HostNet`, `crypto` → `HostCrypto`, … — and
  invoke `call/2` (sync) or `call_async/3` (async). There is **no central registry**: an agent adds a
  concern purely by creating `lib/tinylasers/host_<concern>.ex` + its `node/NN_<mod>.js` shim.

  ## Writing a concern module

      defmodule TinyLasers.Wasm.HostFs do
        # sync: receives the decoded JSON args list, returns any JSON-able term (the guest gets it back).
        def call("fs_read", [path]) do
          case TinyLasers.Wasm.VFS.get(path) do
            {:ok, bytes} -> %{"ok" => true, "data" => Base.encode64(bytes)}
            _ -> %{"ok" => false}
          end
        end

        # async (optional): kick off the work, then resolve via Actor.io_complete(actor, id, value, ok?).
        # `actor` is the owning guest's pid (capture it before spawning a Task for a slow op).
        def call_async("net_connect", [host, port], id) do
          actor = TinyLasers.Wasm.Actor.beam_self()
          Task.start(fn -> ... ; TinyLasers.Wasm.Actor.io_complete(actor, id, result) end)
        end
      end

  Raw guest-memory access (`read/2`, `write/2`) is still available for the rare concern that needs
  pointers instead of JSON, via the same `:tl_mem` slot every import uses.
  """

  @doc "Read `len` bytes of guest linear memory at byte-offset `ptr`."
  def read(ptr, len), do: TinyLasers.Wasm.read_bytes(mem(), ptr, len)

  @doc "Write `bin` into guest linear memory at byte-offset `ptr`. Returns `byte_size(bin)`."
  def write(ptr, bin) do
    TinyLasers.Wasm.write_bytes(mem(), ptr, bin)
    byte_size(bin)
  end

  @doc "The guest's current linear memory (the active run/instance), from the process dict."
  def mem, do: Process.get(:tl_mem)

  @doc """
  Synchronous generic bridge: route `<concern>_<op>` to its module's `call/2` and return the (JSON-able)
  result. Raises if no concern module implements the op (an unimplemented host import is a guest bug).
  """
  def dispatch_call(name, args) when is_binary(name) and is_list(args) do
    case concern_module(name, :call, 2) do
      nil -> raise("tinylasers: no host concern module for sync import '#{name}'")
      mod -> mod.call(name, args)
    end
  end

  @doc """
  Async generic bridge: route `<concern>_<op>` to its module's `call_async/3` (which eventually calls
  `TinyLasers.Wasm.Actor.io_complete/4` to resolve the guest promise `id`). Returns `0`.
  """
  def dispatch_async(name, args, id) when is_binary(name) and is_list(args) do
    case concern_module(name, :call_async, 3) do
      nil -> raise("tinylasers: no host concern module for async import '#{name}'")
      mod -> mod.call_async(name, args, id)
    end

    0
  end

  # resolve <concern>_<op> → TinyLasers.Wasm.Host<Concern>, iff it exports the expected arity.
  defp concern_module(name, fun, arity) do
    case String.split(name, "_", parts: 2) do
      [concern, _op] when concern != "" ->
        mod = Module.concat(TinyLasers.Wasm, "Host" <> String.capitalize(concern))
        if Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity), do: mod, else: nil

      _ ->
        nil
    end
  end
end
