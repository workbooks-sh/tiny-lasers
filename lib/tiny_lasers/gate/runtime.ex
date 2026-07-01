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

  @doc "Property read. Objects: by key. Arrays: numeric index + `length`. Non-objects: `:undefined`."
  def oget({_keys, map}, k) when is_map(map), do: Map.get(map, key_str(k), :undefined)
  def oget({:arr, list}, "length"), do: length(list) * 1.0
  def oget({:arr, list}, i) when is_number(i), do: Enum.at(list, trunc(i), :undefined)

  def oget({:arr, list}, k) when is_binary(k) do
    case Integer.parse(k) do
      {n, ""} -> Enum.at(list, n, :undefined)
      _ -> :undefined
    end
  end

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
  def okeys({keys, map}) when is_map(map), do: keys
  def okeys(_), do: []

  @doc "Functional index/key write. Arrays grow to fit; objects add the key. Returns a NEW term."
  def oput_idx({:arr, list}, i, v) when is_number(i) do
    idx = trunc(i)
    list = if idx >= length(list), do: list ++ List.duplicate(:undefined, idx - length(list) + 1), else: list
    {:arr, List.replace_at(list, idx, v)}
  end

  def oput_idx(other, k, v), do: oput(other, k, v)

  # ── array direct-term (a tagged immutable list, GC'd) ──
  @doc "Array literal from evaluated elements."
  def alit(elems) when is_list(elems), do: {:arr, elems}

  # ── regex as a CAPABILITY (backed by Elixir Regex, returns guest values, stays confined). A regex is a
  # guest-safe term `{:regex, compiled, source, flags}`; the guest can only pass it to the regex methods. ──
  @doc "Compile a guest regex. JS flags i/m/s/u/x map to Elixir opts; g is applied at match/replace time."
  def regex(source, flags) when is_binary(source) do
    opts = flags |> String.graphemes() |> Enum.filter(&(&1 in ~w(i m s u x))) |> Enum.join()

    case Regex.compile(source, opts) do
      {:ok, re} -> {:regex, re, source, flags}
      {:error, _} -> {:regex, ~r/(?!)/, source, flags}
    end
  end

  def regex(_source, _flags), do: {:regex, ~r/(?!)/, "", ""}

  defp global?({:regex, _re, _src, flags}), do: String.contains?(flags, "g")

  # string × regex methods (marked's hot surface): replace/match/split/test/exec
  def method(s, "replace", [{:regex, re, _, _} = rx, repl]) when is_binary(s) do
    Regex.replace(re, s, regex_replacement(repl), global: global?(rx))
  end

  def method(s, "replace", [pat, repl]) when is_binary(s) and is_binary(pat) do
    # string pattern: replace first occurrence
    case :binary.match(s, pat) do
      {pos, len} -> binary_part(s, 0, pos) <> to_str(apply_str_repl(repl, pat)) <> binary_part(s, pos + len, byte_size(s) - pos - len)
      :nomatch -> s
    end
  end

  def method(s, "match", [{:regex, re, _, _} = rx]) when is_binary(s) do
    if global?(rx) do
      case Regex.scan(re, s, capture: :first) |> List.flatten() do
        [] -> :undefined
        list -> {:arr, list}
      end
    else
      case Regex.run(re, s) do
        nil -> :undefined
        caps -> {:arr, Enum.map(caps, fn c -> c || :undefined end)}
      end
    end
  end

  def method(s, "split", [{:regex, re, _, _}]) when is_binary(s), do: {:arr, Regex.split(re, s)}
  def method(s, "search", [{:regex, re, _, _}]) when is_binary(s) do
    case Regex.run(re, s, return: :index) do
      [{pos, _} | _] -> pos * 1.0
      _ -> -1.0
    end
  end

  def method({:regex, re, _, _}, "test", [s | _]), do: Regex.match?(re, to_str(s))

  def method({:regex, re, _, _}, "exec", [s | _]) do
    case Regex.run(re, to_str(s)) do
      nil -> :undefined
      caps -> {:arr, Enum.map(caps, fn c -> c || :undefined end)}
    end
  end

  # a function replacement `.replace(re, fn)` — Elixir passes the whole match + captures as separate args.
  defp regex_replacement({:fn, _} = f), do: fn full, caps -> to_str(call(f, [full | (caps || [])])) end
  defp regex_replacement({:host, _} = f), do: fn full, caps -> to_str(call(f, [full | (caps || [])])) end
  defp regex_replacement(repl), do: js_repl_to_elixir(to_str(repl))

  # JS replacement templates: $1..$9 -> \1, $& -> \0, $$ -> $
  defp js_repl_to_elixir(t) do
    t
    |> String.replace("$$", "\x00DOLLAR\x00")
    |> String.replace(~r/\$(\d)/, "\\\\\\1")
    |> String.replace("$&", "\\0")
    |> String.replace("\x00DOLLAR\x00", "$")
  end

  defp apply_str_repl({:fn, _} = f, matched), do: call(f, [matched])
  defp apply_str_repl(repl, _matched), do: repl

  @doc """
  Confined METHOD dispatch: `recv.name(args)`. The dispatch table IS the builtin surface — a name that
  doesn't resolve for the receiver type is a guest `:undefined` (never a host reach). Mutating array methods
  (push/pop/…) return `{new_receiver, result}` so the lowering can rebind an identifier receiver.
  """
  def method({:arr, list}, "push", args), do: {:mut, {:arr, list ++ args}, (length(list) + length(args)) * 1.0}
  def method({:arr, list}, "pop", _), do: pop_last(list)
  def method({:arr, list}, "join", [sep | _]), do: list |> Enum.map(&to_str/1) |> Enum.join(to_str(sep))
  def method({:arr, list}, "join", _), do: list |> Enum.map(&to_str/1) |> Enum.join(",")
  def method({:arr, list}, "indexOf", [x | _]), do: (Enum.find_index(list, &(&1 === x)) || -1) * 1.0
  def method({:arr, list}, "includes", [x | _]), do: Enum.any?(list, &(&1 === x))
  def method({:arr, list}, "slice", [a | rest]), do: {:arr, slice_list(list, a, rest)}

  def method({:arr, list}, "concat", args) do
    tail = Enum.flat_map(args, fn {:arr, l} -> l; other -> [other] end)
    {:arr, list ++ tail}
  end

  def method({:arr, list}, "map", [f | _]),
    do: {:arr, Enum.with_index(list) |> Enum.map(fn {v, i} -> call(f, [v, i * 1.0]) end)}

  def method({:arr, list}, "forEach", [f | _]) do
    Enum.with_index(list) |> Enum.each(fn {v, i} -> call(f, [v, i * 1.0]) end)
    :undefined
  end

  def method({:arr, list}, "filter", [f | _]),
    do: {:arr, Enum.filter(list, fn v -> truthy(call(f, [v])) end)}

  def method(s, "charCodeAt", [i | _]) when is_binary(s) do
    case :binary.at(s, trunc(i)) do
      b when is_integer(b) -> b * 1.0
    end
  rescue
    ArgumentError -> :undefined
  end

  def method(s, "length", _) when is_binary(s), do: byte_size(s) * 1.0
  def method(s, "toUpperCase", _) when is_binary(s), do: String.upcase(s)
  def method(s, "toLowerCase", _) when is_binary(s), do: String.downcase(s)
  def method(s, "slice", [a | rest]) when is_binary(s), do: str_slice(s, a, rest)
  def method(s, "indexOf", [sub | _]) when is_binary(s) do
    case :binary.match(s, to_str(sub)) do
      {pos, _} -> pos * 1.0
      :nomatch -> -1.0
    end
  end

  def method(s, "split", [sep | _]) when is_binary(s), do: {:arr, String.split(s, to_str(sep))}
  def method({keys, map}, "hasOwnProperty", [k | _]) when is_map(map), do: Map.has_key?(map, key_str(k))

  # user object with a FUNCTION-valued property: `o.f(args)` calls the stored closure (no `this` binding yet).
  def method({_keys, map} = o, name, args) when is_map(map) do
    case oget(o, name) do
      {:fn, _} = f -> call(f, args)
      _ -> guest_error("not a function")
    end
  end

  # calling a method that doesn't resolve (incl. on `:undefined`, e.g. `os.cmd(...)`) is a guest TypeError,
  # NOT a host escape — the receiver was never a host reference.
  def method(_recv, _name, _args), do: guest_error("not a function")

  defp pop_last([]), do: {:mut, {:arr, []}, :undefined}
  defp pop_last(list), do: {:mut, {:arr, Enum.drop(list, -1)}, List.last(list)}

  defp slice_list(list, a, rest) do
    start = trunc(a)
    start = if start < 0, do: max(length(list) + start, 0), else: start
    case rest do
      [b | _] when is_number(b) -> Enum.slice(list, start, max(trunc(b) - start, 0))
      _ -> Enum.drop(list, start)
    end
  end

  defp str_slice(s, a, rest) do
    start = trunc(a)
    start = if start < 0, do: max(byte_size(s) + start, 0), else: start
    len = case rest do
      [b | _] when is_number(b) -> max(trunc(b) - start, 0)
      _ -> byte_size(s) - start
    end
    binary_part(s, min(start, byte_size(s)), min(len, byte_size(s) - min(start, byte_size(s))))
  end

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

  @doc "Guest `throw e` — a catchable guest exception carrying the guest value."
  def throw_val(v), do: throw({:gg_throw, v})

  @doc "`typeof` — a fixed set of result binaries (never guest-controlled atoms)."
  def typeof(v) when is_number(v), do: "number"
  def typeof(v) when is_binary(v), do: "string"
  def typeof(v) when is_boolean(v), do: "boolean"
  def typeof(:undefined), do: "undefined"
  def typeof({:fn, _}), do: "function"
  def typeof({:host, _}), do: "function"
  def typeof(_), do: "object"

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
