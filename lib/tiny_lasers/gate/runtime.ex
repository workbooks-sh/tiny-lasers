defmodule TinyLasers.Gate.Runtime do
  @moduledoc """
  The confined runtime for the GuestGate capability-spike.

  This is the ENTIRE host surface a compiled guest may touch. Compiled guest
  bytecode calls only functions in this module — proven structurally by the
  red-team's bytecode inspector (`TinyLasers.Gate.dangerous_refs/1`).

  ## The one load-bearing invariant

      Guest data NEVER crosses into the atom / MFA / raw-fun / raw-pid domain.

  Guest values live in a closed universe:

    * number  -> Elixir float
    * string  -> Elixir binary (NEVER an atom)
    * boolean -> `true` / `false`        (a fixed 2-element atom set, not guest-controllable)
    * absent  -> `:undefined`            (a fixed atom, not guest-controllable)
    * object  -> `{:obj, id}`            (integer handle into the per-process heap)
    * function-> `{:fun, id}`            (integer handle into the per-process closure table)
    * host cap-> `{:host, cap_id}`       (integer handle into the granted-capability registry)

  Because a guest string is a binary and never an atom, and because no operation
  here calls `binary_to_atom` / `list_to_atom` / `apply` / `binary_to_term` on
  guest data, a guest can never *name* a host module. Escape isn't blocked at
  runtime — it is unexpressible.

  The heap, closure table, and run context live in the running process's
  dictionary, so they are per-run, process-local, and reclaimed for free when the
  run process dies (the BEAM-term-offload model).
  """

  # ── run context setup (host-side; called by the driver, never by guest code) ──

  @doc "Install the run context (granted caps, tenant FS, output buffer) for this process."
  def __init(ctx) do
    Process.put(:gg_ctx, ctx)
    Process.put(:gg_heap, %{})
    Process.put(:gg_funs, %{})
    Process.put(:gg_next, 0)
    Process.put(:gg_out, [])
    Process.put(:gg_fs_writes, [])
    :ok
  end

  @doc "Positional arg fetch for guest closures (keeps the guest's BIF surface off `Enum`)."
  def arg(list, i) when is_list(list), do: Enum.at(list, i, :undefined)
  def arg(_, _), do: :undefined

  def __output, do: Process.get(:gg_out, []) |> Enum.reverse()
  def __ctx, do: Process.get(:gg_ctx)

  defp __id do
    n = Process.get(:gg_next, 0)
    Process.put(:gg_next, n + 1)
    n
  end

  # ── object allocation (handles, not pointers) ──

  @doc "Allocate an object from ordered {key, value} pairs. Returns a `{:obj, id}` handle."
  def obj_new(pairs) do
    id = __id()
    {keys, map} =
      Enum.reduce(pairs, {[], %{}}, fn {k, v}, {ks, m} ->
        k = key_str(k)
        if Map.has_key?(m, k), do: {ks, Map.put(m, k, v)}, else: {ks ++ [k], Map.put(m, k, v)}
      end)

    heap = Process.get(:gg_heap)
    Process.put(:gg_heap, Map.put(heap, id, {keys, map}))
    {:obj, id}
  end

  @doc "Property read. Non-objects read as `:undefined` (no host reach)."
  def get({:obj, id}, key) do
    case Process.get(:gg_heap) |> Map.get(id) do
      {_keys, map} -> Map.get(map, key_str(key), :undefined)
      _ -> :undefined
    end
  end

  def get(_not_obj, _key), do: :undefined

  @doc "Property write. Preserves insertion order. Writing to a non-object is a no-op."
  def set({:obj, id} = o, key, value) do
    k = key_str(key)
    heap = Process.get(:gg_heap)

    case Map.get(heap, id) do
      {keys, map} ->
        keys = if Map.has_key?(map, k), do: keys, else: keys ++ [k]
        Process.put(:gg_heap, Map.put(heap, id, {keys, Map.put(map, k, value)}))
        value

      _ ->
        o
    end

    value
  end

  def set(_not_obj, _key, value), do: value

  @doc "Ordered own-key list of an object (for the no-atom enumeration red-team)."
  def keys({:obj, id}) do
    case Process.get(:gg_heap) |> Map.get(id) do
      {keys, _map} -> keys
      _ -> []
    end
  end

  def keys(_), do: []

  # ── F2 DIRECT-TERM objects (Phase 1): held directly by the guest, NOT a handle-table entry, so the BEAM
  # GC reclaims unreachable objects (H1). Representation `{keys, map}` — an ordered-key list + a binary-keyed
  # map — is a plain immutable term (no atom/pid/fun), so it is a safe guest value. Mutation is functional
  # (returns a new tuple); the lowering rebinds the local. ──

  @doc "Empty direct-term object."
  def olit, do: {[], %{}}

  @doc "Functional property write on a direct-term object (insertion-ordered). Returns a NEW object."
  def oput({keys, map}, k, v) do
    k = key_str(k)
    keys = if Map.has_key?(map, k), do: keys, else: keys ++ [k]
    {keys, Map.put(map, k, v)}
  end

  def oput(_not_obj, _k, _v), do: {[], %{}}

  @doc "Property read on a direct-term object. Non-objects read as `:undefined`."
  def oget({_keys, map}, k), do: Map.get(map, key_str(k), :undefined)
  def oget(_not_obj, _k), do: :undefined

  @doc "Spread-merge b into a (Object.assign({}, a, b) shape). Returns a NEW object, b's keys last/override."
  def omerge({ak, amap}, {bk, bmap}) do
    {keys, map} =
      Enum.reduce(bk, {ak, amap}, fn k, {ks, m} ->
        if Map.has_key?(m, k), do: {ks, Map.put(m, k, bmap[k])}, else: {ks ++ [k], Map.put(m, k, bmap[k])}
      end)

    {keys, map}
  end

  def omerge(a, _non_obj), do: a

  @doc "Ordered own-keys of a direct-term object."
  def okeys({keys, _map}), do: keys
  def okeys(_), do: []

  @doc "A guest function as a DIRECTLY-HELD closure (GC'd, no table). Safe: the guest can only invoke it via
  `call/2`; no codegen path extracts and `apply`s the raw fun."
  def closure(f) when is_function(f, 1), do: {:fn, f}

  # ── closures (handles, never raw funs) ──

  @doc "Register a native closure behind a `{:fun, id}` handle."
  def fun_new(f) when is_function(f, 1) do
    id = __id()
    Process.put(:gg_funs, Map.put(Process.get(:gg_funs), id, f))
    {:fun, id}
  end

  # ── dispatch gate: the ONLY way a guest invokes anything ──

  @doc """
  Call a guest callee with a list of guest args.

  A callee is resolvable ONLY if it is a guest closure handle or a granted host
  capability handle. Anything else is a guest TypeError — NOT a host escape.
  There is no path here from guest data to an arbitrary MFA.
  """
  def call({:fn, f}, args) when is_function(f, 1), do: f.(args)

  def call({:fun, id}, args) do
    case Process.get(:gg_funs) |> Map.get(id) do
      f when is_function(f, 1) -> f.(args)
      _ -> guest_error("not a function")
    end
  end

  def call({:host, cap_id}, args), do: host_call(cap_id, args)
  def call(_not_callable, _args), do: guest_error("not a function")

  @doc """
  Invoke a granted host capability by integer id. An id that was not granted is a
  guest TypeError. The capability re-derives its authority from the run context at
  call time — it carries no ambient capability the guest could capture and reuse.
  """
  def host_call(cap_id, args) do
    ctx = Process.get(:gg_ctx)

    case ctx && Map.get(ctx.caps, cap_id) do
      %{fun: f} -> f.(args, ctx)
      _ -> guest_error("not a function")
    end
  end

  # ── arithmetic / comparison (closed, type-checked, no raw host ops on guest data) ──

  def binop(:+, a, b) when is_number(a) and is_number(b), do: a + b
  def binop(:+, a, b), do: to_str(a) <> to_str(b)
  def binop(:-, a, b) when is_number(a) and is_number(b), do: a - b
  def binop(:*, a, b) when is_number(a) and is_number(b), do: a * b
  def binop(:/, a, b) when is_number(a) and is_number(b) and b != 0, do: a / b
  def binop(:/, _a, _b), do: guest_error("division by zero")
  def binop(:<, a, b) when is_number(a) and is_number(b), do: a < b
  def binop(:>, a, b) when is_number(a) and is_number(b), do: a > b
  def binop(:"<=", a, b) when is_number(a) and is_number(b), do: a <= b
  def binop(:">=", a, b) when is_number(a) and is_number(b), do: a >= b
  def binop(:rem, a, b) when is_number(a) and is_number(b) and b != 0, do: a - b * Float.floor(a / b)
  def binop(:==, a, b), do: a === b
  def binop(:!=, a, b), do: a !== b
  def binop(_op, _a, _b), do: guest_error("bad operands")

  def truthy(false), do: false
  def truthy(:undefined), do: false
  def truthy(:null), do: false
  def truthy(0), do: false
  def truthy(+0.0), do: false
  def truthy(""), do: false
  def truthy(_), do: true

  # ── helpers ──

  # Guest property keys are always binaries. A guest never produces an atom key,
  # and we never atomize a guest string — this is the atom-domain firewall.
  defp key_str(k) when is_binary(k), do: k
  defp key_str(k) when is_number(k), do: to_str(k)
  defp key_str(true), do: "true"
  defp key_str(false), do: "false"
  defp key_str(:undefined), do: "undefined"
  defp key_str(:null), do: "null"
  defp key_str(_), do: "[object]"

  @doc "Stringify a guest value for output (spike formatting; byte-exact dtoa is a separate layer)."
  def to_str(v) when is_binary(v), do: v
  def to_str(v) when is_integer(v), do: Integer.to_string(v)

  def to_str(v) when is_float(v) do
    t = trunc(v)
    if t == v, do: Integer.to_string(t), else: Float.to_string(v)
  end

  def to_str(true), do: "true"
  def to_str(false), do: "false"
  def to_str(:undefined), do: "undefined"
  def to_str(:null), do: "null"
  def to_str({:obj, _}), do: "[object Object]"
  def to_str({:fun, _}), do: "function"
  def to_str({:host, _}), do: "function"
  def to_str(_), do: "[unknown]"

  @doc "A guest-level exception. NOT a host escape — the driver catches it as a guest error."
  def guest_error(reason), do: throw({:gg_guest_error, reason})

  @doc "Guest `return` — throws to the enclosing function-body catch. Routed through the Runtime so the
  emitted guest module references no external module (keeps the 'only Runtime' confinement invariant literal)."
  def ret(v), do: throw({:gg_return, v})

  # ── DoS primitives (emitted only for the red-team's containment tests) ──

  @doc "Unbounded CPU: tail loop, never returns. Contained by the run process timeout."
  def spin, do: spin()

  @doc "Unbounded memory: accumulate on-heap terms. Contained by the process max_heap_size{kill}."
  def mem_bomb(acc \\ []), do: mem_bomb([:lists.seq(1, 500) | acc])

  # ── host capabilities (the ENTIRE allowed side-effect surface) ──
  # Each is `fn args, ctx -> guest_value`. Tenant authority comes from ctx, fresh per call.

  @doc "cap: print — append to the run output buffer."
  def cap_print(args, _ctx) do
    s = args |> Enum.map(&to_str/1) |> Enum.join(" ")
    Process.put(:gg_out, [s | Process.get(:gg_out, [])])
    :undefined
  end

  @doc "cap: fs_read — read a path, CONFINED to the tenant root. Traversal/absolute escapes denied."
  def cap_fs_read([path | _], ctx) when is_binary(path) do
    case confine(ctx.tenant_root, path) do
      {:ok, key} -> Map.get(ctx.fs, key, :undefined)
      :denied -> :undefined
    end
  end

  def cap_fs_read(_args, _ctx), do: :undefined

  @doc "cap: fs_write — write a path, CONFINED to the tenant root."
  def cap_fs_write([path, data | _], ctx) when is_binary(path) do
    case confine(ctx.tenant_root, path) do
      {:ok, key} ->
        # In production this delegates to Nexus.Wasm.VFS (tenant-partitioned Store).
        # Here we record the write on the ctx's fs-writes log so the red-team can assert
        # exactly which keys a guest managed to write — and that traversal never escapes.
        log = Process.get(:gg_fs_writes, [])
        Process.put(:gg_fs_writes, [{key, to_str(data)} | log])
        :undefined

      :denied ->
        :undefined
    end
  end

  def cap_fs_write(_args, _ctx), do: :undefined

  @doc """
  cap: eval — parse a guest string and run it through the CONFINED INTERPRETER (not the
  compiler). Eval'd code inherits exactly the parent's grant (`ctx`), never more, and is
  confined identically (an ungranted identifier is `:undefined`). Interpreting rather than
  compiling avoids minting atoms per eval — closing the eval-driven atom-exhaustion DoS.
  A guest-level error inside eval'd code propagates as the run's guest error.
  """
  def cap_eval([src | _], ctx) when is_binary(src) do
    ast = TinyLasers.Gate.Parser.parse(src)
    TinyLasers.Gate.Interp.run(ast, ctx)
  catch
    :throw, {:gg_parse, _reason} -> guest_error("eval parse error")
  end

  def cap_eval(_args, _ctx), do: :undefined

  # Path confinement: resolve `path` under `root`, reject anything that escapes it.
  defp confine(root, path) do
    full = Path.expand(path, root)

    if full == root or String.starts_with?(full, root <> "/") do
      {:ok, full}
    else
      :denied
    end
  end
end
