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
    Process.put(:gg_global, {[], %{}})
    Process.put(:gg_microq, :queue.new())
    :ok
  end

  # the global object (globalThis / self / window / top-level `this`) — a singleton mutable object so a UMD
  # bundle can attach its export (`(globalThis).marked = {…}`) and the host can read it back.
  def oget({:globalobj}, k), do: Process.get(:gg_global, {[], %{}}) |> elem(1) |> Map.get(key_str(k), :undefined)

  def oput({:globalobj}, k, v) do
    k = key_str(k)
    {keys, map} = Process.get(:gg_global, {[], %{}})
    keys = if Map.has_key?(map, k), do: keys, else: keys ++ [k]
    Process.put(:gg_global, {keys, Map.put(map, k, v)})
    {:globalobj}
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

  # ── boxed closure variables: JS closures share a captured MUTABLE variable BY REFERENCE (counters,
  # accumulators, the module pattern, marked's edit() helper `u = u.replace(...)`). A local that is captured
  # by a nested function AND mutated is stored in a 1-slot box so all closures see the mutation. ──
  @doc "Create a box holding an initial value."
  def box(v) do
    id = Process.get(:gg_box_next, 0)
    Process.put(:gg_box_next, id + 1)
    Process.put({:gg_box, id}, v)
    {:box, id}
  end

  @doc "Read a box."
  def box_get({:box, id}), do: Process.get({:gg_box, id}, :undefined)
  # a value bound plain but read as boxed (analysis over-approximated capture): return it as-is.
  def box_get(v), do: v
  @doc "Write a box (returns the value, JS assignment semantics)."
  def box_set({:box, id}, v), do: (Process.put({:gg_box, id}, v); v)
  def box_set(_plain, v), do: v

  @doc "Property write. A cell mutates in place (shared); an immutable object returns a NEW object."
  def oput({:cell, _} = c, k, v), do: cell_put(c, k, v)
  # Proxy set trap (target, keyString, value, receiver); falls back to writing the target.
  def oput({:proxy, t, h} = px, k, v) do
    case oget(h, "set") do
      f when elem(f, 0) in [:fn, :host] -> invoke(f, h, [t, key_str(k), v, px]); px
      _ -> oput(t, k, v); px
    end
  end
  # `regex.lastIndex = n` updates the stateful match position and RETURNS the regex, so a member-assignment
  # (`re.lastIndex = 0`) doesn't clobber `re` to an empty object — marked's emStrong rDelim loop relies on this.
  def oput({:regex, _, _, _} = r, "lastIndex", v), do: (relast_set(r, trunc(to_number(v))); r)
  def oput({:regex, _, _, _} = r, _k, _v), do: r

  # assigning a function's `.prototype` (Babel `_inherits`: `Ctor.prototype = Object.create(Super.prototype)`)
  # replaces its instance method bag, so `new Ctor()` sees the inherited chain.
  def oput({:fn, f} = fnv, "prototype", v) do
    Process.put(:gg_fnproto, Map.put(Process.get(:gg_fnproto, %{}), f, v))
    fnv
  end

  # functions are objects: `marked.parse = fn`, `marked.Lexer = ...`. Properties live in a per-function table
  # keyed by the closure identity (mutation is shared, like a cell). Returns the function.
  def oput({:fn, f} = fnv, k, v) do
    k = key_str(k)
    props = Process.get(:gg_fnprops, %{})
    {keys, map} = Map.get(props, f, {[], %{}})
    keys = if Map.has_key?(map, k), do: keys, else: keys ++ [k]
    Process.put(:gg_fnprops, Map.put(props, f, {keys, Map.put(map, k, v)}))
    fnv
  end

  def oput({keys, map}, k, v) when is_map(map) do
    k = key_str(k)
    keys = if Map.has_key?(map, k), do: keys, else: keys ++ [k]
    {keys, Map.put(map, k, v)}
  end

  # arrays can carry NAMED properties (JS arrays are objects): `this.tokens.links = {}` — stored in a props
  # map alongside the elements. Numeric keys write elements; named keys write props.
  def oput({:arr, _} = a, k, v), do: arr_put(a, k, v)
  def oput(_not_obj, _k, _v), do: {[], %{}}

  # write to an array IN PLACE: numeric key → element slot; named key → the props map. Returns the same handle.
  defp arr_put({:arr, _} = a, k, v) do
    list = al(a)
    props = ap(a)

    case arr_index(k) do
      nil ->
        aset(a, list, Map.put(props, key_str(k), v))

      idx when idx >= 0 and idx < 1_000_000 ->
        list = if idx >= length(list), do: list ++ List.duplicate(:undefined, idx - length(list) + 1), else: list
        aset(a, List.replace_at(list, idx, v), props)

      # an out-of-sane-range index (from a NaN/huge computed key) is treated as a named prop, never a giant list.
      idx ->
        aset(a, list, Map.put(props, Integer.to_string(idx), v))
    end
  end

  defp arr_index(i) when is_number(i), do: trunc(i)
  defp arr_index(k) when is_binary(k), do: (case Integer.parse(k) do {n, ""} when n >= 0 -> n; _ -> nil end)
  defp arr_index(_), do: nil

  @doc "Property read. Objects: by key. Arrays: numeric index + `length`. Non-objects: `:undefined`."
  # cell property read WITH prototype-chain fallback: ES5 classes put methods on `Ctor.prototype`; a `new
  # Ctor()` instance resolves a missing own-property from its linked prototype (see construct/2, fn_proto/1).
  def oget({:cell, _} = c, k), do: cell_oget(c, key_str(k), c)

  # resolve a cell property through the prototype chain; a `{:getter, fn}` marker is invoked with `this` = the
  # ORIGINAL receiver (so a prototype getter reading the instance's scope state works).
  defp cell_oget({:cell, id} = c, key, recv) do
    case Map.get(cell_read(c) |> elem(1), key, :__miss) do
      :__miss ->
        case Process.get({:gg_instproto, id}) do
          nil -> :undefined
          {:cell, _} = proto -> cell_oget(proto, key, recv)
          proto -> deget(oget(proto, key), recv)
        end

      {:getter, f} ->
        invoke(f, recv, [])

      v ->
        v
    end
  end

  defp deget({:getter, f}, recv), do: invoke(f, recv, [])
  defp deget(v, _recv), do: v

  # a function's `.prototype` is a stable per-function cell (ES5 method bag: `Ctor.prototype.m = fn`).
  def oget({:fn, _} = fnv, "prototype"), do: fn_proto(fnv)
  def oget({:fn, f}, k), do: (Process.get(:gg_fnprops, %{}) |> Map.get(f, {[], %{}}) |> elem(1) |> Map.get(key_str(k), :undefined))
  def oget({_keys, map}, k) when is_map(map), do: Map.get(map, key_str(k), :undefined)
  def oget({:set, _} = st, "size"), do: length(set_list(st)) * 1.0
  def oget({:map, _} = mp, "size"), do: length(map_pairs(mp)) * 1.0
  # Proxy get trap (falls back to the target). The trap receives (target, keyString, receiver).
  def oget({:proxy, t, h} = px, k) do
    case oget(h, "get") do
      f when elem(f, 0) in [:fn, :host] -> invoke(f, h, [t, key_str(k), px])
      _ -> oget(t, k)
    end
  end
  def oget({:bytes, b}, k) when k in ["length", "byteLength"], do: byte_size(b) * 1.0
  def oget({:bytes, _}, "byteOffset"), do: 0.0
  def oget({:bytes, b}, k) when is_number(k), do: (i = trunc(k); if i >= 0 and i < byte_size(b), do: :binary.at(b, i) * 1.0, else: :undefined)
  def oget({:bytes, _}, _), do: :undefined

  def oget({:arr, _} = a, k) do
    cond do
      k == "length" -> length(al(a)) * 1.0
      (idx = arr_index(k)) != nil -> Enum.at(al(a), idx, :undefined)
      true -> Map.get(ap(a), key_str(k), :undefined)
    end
  end

  # regex properties (marked's edit() helper reads `re.source` to compose patterns as strings).
  def oget({:regex, _re, src, _flags}, "source"), do: src
  def oget({:regex, _re, _src, flags}, "flags"), do: flags
  def oget({:regex, _re, _src, flags}, "global"), do: String.contains?(flags, "g")
  def oget({:regex, _re, _src, flags}, "ignoreCase"), do: String.contains?(flags, "i")
  def oget({:regex, _re, _src, flags}, "multiline"), do: String.contains?(flags, "m")
  def oget({:regex, _, _, _} = r, "lastIndex"), do: relast_get(r) * 1.0

  # string properties: `.length` and index access `s[i]` (JS returns a 1-char string).
  # string length/index are by CODE POINT (JS string semantics), with an all-ASCII fast path (bytes==code
  # points → the O(1) byte op is already correct). acorn's unicode identifier tokenizer needs this.
  def oget(s, "length") when is_binary(s), do: str_len(s) * 1.0
  def oget(s, i) when is_binary(s) and is_number(i) do
    idx = trunc(i)
    cond do
      idx < 0 -> :undefined
      ascii?(s) -> (if idx < byte_size(s), do: binary_part(s, idx, 1), else: :undefined)
      true -> (case Enum.at(String.to_charlist(s), idx) do nil -> :undefined; cp -> List.to_string([cp]) end)
    end
  end

  @doc "global namespace/property reads (Math.PI, Number.MAX_VALUE, Object.prototype)."
  def oget({:global, "Math"}, "PI"), do: :math.pi()
  def oget({:global, "Number"}, "MAX_VALUE"), do: 1.7976931348623157e308
  def oget({:global, "Number"}, "MIN_VALUE"), do: 5.0e-324
  def oget({:global, "Number"}, "MAX_SAFE_INTEGER"), do: 9_007_199_254_740_991.0
  # the Object static methods callable as first-class values (esbuild aliases `var f = Object.defineProperty`).
  @obj_statics ~w(keys values entries getOwnPropertyNames getOwnPropertyDescriptor assign create freeze
                  defineProperty defineProperties getPrototypeOf setPrototypeOf fromEntries)

  # well-known symbols: stable, shared identities (Symbol.iterator etc. must compare equal across reads).
  def oget({:global, "Symbol"}, k) when k in ["iterator", "asyncIterator", "hasInstance", "toPrimitive", "toStringTag"],
    do: {:symbol, "@@" <> k, k}
  def oget({:global, "Symbol"}, "for"), do: closure(fn _this, args -> (d = to_str(List.first(args) || ""); {:symbol, "for:" <> d, d}) end)
  def oget({:global, name}, "prototype"), do: {:proto, name}
  # a global static method read as a first-class value: return a closure bound to the method dispatcher so
  # `var f = Object.defineProperty; f(o,k,d)` works (esbuild wrapper pattern). Gated to known statics so
  # `typeof Object.somethingElse` stays "undefined".
  def oget({:global, "Object"}, k) when is_binary(k) and k not in ["prototype"] do
    if k in @obj_statics, do: closure(fn _this, args -> object_static(k, args) end), else: :undefined
  end
  def oget({:global, "Promise"}, k) when k in ["resolve", "reject", "all", "allSettled", "race"],
    do: closure(fn _this, args -> promise_static(k, args) end)
  def oget({:global, "Reflect"}, k) when k in ["get", "set", "has", "ownKeys", "deleteProperty", "getPrototypeOf", "defineProperty", "construct", "apply"],
    do: closure(fn _this, args -> reflect_static(k, args) end)
  def oget({:global, _}, _), do: :undefined

  def oget({:proto, _}, "toString"), do: {:protom, :tostring}
  def oget({:proto, _}, "hasOwnProperty"), do: {:protom, :hasown}
  def oget({:proto, _}, _), do: :undefined

  def oget(_not_obj, _k), do: :undefined

  @doc "Spread-merge b's own keys into cell a in order (`{...a, ...b}` / Object.assign). Mutates & returns a."
  def omerge({:cell, _} = a, b) do
    Enum.reduce(spread_keys(b), a, fn k, acc -> oput(acc, k, oget(b, k)) end)
  end

  # own-enumerable keys of a spread source; non-objects (undefined/null/number/string) contribute nothing.
  defp spread_keys({:cell, _} = c), do: okeys(c)
  defp spread_keys({keys, map}) when is_map(map), do: keys
  defp spread_keys({:globalobj}), do: okeys({:globalobj})
  defp spread_keys(_), do: []

  def omerge({:cell, _} = c, b), do: omerge(cell_read(c), b)
  def omerge(a, {:cell, _} = c), do: omerge(a, cell_read(c))
  def omerge(a, _non_obj), do: a

  @doc "Ordered own-keys of a direct-term object."
  def okeys({keys, map}) when is_map(map), do: keys
  def okeys({:cell, _} = c), do: elem(cell_read(c), 0)
  def okeys({:globalobj}), do: Process.get(:gg_global, {[], %{}}) |> elem(0)
  # Proxy ownKeys trap → the enumerable keys (falls back to the target's).
  def okeys({:proxy, t, h}) do
    case oget(h, "ownKeys") do
      f when elem(f, 0) in [:fn, :host] -> arr_to_list(invoke(f, h, [t]))
      _ -> okeys(t)
    end
  end
  def okeys(_), do: []

  # ── MUTABLE CELL objects (stateful instances: things with methods, e.g. a Lexer/Parser). Few and long-
  # lived, so a per-run process-dict table is fine (the GC concern is the transient object FLOOD, which stays
  # immutable {keys,map}). A cell mutates IN PLACE, so `this.x = v` and shared-object aliasing work. The guest
  # holds only the integer id inside {:cell, id} — still no atom/pid/fun crosses the boundary. ──
  @doc "Allocate a mutable-cell object from ordered {key, value} pairs. Returns `{:cell, id}`."
  def cell_new(pairs) do
    id = cell_id()
    {keys, map} =
      Enum.reduce(pairs, {[], %{}}, fn {k, v}, {ks, m} ->
        k = key_str(k)
        if Map.has_key?(m, k), do: {ks, Map.put(m, k, v)}, else: {ks ++ [k], Map.put(m, k, v)}
      end)

    Process.put(:gg_cells, Map.put(Process.get(:gg_cells, %{}), id, {keys, map}))
    {:cell, id}
  end

  defp cell_id do
    n = Process.get(:gg_cell_next, 0)
    Process.put(:gg_cell_next, n + 1)
    n
  end

  defp cell_read({:cell, id}), do: Process.get(:gg_cells, %{}) |> Map.get(id, {[], %{}})

  @doc "In-place property write on a cell. Returns the SAME handle (mutation is shared)."
  def cell_put({:cell, id} = c, k, v) do
    k = key_str(k)
    {keys, map} = cell_read(c)
    keys = if Map.has_key?(map, k), do: keys, else: keys ++ [k]
    Process.put(:gg_cells, Map.put(Process.get(:gg_cells, %{}), id, {keys, Map.put(map, k, v)}))
    c
  end

  @doc "Functional index/key write. Arrays grow to fit; objects add the key. Returns a NEW term."
  def oput_idx({:arr, _} = a, i, v), do: arr_put(a, i, v)
  def oput_idx({:cell, _} = c, k, v), do: cell_put(c, k, v)
  def oput_idx({:globalobj}, k, v), do: oput({:globalobj}, k, v)
  def oput_idx(other, k, v), do: oput(other, k, v)

  @doc "method call on the global object (globalThis.marked(md))."
  def method({:globalobj} = g, name, args) do
    case oget(g, name) do
      {:fn, _} = f -> invoke(f, g, args)
      _ -> if System.get_env("GAPLOG"), do: IO.puts(:stderr, "GAP globalmeth #{inspect(name)}"); guest_error("not a function")
    end
  end

  # ── arrays are MUTABLE REFERENCES (JS array semantics): `{:arr, id}` indexes a per-run table holding
  # `{elements, named_props}`. push/pop/… mutate in place so aliases + params share the mutation (marked's
  # `blockTokens(src, this.tokens)` pushes into the caller's array). Non-mutating ops return a NEW array. ──
  @doc "Allocate a mutable array."
  def avec(list, props \\ %{}) when is_list(list) do
    id = Process.get(:gg_vec_next, 0)
    Process.put(:gg_vec_next, id + 1)
    Process.put({:gg_vec, id}, {list, props})
    {:arr, id}
  end

  @doc "A rest parameter's array: the args from index `i` onward. (Keeps Enum.drop out of emitted guest code.)"
  def args_rest(args, i) when is_list(args), do: avec(Enum.drop(args, i))

  @doc "Public accessor: a guest array's element list (for host capability bridges reading guest arrays)."
  def arr_to_list({:arr, _} = a), do: al(a)
  def arr_to_list(_), do: []

  defp bytes_bin({:bytes, b}), do: b
  defp bytes_bin(b) when is_binary(b), do: b
  defp bytes_bin(_), do: ""

  @doc "Granted `__host(op, params)` capability bridge → dispatches to a host module (e.g. the rollup
  wasm parser via HostRollup) and returns the result as a guest object. Confined: the guest holds only the
  integer capability handle; the host work (running wasm) happens here, never referenced in guest code."
  def host_rollup_bridge([op, params | _], _ctx) do
    plist = arr_to_list(params)
    case TinyLasers.Wasm.HostRollup.call(to_string(op), plist) do
      m when is_map(m) -> cell_new(Enum.map(m, fn {k, v} -> {to_string(k), v} end))
      other -> other
    end
  end

  defp al({:arr, id}), do: Process.get({:gg_vec, id}, {[], %{}}) |> elem(0)
  defp ap({:arr, id}), do: Process.get({:gg_vec, id}, {[], %{}}) |> elem(1)
  defp aset({:arr, id} = a, list, props), do: (Process.put({:gg_vec, id}, {list, props}); a)
  defp aset_l({:arr, _} = a, list), do: aset(a, list, ap(a))

  # overwrite `dst` from index `off` with `src` elements (typed-array .set), keeping the rest.
  defp ta_set(dst, src, off) do
    dst = List.to_tuple(dst)
    Enum.reduce(Enum.with_index(src), dst, fn {v, i}, acc ->
      idx = off + i
      if idx >= 0 and idx < tuple_size(acc), do: put_elem(acc, idx, v), else: acc
    end)
    |> Tuple.to_list()
  end

  @doc "Array literal from evaluated elements."
  def alit(elems) when is_list(elems), do: avec(elems)

  @doc "Array literal WITH spread elements: parts are `{:one, v}` | `{:spread, iterable}`."
  def aspread(parts) do
    avec(Enum.flat_map(parts, fn {:spread, v} -> iter(v); {:one, v} -> [v] end))
  end

  @doc "Flatten call arguments with spread elements into a plain args list (`f(...xs, y)`)."
  def spread_args(parts), do: Enum.flat_map(parts, fn {:spread, v} -> iter(v); {:one, v} -> [v] end)

  @doc "Array rest binding `[a, ...rest] = arr` — the elements from index `from` onward as a new array."
  def arest({:arr, _} = a, from), do: avec(Enum.drop(al(a), from))
  def arest(_other, _from), do: avec([])

  @doc "Object rest binding `{a, ...rest} = o` — a new object of `o`'s own keys except the destructured ones."
  def orest(o, taken) do
    keep = okeys(o) |> Enum.reject(&(&1 in taken))
    cell_new(Enum.map(keep, fn k -> {k, oget(o, k)} end))
  end

  # ── regex as a CAPABILITY (backed by Elixir Regex, returns guest values, stays confined). A regex is a
  # guest-safe term `{:regex, compiled, source, flags}`; the guest can only pass it to the regex methods. ──
  @doc "Compile a guest regex. JS flags i/m/s/u/x map to Elixir opts; g is applied at match/replace time."
  def regex(source, flags) when is_binary(source) do
    opts = flags |> String.graphemes() |> Enum.filter(&(&1 in ~w(i m s u x))) |> Enum.join()

    # keep `source` (the JS-visible .source) as-is, but translate JS-only regex syntax before PCRE compile.
    case Regex.compile(js_re_to_pcre(source), opts) do
      {:ok, re} -> {:regex, re, source, flags}
      {:error, _} -> {:regex, ~r/(?!)/, source, flags}
    end
  end

  # `[^]` is JS for "any char incl. newline" but is an empty (invalid) class in PCRE — rewrite to `[\s\S]`.
  # acorn's skipWhiteSpace `/\/\*[^]*?\*\//` relies on it.
  defp js_re_to_pcre(src), do: String.replace(src, "[^]", "[\\s\\S]")

  def regex(_source, _flags), do: {:regex, ~r/(?!)/, "", ""}

  defp global?({:regex, _re, _src, flags}), do: String.contains?(flags, "g")

  # string × regex methods (marked's hot surface): replace/match/split/test/exec
  # function replacement: Elixir's Regex.replace passes captures as SEPARATE args (variable arity), so drive
  # it with Regex.scan and splice manually — the JS callback gets (fullMatch, ...groups).
  def method(s, "replace", [{:regex, re, _, _} = rx, f]) when is_binary(s) and (elem(f, 0) == :fn or elem(f, 0) == :host) do
    idxs = Regex.scan(re, s, return: :index)
    idxs = if global?(rx), do: idxs, else: Enum.take(idxs, 1)

    {chunks, last} =
      Enum.reduce(idxs, {[], 0}, fn caps, {acc, pos} ->
        [{ms, ml} | _] = caps
        [full | groups] = Enum.map(caps, fn {i, l} -> if i < 0, do: :undefined, else: binary_part(s, i, l) end)
        repl = to_str(call(f, [full | groups] ++ [ms * 1.0, s]))
        {[acc, binary_part(s, pos, ms - pos), repl], ms + ml}
      end)

    IO.iodata_to_binary([chunks, binary_part(s, last, byte_size(s) - last)])
  end

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
        list -> avec(list)
      end
    else
      case Regex.run(re, s) do
        nil -> :undefined
        caps -> avec(Enum.map(caps, fn c -> c || :undefined end))
      end
    end
  end

  def method(s, "split", [{:regex, re, _, _}]) when is_binary(s), do: avec(Regex.split(re, s))
  def method(s, "search", [{:regex, re, _, _}]) when is_binary(s) do
    case Regex.run(re, s, return: :index) do
      [{pos, _} | _] -> pos * 1.0
      _ -> -1.0
    end
  end

  # `lastIndex` state is per-regex-term (structural key), so a global/sticky regex resumes across exec/test
  # calls (marked's reflinkSearch mask loop + emStrong rDelim loop rely on this).
  defp relast_get(r), do: Process.get({:gg_relast, r}, 0)
  defp relast_set(r, n), do: Process.put({:gg_relast, r}, max(n, 0))

  def method({:regex, re, _src, flags} = r, "test", [s | _]) do
    str = to_str(s)
    global = String.contains?(flags, "g") or String.contains?(flags, "y")
    start = if global, do: relast_get(r), else: 0

    case start <= byte_size(str) && Regex.run(re, str, offset: start, return: :index) do
      [{ms, ml} | _] -> (if global, do: relast_set(r, ms + ml)); true
      _ -> (if global, do: relast_set(r, 0)); false
    end
  end

  # JS exec: stateful for global/sticky regexes (resumes from lastIndex, advances it, resets on miss). The
  # result array carries `.index`/`.input`. Returns `:null` on no match (marked's loops check `!= null`).
  def method({:regex, re, _src, flags} = r, "exec", [s | _]) do
    str = to_str(s)
    global = String.contains?(flags, "g") or String.contains?(flags, "y")
    start = if global, do: relast_get(r), else: 0

    case start <= byte_size(str) && Regex.run(re, str, offset: start, return: :index) do
      [{ms, ml} | _] = idxs ->
        caps = Enum.map(idxs, fn {i, l} -> if i < 0, do: :undefined, else: binary_part(str, i, l) end)
        if global, do: relast_set(r, ms + ml)
        avec(caps, %{"index" => ms * 1.0, "input" => str})

      _ ->
        (if global, do: relast_set(r, 0)); :null
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
  # Set
  def method({:set, id} = st, "add", [v | _]), do: (Process.put({:gg_set, id}, Enum.uniq(set_list(st) ++ [v])); st)
  def method({:set, _} = st, "has", [v | _]), do: Enum.any?(set_list(st), &(&1 === v))
  def method({:set, id} = st, "delete", [v | _]), do: (had = method(st, "has", [v]); Process.put({:gg_set, id}, Enum.reject(set_list(st), &(&1 === v))); had)
  def method({:set, id}, "clear", _), do: (Process.put({:gg_set, id}, []); :undefined)
  def method({:set, _} = st, "forEach", [f | _]), do: (Enum.each(set_list(st), fn v -> call(f, [v, v]) end); :undefined)
  # Map
  def method({:map, _} = mp, "get", [k | _]), do: (case List.keyfind(map_pairs(mp), k, 0) do {_, v} -> v; _ -> :undefined end)
  def method({:map, id} = mp, "set", [k, v | _]), do: (Process.put({:gg_map, id}, List.keystore(map_pairs(mp), k, 0, {k, v})); mp)
  def method({:map, _} = mp, "has", [k | _]), do: List.keymember?(map_pairs(mp), k, 0)
  def method({:map, id} = mp, "delete", [k | _]), do: (had = method(mp, "has", [k]); Process.put({:gg_map, id}, List.keydelete(map_pairs(mp), k, 0)); had)
  def method({:map, id}, "clear", _), do: (Process.put({:gg_map, id}, []); :undefined)
  def method({:map, _} = mp, "forEach", [f | _]), do: (Enum.each(map_pairs(mp), fn {k, v} -> call(f, [v, k]) end); :undefined)
  def method({:map, _} = mp, "keys", _), do: avec(Enum.map(map_pairs(mp), &elem(&1, 0)))
  def method({:map, _} = mp, "values", _), do: avec(Enum.map(map_pairs(mp), &elem(&1, 1)))
  def method({:map, _} = mp, "entries", _), do: avec(Enum.map(map_pairs(mp), fn {k, v} -> avec([k, v]) end))

  # ── Promises: synchronous/eager model. No event loop — resolve/reject settle immediately and .then runs its
  # callback right away on an already-settled promise (a pending promise queues callbacks, run on settle). This
  # covers rollup's load-time Promise.resolve().then(...) deferral idioms; strict microtask ordering is a later
  # rung if byte-identical output needs it.
  def method({:promise, _} = p, "then", [onF | rest]), do: prom_then(p, onF, List.first(rest) || :undefined)
  def method({:promise, _} = p, "catch", [onR | _]), do: prom_then(p, :undefined, onR)
  def method({:promise, _} = p, "finally", [onFin | _]) do
    f = closure(fn _t, a -> (invoke_if(onFin, []); List.first(a) || :undefined) end)
    r = closure(fn _t, a -> (invoke_if(onFin, []); throw_val(List.first(a) || :undefined)) end)
    prom_then(p, f, r)
  end
  # ── all array methods on a mutable reference: mutating ops write the table in place (aliases share); pure
  # ops return a NEW array. ──
  def method({:arr, _} = a, name, args) do
    list = al(a)
    a0 = List.first(args)
    arr_method(a, list, name, a0, args)
  end

  def method(s, "charCodeAt", [i | _]) when is_binary(s) do
    idx = trunc(i)
    cond do
      idx < 0 -> :undefined
      ascii?(s) -> (if idx < byte_size(s), do: :binary.at(s, idx) * 1.0, else: :undefined)
      true -> (case Enum.at(String.to_charlist(s), idx) do nil -> :undefined; cp -> cp * 1.0 end)
    end
  end

  def method(s, "length", _) when is_binary(s), do: str_len(s) * 1.0
  def method(s, "toUpperCase", _) when is_binary(s), do: String.upcase(s)
  def method(s, "toLowerCase", _) when is_binary(s), do: String.downcase(s)
  def method(s, "slice", [a | rest]) when is_binary(s), do: str_slice(s, a, rest)
  def method(s, "indexOf", [sub | rest]) when is_binary(s) do
    # honor the optional fromIndex (JS `str.indexOf(sub, from)`); acorn's regex-flag validation relies on it.
    from = case rest do [f | _] when is_number(f) -> min(max(trunc(f), 0), byte_size(s)); _ -> 0 end
    scope = binary_part(s, from, byte_size(s) - from)

    case :binary.match(scope, to_str(sub)) do
      {pos, _} -> (pos + from) * 1.0
      :nomatch -> -1.0
    end
  end

  def method(s, "split", [sep | _]) when is_binary(s), do: avec(String.split(s, to_str(sep)))
  def method(s, "trim", _) when is_binary(s), do: String.trim(s)
  def method(s, "trimStart", _) when is_binary(s), do: String.trim_leading(s)
  def method(s, "trimLeft", _) when is_binary(s), do: String.trim_leading(s)
  def method(s, "trimRight", _) when is_binary(s), do: String.trim_trailing(s)
  def method(s, "trimEnd", _) when is_binary(s), do: String.trim_trailing(s)
  def method(s, "substring", [a | rest]) when is_binary(s), do: str_substring(s, a, rest)
  def method(s, "substr", [a | rest]) when is_binary(s), do: str_slice(s, a, (case rest do [l | _] -> [a + l]; _ -> [] end))
  def method(s, "charAt", [i | _]) when is_binary(s), do: (if oget(s, i * 1) == :undefined, do: "", else: oget(s, i * 1))
  def method(s, "charAt", _) when is_binary(s), do: binary_part(s, 0, min(1, byte_size(s)))
  def method(s, "at", [i | _]) when is_binary(s) do
    idx = trunc(i)
    idx = if idx < 0, do: byte_size(s) + idx, else: idx
    if idx >= 0 and idx < byte_size(s), do: binary_part(s, idx, 1), else: :undefined
  end
  def method(s, "repeat", [n | _]) when is_binary(s) and is_number(n), do: String.duplicate(s, min(max(trunc(n), 0), 1_000_000))
  def method(s, "repeat", _) when is_binary(s), do: ""
  def method(s, "padStart", [len | rest]) when is_binary(s), do: str_pad(s, len, rest, :leading)
  def method(s, "padEnd", [len | rest]) when is_binary(s), do: str_pad(s, len, rest, :trailing)
  def method(s, "startsWith", [p | _]) when is_binary(s), do: String.starts_with?(s, to_str(p))
  def method(s, "endsWith", [p | _]) when is_binary(s), do: String.ends_with?(s, to_str(p))
  def method(s, "includes", [p | _]) when is_binary(s), do: String.contains?(s, to_str(p))
  def method(s, "replaceAll", [p, r | _]) when is_binary(s) and is_binary(p), do: String.replace(s, p, to_str(r))
  def method(s, "concat", args) when is_binary(s), do: s <> (args |> Enum.map(&to_str/1) |> Enum.join())
  def method(s, "lastIndexOf", [sub | _]) when is_binary(s) do
    parts = :binary.matches(s, to_str(sub))
    case List.last(parts) do {pos, _} -> pos * 1.0; _ -> -1.0 end
  end
  def method(s, m, _) when is_binary(s) and m in ["toString", "valueOf", "normalize"], do: s
  def method(s, "codePointAt", [i | _]) when is_binary(s) do
    case oget(s, i * 1) do c when is_binary(c) -> (:binary.first(c)) * 1.0; _ -> :undefined end
  end

  # array-method dispatch on the deref'd `list`; mutating cases `aset_l(a, …)` write back in place.
  defp arr_flat(list), do: Enum.flat_map(list, fn x -> if match?({:arr, _}, x), do: al(x), else: [x] end)

  defp arr_method(a, list, name, a0, args) do
    case name do
      "push" -> aset_l(a, list ++ args); (length(list) + length(args)) * 1.0
      "pop" -> case list do
                 [] -> :undefined
                 _ -> {init, [last]} = Enum.split(list, -1); aset_l(a, init); last
               end
      "shift" -> case list do [] -> :undefined; [h | t] -> aset_l(a, t); h end
      "unshift" -> aset_l(a, args ++ list); (length(list) + length(args)) * 1.0
      "join" -> sep = if a0, do: to_str(a0), else: ","; list |> Enum.map(fn v -> if v in [:undefined, :null], do: "", else: to_str(v) end) |> Enum.join(sep)
      "indexOf" -> (Enum.find_index(list, &(&1 === a0)) || -1) * 1.0
      "lastIndexOf" -> idx = list |> Enum.reverse() |> Enum.find_index(&(&1 === a0)); if idx, do: (length(list) - 1 - idx) * 1.0, else: -1.0
      "includes" -> Enum.any?(list, &(&1 === a0))
      "slice" -> avec(slice_list(list, a0 || 0.0, Enum.drop(args, 1)))
      # typed-array subarray: a view expressed as a fresh backing array (sufficient for read/decode use).
      "subarray" -> avec(slice_list(list, a0 || 0.0, Enum.drop(args, 1)))
      # typed-array bulk set: write src elements starting at offset.
      "set" -> src = (case a0 do {:arr,_} -> al(a0); _ -> [] end); off = trunc(to_number(Enum.at(args, 1) || 0.0)); aset_l(a, ta_set(list, src, off)); :undefined
      "concat" -> avec(list ++ arr_flat(args))
      "flat" -> avec(arr_flat(list))
      "map" -> avec(Enum.with_index(list) |> Enum.map(fn {v, i} -> call(a0, [v, i * 1.0, a]) end))
      "filter" -> avec(Enum.filter(list, fn v -> truthy(call(a0, [v])) end))
      "forEach" -> Enum.with_index(list) |> Enum.each(fn {v, i} -> call(a0, [v, i * 1.0, a]) end); :undefined
      "find" -> Enum.find(list, :undefined, fn v -> truthy(call(a0, [v])) end)
      "findIndex" -> (Enum.find_index(list, fn v -> truthy(call(a0, [v])) end) || -1) * 1.0
      "some" -> Enum.any?(list, fn v -> truthy(call(a0, [v])) end)
      "every" -> Enum.all?(list, fn v -> truthy(call(a0, [v])) end)
      "reduce" -> arr_reduce(list, args)
      "reduceRight" -> Enum.reduce(Enum.reverse(list), (if length(args) > 1, do: Enum.at(args, 1), else: :undefined), fn v, acc -> call(a0, [acc, v]) end)
      "sort" -> cmp = if match?({:fn, _}, a0), do: a0, else: nil
                sorted = if cmp, do: Enum.sort(list, fn x, y -> num(call(cmp, [x, y])) <= 0 end), else: Enum.sort_by(list, &to_str/1)
                aset_l(a, sorted); a
      "reverse" -> aset_l(a, Enum.reverse(list)); a
      "fill" -> aset_l(a, Enum.map(list, fn _ -> a0 end)); a
      "at" -> idx = trunc(num(a0)); idx = if idx < 0, do: length(list) + idx, else: idx; Enum.at(list, idx, :undefined)
      "splice" -> arr_splice(a, list, args)
      # iterator methods — returned as arrays (for-of over an array works; strict iterator identity unneeded).
      "entries" -> avec(list |> Enum.with_index() |> Enum.map(fn {v, i} -> avec([i * 1.0, v]) end))
      "keys" -> avec(Enum.map(0..max(length(list) - 1, -1)//1, &(&1 * 1.0)))
      "values" -> avec(list)
      m when m in ["toString", "valueOf"] -> list |> Enum.map(&to_str/1) |> Enum.join(",")
      _ ->
        # a function-valued named property (rare): call it; else it is not a function.
        case Map.get(ap(a), name, :undefined) do
          {:fn, _} = f -> invoke(f, a, args)
          _ -> if System.get_env("GAPLOG"), do: IO.puts(:stderr, "GAP arrmeth #{inspect(name)}"); guest_error("not a function")
        end
    end
  end

  defp arr_reduce(list, [f | rest]) do
    case rest do
      [init | _] -> Enum.reduce(Enum.with_index(list), init, fn {v, i}, acc -> call(f, [acc, v, i * 1.0]) end)
      [] ->
        case list do
          [] -> guest_error("reduce of empty array with no initial value")
          [h | t] -> Enum.reduce(Enum.with_index(t, 1), h, fn {v, i}, acc -> call(f, [acc, v, i * 1.0]) end)
        end
    end
  end

  # arr.splice(start, deleteCount, ...items) — mutate in place, return the removed elements as a new array.
  defp arr_splice(a, list, args) do
    len = length(list)
    start = trunc(num(List.first(args) || 0.0))
    start = if start < 0, do: max(len + start, 0), else: min(start, len)
    dcount = case args do [_, d | _] -> max(trunc(num(d)), 0); _ -> len - start end
    items = Enum.drop(args, 2)
    removed = Enum.slice(list, start, dcount)
    aset_l(a, Enum.take(list, start) ++ items ++ Enum.drop(list, start + dcount))
    avec(removed)
  end

  def method({keys, map}, "hasOwnProperty", [k | _]) when is_map(map), do: Map.has_key?(map, key_str(k))

  # user object with a FUNCTION-valued property: `o.f(args)` calls the stored closure (no `this` binding yet).
  def method({_keys, map} = o, name, args) when is_map(map) do
    case oget(o, name) do
      {:fn, _} = f -> invoke(f, o, args)
      _ -> if System.get_env("GAPLOG"), do: IO.puts(:stderr, "GAP objmeth #{inspect(name)}"); guest_error("not a function")
    end
  end

  # a mutable-cell instance: `hasOwnProperty`, else a function-valued property is a method with this=the cell.
  def method({:cell, _} = c, "hasOwnProperty", [k | _]), do: Map.has_key?(cell_read(c) |> elem(1), key_str(k))

  def method({:cell, _} = c, name, args) do
    case oget(c, name) do
      {:fn, _} = f -> invoke(f, c, args)
      _ ->
        if System.get_env("GAPLOG"), do: IO.puts(:stderr, "GAP cellmeth #{inspect(name)} keys=#{inspect(okeys(c)) |> String.slice(0, 90)}")
        if System.get_env("GAPSOFT"), do: :undefined, else: guest_error("not a function")
    end
  end

  # ── Node Buffer: a raw byte buffer as {:bytes, binary}. Buffer.from(str[, enc]) / Buffer.from(byteArray).
  # Guest strings are already UTF-8 binaries, so utf-8 is identity; base64 decodes. Used by rollup's xxhash
  # (Buffer.from(id).toString("base64")) and the wasm-bridge base64 paths.
  def method({:global, "Buffer"}, "from", [data | rest]) do
    enc = List.first(rest)
    cond do
      enc == "base64" and is_binary(data) -> {:bytes, (case Base.decode64(data) do {:ok, b} -> b; _ -> "" end)}
      is_binary(data) -> {:bytes, data}
      match?({:bytes, _}, data) -> data
      match?({:arr, _}, data) -> {:bytes, al(data) |> Enum.map(&(trunc(to_number(&1)) |> Bitwise.band(0xFF))) |> :erlang.list_to_binary()}
      true -> {:bytes, ""}
    end
  end
  def method({:global, "Buffer"}, name, args) when name in ["alloc", "allocUnsafe"], do: (n = trunc(to_number(List.first(args) || 0.0)); {:bytes, :binary.copy(<<0>>, n)})
  def method({:global, "Buffer"}, "concat", [{:arr, _} = a | _]), do: {:bytes, al(a) |> Enum.map(fn {:bytes, b} -> b; b when is_binary(b) -> b; _ -> "" end) |> IO.iodata_to_binary()}
  def method({:global, "Buffer"}, "isBuffer", [x | _]), do: match?({:bytes, _}, x)

  # methods on a byte buffer value.
  def method({:bytes, b}, "toString", rest), do: (case List.first(rest) do "base64" -> Base.encode64(b); "hex" -> Base.encode16(b, case: :lower); _ -> b end)
  def method({:bytes, _} = bytes, "subarray", [a0 | rest]), do: (b = bytes_bin(bytes); s = trunc(to_number(a0)); e = (case rest do [e0 | _] -> trunc(to_number(e0)); _ -> byte_size(b) end); {:bytes, binary_part(b, s, max(min(e, byte_size(b)) - s, 0))})
  def method({:bytes, _} = bytes, "slice", args), do: method(bytes, "subarray", args)

  # a method call on a Proxy: get the (trapped) property, invoke with this=proxy.
  def method({:proxy, _, _} = px, name, args), do: invoke(oget(px, name), px, args)

  # Reflect: the default-passthrough operations Proxy handlers delegate to.
  def method({:global, "Reflect"}, name, args), do: reflect_static(name, args)

  # ── global namespaces (Object/Array/Math/JSON/Number/String) — static methods + a few properties ──
  def method({:global, "Object"}, name, args), do: object_static(name, args)
  def method({:global, "Promise"}, name, args), do: promise_static(name, args)
  def method({:global, "Array"}, name, args), do: array_static(name, args)
  def method({:global, "Math"}, name, args), do: math_static(name, args)
  def method({:global, "JSON"}, "stringify", [v | rest]), do: json_stringify(v, rest)
  def method({:global, "JSON"}, "parse", [s | _]) when is_binary(s), do: json_parse(s)
  def method({:global, "Number"}, "isInteger", [x | _]), do: is_number(x) and trunc(x) == x
  def method({:global, "Number"}, "isNaN", [x | _]), do: not is_number(x)
  def method({:global, "Number"}, "isFinite", [x | _]), do: is_number(x)
  def method({:global, "Number"}, "parseFloat", [x | _]), do: to_number(x)
  def method({:global, "String"}, "fromCharCode", codes), do: codes |> Enum.map(&<<trunc(&1)::utf8>>) |> Enum.join()

  defp object_static("keys", [o | _]), do: avec(okeys(o))
  defp object_static("values", [o | _]), do: avec(Enum.map(okeys(o), &oget(o, &1)))
  defp object_static("entries", [o | _]), do: avec(Enum.map(okeys(o), fn k -> avec([k, oget(o, k)]) end))
  defp object_static("getOwnPropertyNames", [o | _]), do: avec(okeys(o))
  defp object_static("assign", [target | sources]), do: Enum.reduce(sources, target, fn s, t -> Enum.reduce(okeys(s), t, fn k, acc -> oput(acc, k, oget(s, k)) end) end)
  # Object.create(proto): a fresh object whose prototype chain is `proto` (Babel `_inherits`).
  defp object_static("create", [proto | _]) when proto != :undefined and proto != :null do
    c = cell_new([])
    {:cell, id} = c
    Process.put({:gg_instproto, id}, proto)
    c
  end

  defp object_static("create", _), do: cell_new([])
  defp object_static("freeze", [o | _]), do: o
  # defineProperty: set `value` if the descriptor carries one (Babel `_createClass` method attach); a
  # value-less descriptor (`{writable:false}` on `Ctor.prototype`) must NOT clobber the existing property.
  defp object_static("defineProperty", [o, k, desc | _]) do
    cond do
      has_own(desc, "value") -> oput(o, to_str(k), oget(desc, "value"))
      has_own(desc, "get") -> oput(o, to_str(k), {:getter, oget(desc, "get")})
      true -> o
    end
  end
  # Object.defineProperties(o, { k1: desc1, k2: desc2, … }) — acorn installs its getter properties this way.
  defp object_static("defineProperties", [o, descs | _]) do
    Enum.each(okeys(descs), fn k -> object_static("defineProperty", [o, k, oget(descs, k)]) end)
    o
  end

  # Reflect operations (Proxy default passthrough). Array/apply args come as a guest array.
  defp reflect_static("get", [t, k | _]), do: oget(t, k)
  defp reflect_static("set", [t, k, v | _]), do: (oput(t, k, v); true)
  defp reflect_static("has", [t, k | _]), do: has_own(t, k)
  defp reflect_static("ownKeys", [t | _]), do: avec(okeys(t))
  defp reflect_static("deleteProperty", [t, k | _]), do: (odelete(t, k); true)
  defp reflect_static("getPrototypeOf", _), do: :null
  defp reflect_static("defineProperty", [t, k, d | _]), do: (object_static("defineProperty", [t, k, d]); true)
  defp reflect_static("construct", [ctor, a | _]), do: construct(ctor, arr_to_list(a))
  defp reflect_static("apply", [f, this, a | _]), do: invoke(f, this, arr_to_list(a))
  defp reflect_static(_, _), do: :undefined

  # delete a property from a cell (Reflect.deleteProperty / `delete o.k`).
  defp odelete({:cell, id} = c, k) do
    {keys, map} = cell_read(c)
    ks = key_str(k)
    Process.put(:gg_cells, Map.put(Process.get(:gg_cells, %{}), id, {List.delete(keys, ks), Map.delete(map, ks)}))
    :undefined
  end
  defp odelete(_, _), do: :undefined

  defp object_static("getPrototypeOf", _), do: :undefined
  defp object_static("setPrototypeOf", [o | _]), do: o
  # getOwnPropertyDescriptor(o, k): a data descriptor for an own property, else undefined. esbuild's
  # __copyProps reads `desc.enumerable`; we report own props as enumerable/writable/configurable.
  defp object_static("getOwnPropertyDescriptor", [o, k | _]) do
    ks = to_str(k)
    if ks in Enum.map(okeys(o), &to_str/1),
      do: cell_new([{"value", oget(o, ks)}, {"writable", true}, {"enumerable", true}, {"configurable", true}]),
      else: :undefined
  end
  defp object_static("fromEntries", [o | _]) do
    pairs = for e <- okeys(o) |> Enum.map(&oget(o, &1)) || [], do: {to_str(oget(e, 0.0)), oget(e, 1.0)}
    cell_new(pairs)
  end
  defp object_static(_, _), do: :undefined

  defp array_static("isArray", [x | _]), do: match?({:arr, _}, x)
  defp array_static("from", [x | rest]) do
    items = iter_any(x)
    case rest do
      [{:fn, _} = f | _] -> avec(Enum.with_index(items) |> Enum.map(fn {v, i} -> call(f, [v, i * 1.0]) end))
      _ -> avec(items)
    end
  end
  defp array_static("of", args), do: avec(args)
  defp array_static(_, _), do: :undefined

  defp iter_any({:arr, _} = a), do: al(a)
  defp iter_any(s) when is_binary(s), do: for(<<c::utf8 <- s>>, do: <<c::utf8>>)
  defp iter_any(_), do: []

  defp math_static("floor", [x | _]), do: Float.floor(x / 1)
  defp math_static("ceil", [x | _]), do: Float.ceil(x / 1)
  defp math_static("round", [x | _]), do: Float.round(x / 1) |> trunc() |> Kernel.*(1.0)
  defp math_static("trunc", [x | _]), do: trunc(x) * 1.0
  defp math_static("abs", [x | _]), do: abs(x) * 1.0
  defp math_static("sqrt", [x | _]), do: :math.sqrt(x)
  defp math_static("pow", [a, b | _]), do: :math.pow(a, b)
  defp math_static("max", args), do: (args |> Enum.filter(&is_number/1) |> Enum.max(fn -> 0.0 end)) * 1.0
  defp math_static("min", args), do: (args |> Enum.filter(&is_number/1) |> Enum.min(fn -> 0.0 end)) * 1.0
  defp math_static("random", _), do: :rand.uniform()
  defp math_static("sign", [x | _]), do: (cond do x > 0 -> 1.0; x < 0 -> -1.0; true -> 0.0 end)
  defp math_static(_, _), do: :undefined

  # calling a namespace/coercion function or a global function
  def call({:global, "String"}, args), do: to_str(List.first(args) || :undefined)
  def call({:global, "Number"}, args), do: to_number(List.first(args) || :undefined)
  def call({:global, "Boolean"}, args), do: truthy(List.first(args) || :undefined)
  def call({:global, "Array"}, args), do: avec(args)
  def call({:global, "Object"}, args), do: List.first(args) || olit()
  def call({:global, err}, args) when err in ["Error", "TypeError", "RangeError", "SyntaxError"], do: construct({:global, err}, args)
  # Symbol(desc): a fresh unique symbol. Represented as {:symbol, id, desc}; identity is the id, so two
  # Symbol("x") differ. Usable as an object key (key_str tags it uniquely).
  def call({:global, "Symbol"}, args) do
    desc = case args do [d | _] when d != :undefined -> to_str(d); _ -> "" end
    {:symbol, __id(), desc}
  end
  def call({:global, _}, _args), do: :undefined

  def call({:globalfn, "parseInt"}, [x | _]), do: parse_int(x)
  def call({:globalfn, "parseFloat"}, [x | _]), do: to_number(x)
  def call({:globalfn, "isNaN"}, [x | _]), do: not is_number(x)
  def call({:globalfn, "isFinite"}, [x | _]), do: is_number(x)
  def call({:globalfn, enc}, [x | _]) when enc in ["encodeURIComponent", "encodeURI"], do: URI.encode(to_str(x))
  def call({:globalfn, dec}, [x | _]) when dec in ["decodeURIComponent", "decodeURI"], do: URI.decode(to_str(x))
  def call({:globalfn, _}, _), do: :undefined

  defp json_stringify(v, _rest), do: json_enc(v)
  defp json_enc(n) when is_number(n), do: to_str(n)
  defp json_enc(true), do: "true"
  defp json_enc(false), do: "false"
  defp json_enc(:undefined), do: "null"
  defp json_enc(:null), do: "null"
  defp json_enc(s) when is_binary(s), do: json_quote(s)
  defp json_enc({:arr, _} = a), do: "[" <> (al(a) |> Enum.map(&json_enc/1) |> Enum.join(",")) <> "]"
  defp json_enc({:fn, _}), do: "null"
  defp json_enc(o) do
    keys = okeys(o)
    body = keys |> Enum.map(fn k -> json_quote(k) <> ":" <> json_enc(oget(o, k)) end) |> Enum.join(",")
    "{" <> body <> "}"
  end

  defp json_quote(s), do: "\"" <> (s |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"") |> String.replace("\n", "\\n")) <> "\""

  defp json_parse(s) do
    try do
      TinyLasers.Wasm.Json.decode!(s) |> json_to_guest()
    rescue
      _ -> :undefined
    end
  end

  defp json_to_guest(n) when is_number(n), do: n / 1
  defp json_to_guest(b) when is_boolean(b), do: b
  defp json_to_guest(nil), do: :null
  defp json_to_guest(s) when is_binary(s), do: s
  defp json_to_guest(l) when is_list(l), do: avec(Enum.map(l, &json_to_guest/1))
  defp json_to_guest(m) when is_map(m), do: Enum.reduce(m, olit(), fn {k, v}, acc -> oput(acc, to_string(k), json_to_guest(v)) end)

  defp parse_int(x) do
    case Integer.parse(String.trim(to_str(x))) do
      {n, _} -> n * 1.0
      :error -> :undefined
    end
  end

  @doc "ToNumber coercion (public: unary + uses it)."
  def to_number(x) when is_number(x), do: x
  def to_number(x) when x in [:infinity, :neg_infinity, :nan], do: x
  def to_number(true), do: 1.0
  def to_number(false), do: 0.0
  def to_number(s) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {n, ""} -> n
      _ -> case Integer.parse(String.trim(s)) do {n, ""} -> n * 1.0; _ -> :undefined end
    end
  end
  def to_number(_), do: :undefined

  # Function.prototype.apply/call/bind (marked + minified helpers use these heavily).
  def method({:fn, _} = f, "apply", args) do
    this = List.first(args) || :undefined
    argl = case args do [_, {:arr, _} = av | _] -> al(av); _ -> [] end
    invoke(f, this, argl)
  end

  def method({:protom, :tostring}, m, [x | _]) when m in ["call", "apply"], do: to_string_tag(x)
  def method({:protom, :tostring}, m, []) when m in ["call", "apply"], do: to_string_tag(:undefined)
  def method({:protom, :hasown}, "call", [o, k | _]), do: has_own(o, k)
  def method({:protom, :hasown}, "apply", [o, {:arr, _} = av | _]), do: has_own(o, List.first(al(av)))
  def method({:fn, _} = f, "call", [this | rest]), do: invoke(f, this, rest)
  def method({:fn, _} = f, "call", []), do: invoke(f, :undefined, [])

  def method({:fn, _} = f, "bind", [this | bound]) do
    closure(fn _ignored_this, args -> invoke(f, this, bound ++ args) end)
  end
  # `.bind()` with no args: bind `this` to undefined (marked: `Object.assign.bind()`).
  def method({:fn, _} = f, "bind", []), do: closure(fn _ignored_this, args -> invoke(f, :undefined, args) end)

  # a property call on a function object: `marked.parse(md)` — look up the function-valued property + invoke.
  def method({:fn, _} = fnv, name, args) do
    case oget(fnv, name) do
      {:fn, _} = g -> invoke(g, fnv, args)
      other -> if System.get_env("GAPLOG"), do: IO.puts(:stderr, "GAP fnmeth #{inspect(name)} -> #{inspect(other)|>String.slice(0,30)}"); guest_error("not a function")
    end
  end

  # calling a method that doesn't resolve (incl. on `:undefined`, e.g. `os.cmd(...)`) is a guest TypeError,
  # NOT a host escape — the receiver was never a host reference.
  def method(r, nm, _a) do
    if System.get_env("GAPLOG") do
      extra = if System.get_env("GAPTRACE") do
        Process.info(self(), :current_stacktrace) |> elem(1)
        |> Enum.filter(fn {m,_,_,_} -> m |> to_string() =~ ~r/Runtime|Guest/ end) |> Enum.take(6)
        |> Enum.map_join(" <- ", fn {_,f,a,_} -> "#{f}/#{a}" end)
      else "" end
      IO.puts(:stderr, "GAP method #{inspect(nm)} on #{inspect(r) |> String.slice(0, 40)} #{extra}")
    end
    if System.get_env("GAPSOFT"), do: :undefined, else: guest_error("not a function")
  end


  defp slice_list(list, a, rest) do
    n = length(list)
    start = trunc(num(a))
    start = if start < 0, do: max(n + start, 0), else: min(start, n)
    stop = case rest do
      [b | _] when b != :undefined -> e = trunc(num(b)); if e < 0, do: max(n + e, 0), else: min(e, n)
      _ -> n
    end
    Enum.slice(list, start, max(stop - start, 0))
  end

  # code-point count (JS string length) with an all-ASCII fast path.
  defp str_len(s), do: if ascii?(s), do: byte_size(s), else: length(String.to_charlist(s))
  # all-ASCII check (the common case → the byte ops are already correct): no byte has the high bit set.
  defp ascii?(<<>>), do: true
  defp ascii?(<<b, rest::binary>>) when b < 128, do: ascii?(rest)
  defp ascii?(_), do: false

  # slice/substring on CODE POINTS (JS semantics), ASCII fast path via binary_part.
  defp str_slice(s, a, rest) do
    n = str_len(s)
    start = trunc(num(a))
    start = if start < 0, do: max(n + start, 0), else: min(start, n)
    stop = case rest do
      [b | _] when b != :undefined -> e = trunc(num(b)); if e < 0, do: max(n + e, 0), else: min(e, n)
      _ -> n
    end
    cp_sub(s, start, max(stop - start, 0))
  end

  # substring(a,b): clamps to [0,len], swaps if a>b (JS semantics), no negatives.
  defp str_substring(s, a, rest) do
    len = str_len(s)
    a = a |> trunc() |> max(0) |> min(len)
    b = case rest do [x | _] when is_number(x) -> x |> trunc() |> max(0) |> min(len); _ -> len end
    lo = min(a, b)
    cp_sub(s, lo, max(a, b) - lo)
  end

  defp cp_sub(s, start, len) do
    if ascii?(s), do: binary_part(s, start, len), else: (String.to_charlist(s) |> Enum.slice(start, len) |> List.to_string())
  end

  defp str_pad(s, len, rest, side) do
    target = trunc(len)
    pad = case rest do [p | _] -> to_str(p); _ -> " " end

    if byte_size(s) >= target or pad == "" do
      s
    else
      fill = String.duplicate(pad, div(target - byte_size(s), byte_size(pad)) + 1) |> binary_part(0, target - byte_size(s))
      if side == :leading, do: fill <> s, else: s <> fill
    end
  end

  defp num(v) when is_number(v), do: v
  defp num(_), do: 0

  @doc "A guest function as a DIRECTLY-HELD closure (GC'd, no table). The fun takes `(this, args)`; safe —
  the guest can only invoke it via `call/2` or `invoke/3`, and no codegen path extracts and `apply`s it."
  def closure(f) when is_function(f, 2), do: {:fn, f}

  defp instanceof_chain(nil, _target), do: false
  defp instanceof_chain(proto, target) do
    proto == target or instanceof_chain((case proto do {:cell, pid} -> Process.get({:gg_instproto, pid}); _ -> nil end), target)
  end

  # ── Promise internals (synchronous/eager; see the method clauses above) ──
  # ── microtask queue: settle/then NEVER run callbacks inline (that recursed settle→then→settle unboundedly,
  # growing the BEAM stack until OOM). Instead callbacks are ENQUEUED and a drain loop runs them iteratively
  # (bounded, constant stack). This also gives correct JS microtask ordering. ──
  defp mq_enqueue(thunk), do: Process.put(:gg_microq, :queue.in(thunk, Process.get(:gg_microq, :queue.new())))

  defp mq_take do
    case :queue.out(Process.get(:gg_microq, :queue.new())) do
      {{:value, thunk}, q2} -> Process.put(:gg_microq, q2); thunk
      {:empty, _} -> nil
    end
  end

  @microtask_cap 5_000_000

  @doc "Drain all pending microtasks iteratively (called by the run harness after the top-level guest code)."
  def drain_microtasks(n \\ 0)
  def drain_microtasks(n) when n >= @microtask_cap, do: guest_error("microtask overflow — unresolved promise loop")
  def drain_microtasks(n) do
    case mq_take() do
      nil -> :ok
      thunk -> thunk.(); drain_microtasks(n + 1)
    end
  end

  defp new_promise do
    id = __id()
    Process.put({:gg_prom, id}, {:pending, :undefined, []})
    {:promise, id}
  end

  defp prom_state({:promise, id}), do: Process.get({:gg_prom, id}, {:pending, :undefined, []})

  # settle a pending promise. Resolving with a thenable adopts its eventual state (via prom_on — a SIDE-EFFECT
  # subscription whose return value is ignored, unlike prom_then). Otherwise record state + enqueue callbacks.
  defp settle({:promise, id} = p, kind, value) do
    case prom_state(p) do
      {:pending, _, cbs} ->
        if kind == :fulfilled and match?({:promise, _}, value) do
          prom_on(value, fn v -> settle(p, :fulfilled, v) end, fn e -> settle(p, :rejected, e) end)
          :ok
        else
          Process.put({:gg_prom, id}, {kind, value, []})
          Enum.each(:lists.reverse(cbs), fn cb -> mq_enqueue(fn -> cb.(kind, value) end) end)
        end

      _ -> :ok
    end
    p
  end

  # subscribe an INTERNAL side-effect to a promise (Promise.all accumulation, thenable adoption). The handler
  # is a plain 1-arg Elixir fun; its return value is IGNORED — no out-promise, no return-adoption. (prom_then,
  # by contrast, settles an out-promise with the handler's return — for that, an internal handler returning a
  # promise would be re-adopted every cycle → infinite microtask loop.)
  defp prom_on(p, on_f, on_r) do
    cb = fn kind, value -> (if kind == :fulfilled, do: on_f, else: on_r).(value) end
    case prom_state(p) do
      {:pending, _, cbs} -> Process.put(elem_key(p), {:pending, :undefined, [cb | cbs]})
      {kind, value, _} -> mq_enqueue(fn -> cb.(kind, value) end)
    end
    :ok
  end

  # .then: returns a new promise; the handler runs as a MICROTASK (enqueued), never inline.
  defp prom_then(p, on_f, on_r) do
    out = new_promise()
    cb = fn kind, value ->
      handler = if kind == :fulfilled, do: on_f, else: on_r
      if match?({:fn, _}, handler) or match?({:host, _}, handler) do
        try do
          settle(out, :fulfilled, invoke(handler, :undefined, [value]))
        catch
          :throw, {:gg_guest_error, e} -> settle(out, :rejected, e)
          :throw, {:gg_throw, e} -> settle(out, :rejected, e)
        end
      else
        # no handler: pass the settled value/reason straight through
        settle(out, kind, value)
      end
    end
    case prom_state(p) do
      {:pending, _, cbs} -> Process.put(elem_key(p), {:pending, :undefined, [cb | cbs]})
      {kind, value, _} -> mq_enqueue(fn -> cb.(kind, value) end)
    end
    out
  end

  defp elem_key({:promise, id}), do: {:gg_prom, id}
  defp invoke_if(f, args), do: (if match?({:fn, _}, f) or match?({:host, _}, f), do: invoke(f, :undefined, args), else: :undefined)

  @doc "Run an async function body thunk, producing a promise: resolves with its (awaited) result, or rejects
  on a thrown guest error / rejected await."
  def promise_from(thunk) do
    try do
      settle(new_promise(), :fulfilled, thunk.())
    catch
      :throw, {:gg_guest_error, e} -> settle(new_promise(), :rejected, e)
      :throw, {:gg_throw, e} -> settle(new_promise(), :rejected, e)
    end
  end

  @doc "`await x`: drain microtasks until the awaited promise settles, then unwrap (rejected → re-throw)."
  def await_({:promise, _} = p), do: (drain_until(p, 0); await_read(p))
  def await_(v), do: v

  defp await_read(p) do
    case prom_state(p) do
      {:fulfilled, v, _} -> v
      {:rejected, e, _} -> throw_val(e)
      {:pending, _, _} -> :undefined
    end
  end

  # run microtasks until `p` leaves pending (or the queue empties / cap hit).
  defp drain_until(p, n) do
    case prom_state(p) do
      {:pending, _, _} when n < @microtask_cap ->
        case mq_take() do
          nil -> :ok
          thunk -> thunk.(); drain_until(p, n + 1)
        end
      _ -> :ok
    end
  end

  defp promise_static("resolve", [v | _]), do: (if match?({:promise, _}, v), do: v, else: settle(new_promise(), :fulfilled, v))
  defp promise_static("resolve", []), do: settle(new_promise(), :fulfilled, :undefined)
  defp promise_static("reject", [e | _]), do: settle(new_promise(), :rejected, e)
  defp promise_static("reject", []), do: settle(new_promise(), :rejected, :undefined)
  # Promise.all: settle `out` with the results array once every input fulfils (reject on first rejection).
  # Correct async: register a then on each input; accumulate results in an out-keyed process slot.
  defp promise_static("all", [{:arr, _} = av | _]) do
    items = al(av)
    out = new_promise()
    total = length(items)
    if total == 0 do
      settle(out, :fulfilled, avec([]))
    else
      Process.put({:gg_all, elem(out, 1)}, {total, List.duplicate(:undefined, total)})
      items |> Enum.with_index() |> Enum.each(fn {item, i} ->
        prom_on(promise_wrap(item), fn v -> all_collect(out, i, v) end, fn e -> settle(out, :rejected, e) end)
      end)
      out
    end
  end
  defp promise_static("allSettled", [{:arr, _} = av | _]) do
    items = al(av)
    out = new_promise()
    total = length(items)
    if total == 0 do
      settle(out, :fulfilled, avec([]))
    else
      Process.put({:gg_all, elem(out, 1)}, {total, List.duplicate(:undefined, total)})
      items |> Enum.with_index() |> Enum.each(fn {item, i} ->
        prom_on(promise_wrap(item),
          fn v -> all_collect(out, i, cell_new([{"status", "fulfilled"}, {"value", v}])) end,
          fn e -> all_collect(out, i, cell_new([{"status", "rejected"}, {"reason", e}])) end)
      end)
      out
    end
  end
  defp promise_static("race", [{:arr, _} = av | _]) do
    out = new_promise()
    Enum.each(al(av), fn item ->
      prom_on(promise_wrap(item), fn v -> settle(out, :fulfilled, v) end, fn e -> settle(out, :rejected, e) end)
    end)
    out
  end
  defp promise_static(_, _), do: :undefined

  # record result i for a Promise.all/allSettled `out`; settle when all have arrived.
  defp all_collect(out, i, v) do
    {rem, results} = Process.get({:gg_all, elem(out, 1)})
    results = List.replace_at(results, i, v)
    if rem - 1 == 0 do
      settle(out, :fulfilled, avec(results))
    else
      Process.put({:gg_all, elem(out, 1)}, {rem - 1, results})
    end
  end

  defp promise_wrap({:promise, _} = p), do: p
  defp promise_wrap(v), do: settle(new_promise(), :fulfilled, v)

  @doc "Link a child constructor's prototype to its parent's (ES6 `class Child extends Parent`), so inherited
  instance methods resolve by walking child.prototype -> parent.prototype. Also records the ctor-level super
  link for static inheritance."
  def set_proto_chain({:fn, _} = child, {:fn, _} = parent) do
    {:cell, cid} = fn_proto(child)
    Process.put({:gg_instproto, cid}, fn_proto(parent))
    Process.put({:gg_superctor, child_key(child)}, parent)
    :undefined
  end
  def set_proto_chain(_, _), do: :undefined

  defp child_key({:fn, f}), do: f

  # a function's prototype cell (stable per closure) — the ES5 method bag for `new Ctor()` instances.
  defp fn_proto({:fn, f}) do
    case Process.get(:gg_fnproto, %{}) |> Map.get(f) do
      nil ->
        pc = cell_new([])
        Process.put(:gg_fnproto, Map.put(Process.get(:gg_fnproto, %{}), f, pc))
        pc

      pc ->
        pc
    end
  end

  # top-level function registry: late binding so forward references + mutual recursion work (fn A calls fn B
  # declared after it). Functions are few and per-run, so a small process-dict table is fine (the GC concern
  # was OBJECTS, not functions). A guest can only reach these by NAME resolved at compile time to greg_get.
  @doc "Register a top-level guest function by name."
  def greg_set(name, closure), do: Process.put({:gg_fn, name}, closure)
  @doc "Resolve a top-level guest function by name (late) — `:undefined` if never declared."
  def greg_get(name), do: Process.get({:gg_fn, name}, :undefined)

  @doc "`new F(args)` — construct an instance: fresh `this` cell, invoke the constructor, return the instance
  (the constructor's returned object if it returns one, else the mutated `this`). Error constructors make an
  error object; `new RegExp` is handled at the codegen level."
  def construct({:fn, _} = f, args) do
    this = cell_new([])
    {:cell, iid} = this
    # link the instance to its constructor's prototype so method lookups resolve ES5 class methods.
    Process.put({:gg_instproto, iid}, fn_proto(f))

    case invoke(f, this, args) do
      {tag, _} = obj when tag in [:cell, :arr] -> obj
      {keys, map} = obj when is_map(map) -> obj
      _ -> this
    end
  end

  def construct({:global, err}, args) when err in ["Error", "TypeError", "RangeError", "SyntaxError"],
    do: cell_new([{"message", to_str(List.first(args) || "")}, {"name", err}])

  def construct({:global, "Array"}, args), do: avec(args)
  # Proxy: {:proxy, target, handler}. Property get/set + method calls route through the handler's traps
  # (falling back to the target). rollup's output bundle is a Proxy over the chunk map.
  def construct({:global, "Proxy"}, [target, handler | _]), do: {:proxy, target, handler}
  # typed arrays are backed by a plain guest array (indexed get/set, length, subarray all work on {:arr,_}).
  # new TA(n) -> n zeros; new TA([...]) / new TA(otherTA) -> element copy.
  def construct({:global, ta}, args)
      when ta in ["Uint8Array", "Int8Array", "Uint16Array", "Int16Array", "Uint32Array",
                  "Int32Array", "Float32Array", "Float64Array"] do
    case args do
      [{:arr, _} = av | _] -> avec(al(av))
      [n | _] when is_number(n) -> avec(List.duplicate(0.0, trunc(n)))
      _ -> avec([])
    end
  end
  def construct({:global, "Object"}, _), do: cell_new([])
  def construct({:global, s}, args) when s in ["Set", "WeakSet"] do
    id = __id()
    init = case args do [{:arr, _} = av | _] -> Enum.uniq(al(av)); _ -> [] end
    Process.put({:gg_set, id}, init)
    {:set, id}
  end

  # new Promise(executor): run the executor synchronously with (resolve, reject); a synchronous resolve/reject
  # settles now (eager model). A throwing executor rejects.
  def construct({:global, "Promise"}, [executor | _]) do
    p = new_promise()
    res = closure(fn _t, a -> settle(p, :fulfilled, List.first(a) || :undefined) end)
    rej = closure(fn _t, a -> settle(p, :rejected, List.first(a) || :undefined) end)
    try do
      invoke(executor, :undefined, [res, rej])
    catch
      :throw, {:gg_guest_error, e} -> settle(p, :rejected, e)
      :throw, {:gg_throw, e} -> settle(p, :rejected, e)
    end
    p
  end

  def construct({:global, m}, args) when m in ["Map", "WeakMap"] do
    id = __id()
    init = case args do [{:arr, _} = av | _] -> Enum.map(al(av), fn e -> case (if match?({:arr,_},e), do: al(e), else: []) do [k, v | _] -> {k, v}; _ -> {:undefined, :undefined} end end); _ -> [] end
    Process.put({:gg_map, id}, init)
    {:map, id}
  end

  def construct(nc, args) do
    if System.get_env("GAPLOG") do
      st = if System.get_env("GAPTRACE") do
        Process.info(self(), :current_stacktrace) |> elem(1) |> Enum.filter(fn {m,_,_,_} -> m |> to_string() =~ ~r/Guest|Runtime/ end) |> Enum.take(6) |> Enum.map_join(" <- ", fn {_,f,a,_} -> "#{f}/#{a}" end)
      else "" end
      akeys = args |> Enum.map(fn a -> if match?({:cell,_}, a), do: okeys(a) |> Enum.take(6), else: a end) |> inspect() |> String.slice(0, 100)
      IO.puts(:stderr, "GAP construct #{inspect(nc)|>String.slice(0,50)} argkeys=#{akeys} #{st}")
    end
    if System.get_env("GAPSOFT"), do: cell_new([]), else: guest_error("not a constructor")
  end

  @doc "Invoke a guest function with an explicit `this` receiver (method call). Ungranted callees error."
  def invoke({:fn, f}, this, args) when is_function(f, 2), do: f.(this, args)
  def invoke({:host, cap_id}, _this, args), do: host_call(cap_id, args)
  def invoke(nc, _this, args) do
    if System.get_env("GAPLOG"), do: IO.puts(:stderr, "GAP invoke on #{inspect(nc)|>String.slice(0,40)} args=#{inspect(args)|>String.slice(0,50)}")
    guest_error("not a function")
  end

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
  def call({:fn, f}, args) when is_function(f, 2), do: f.(:undefined, args)

  def call({:fun, id}, args) do
    case Process.get(:gg_funs) |> Map.get(id) do
      f when is_function(f, 1) -> f.(args)
      _ -> guest_error("not a function")
    end
  end

  def call({:host, cap_id}, args), do: host_call(cap_id, args)
  def call(nc, args) do
    if System.get_env("GAPLOG") do
      st = Process.info(self(), :current_stacktrace) |> elem(1) |> Enum.filter(fn {m,_,_,_} -> m |> to_string() |> String.contains?("Guest") end) |> Enum.take(3) |> Enum.map(fn {_,f,a,_} -> "#{f}/#{a}" end)
      IO.puts(:stderr, "GAP call on #{inspect(nc) |> String.slice(0, 40)} args=#{inspect(args) |> String.slice(0, 40)} @ #{Enum.join(st, " <- ")}")
    end
    if System.get_env("GAPSOFT"), do: :undefined, else: guest_error("not a function")
  end

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
  # ±Infinity in relational comparisons (rank-ordered; NaN comparisons are always false, handled by fallback).
  def binop(op, a, b) when op in [:<, :>, :"<=", :">="] and (a == :infinity or a == :neg_infinity or b == :infinity or b == :neg_infinity) do
    case {rel_key(a), rel_key(b)} do
      {nil, _} -> false
      {_, nil} -> false
      {ka, kb} -> case op do
        :< -> ka < kb
        :> -> ka > kb
        :"<=" -> ka <= kb
        :">=" -> ka >= kb
      end
    end
  end

  def binop(:<, a, b) when is_number(a) and is_number(b), do: a < b
  def binop(:>, a, b) when is_number(a) and is_number(b), do: a > b
  def binop(:"<=", a, b) when is_number(a) and is_number(b), do: a <= b
  def binop(:">=", a, b) when is_number(a) and is_number(b), do: a >= b
  def binop(:rem, a, b) when is_number(a) and is_number(b) and b != 0, do: a - b * Float.floor(a / b)
  # string relational comparison (lexicographic, JS semantics)
  def binop(:<, a, b) when is_binary(a) and is_binary(b), do: a < b
  def binop(:>, a, b) when is_binary(a) and is_binary(b), do: a > b
  def binop(:"<=", a, b) when is_binary(a) and is_binary(b), do: a <= b
  def binop(:">=", a, b) when is_binary(a) and is_binary(b), do: a >= b
  def binop(:===, a, b), do: a === b
  def binop(:!==, a, b), do: a !== b
  # loose equality: `null == undefined` is true; number/string/boolean coerce (marked's `x != null` idiom).
  def binop(:==, a, b), do: loose_eq(a, b)
  def binop(:!=, a, b), do: not loose_eq(a, b)
  def binop(:in, k, obj), do: has_own(obj, k)
  # `x instanceof Ctor` — walk x's prototype chain (from `new`/Object.create linkage) for Ctor.prototype.
  def binop(:instanceof, {:cell, id}, {:fn, _} = ctor), do: instanceof_chain(Process.get({:gg_instproto, id}), fn_proto(ctor))
  def binop(:instanceof, _a, _b), do: false
  # bitwise ops — JS coerces via ToInt32; result is a signed 32-bit int returned as a float.
  def binop(:band, a, b), do: bitop(a, b, &Bitwise.band/2)
  def binop(:bor, a, b), do: bitop(a, b, &Bitwise.bor/2)
  def binop(:bxor, a, b), do: bitop(a, b, &Bitwise.bxor/2)
  def binop(:bsl, a, b), do: bitop(a, b, fn x, y -> Bitwise.bsl(x, Bitwise.band(y, 31)) end)
  def binop(:bsr, a, b), do: bitop(a, b, fn x, y -> Bitwise.bsr(x, Bitwise.band(y, 31)) end)
  # relational comparison with a mismatched/non-number operand (`1 < undefined`) is false in JS (NaN).
  def binop(op, _a, _b) when op in [:<, :>, :"<=", :">="], do: false
  # arithmetic on non-number operands: JS coerces via ToNumber; a non-coercible operand yields NaN
  # (`undefined - 2`, `[] * 3`). marked relies on NaN propagating rather than throwing.
  def binop(:-, a, b), do: arith(a, b, &Kernel.-/2)
  def binop(:*, a, b), do: arith(a, b, &Kernel.*/2)
  def binop(:rem, a, b), do: arith(a, b, fn x, y -> if y == 0, do: :nan, else: x - y * Float.floor(x / y) end)
  def binop(op, a, b) do
    if System.get_env("GAPLOG"), do: IO.puts(:stderr, "GAP binop #{inspect(op)} a=#{inspect(a)|>String.slice(0,30)} b=#{inspect(b)|>String.slice(0,30)}")
    guest_error("bad operands")
  end

  defp nullish?(:null), do: true
  defp nullish?(:undefined), do: true
  defp nullish?(_), do: false

  defp loose_eq(a, b) do
    cond do
      a === b -> true
      nullish?(a) and nullish?(b) -> true
      is_number(a) and is_binary(b) -> (n = to_number(b); is_number(n) and a === n)
      is_binary(a) and is_number(b) -> (n = to_number(a); is_number(n) and n === b)
      is_boolean(a) -> loose_eq((if a, do: 1.0, else: 0.0), b)
      is_boolean(b) -> loose_eq(a, (if b, do: 1.0, else: 0.0))
      true -> false
    end
  end

  defp to_int32(v) do
    n = trunc(num(v))
    m = rem(n, 4_294_967_296)
    m = if m < 0, do: m + 4_294_967_296, else: m
    if m >= 2_147_483_648, do: m - 4_294_967_296, else: m
  end

  defp bitop(a, b, f), do: to_int32(f.(to_int32(a), to_int32(b))) * 1.0

  defp rel_key(:infinity), do: {2, 0}
  defp rel_key(:neg_infinity), do: {0, 0}
  defp rel_key(x) when is_number(x), do: {1, x}
  defp rel_key(_), do: nil

  defp arith(a, b, f) do
    na = to_number(a)
    nb = to_number(b)
    cond do
      is_number(na) and is_number(nb) -> f.(na, nb)
      # 0 - (±Infinity) negates it (covers unary minus); anything else with an infinity stays infinite/NaN.
      a == 0.0 and nb == :infinity -> :neg_infinity
      a == 0.0 and nb == :neg_infinity -> :infinity
      true -> :nan
    end
  end

  @doc "JS nullish: only null/undefined (for `??` and `?.`). Distinct from falsy."
  def is_nullish(:undefined), do: true
  def is_nullish(:null), do: true
  def is_nullish(_), do: false

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
  # a symbol used as a property key: tag uniquely by its identity so distinct symbols don't collide.
  defp key_str({:symbol, id, _desc}), do: "@@sym:" <> to_string(id)
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
  def to_str({:symbol, _, desc}), do: "Symbol(" <> desc <> ")"
  def to_str({:obj, _}), do: "[object Object]"
  def to_str({:fun, _}), do: "function"
  def to_str({:host, _}), do: "function"
  def to_str({:arr, _} = a), do: al(a) |> Enum.map(fn v -> if v in [:undefined, :null], do: "", else: to_str(v) end) |> Enum.join(",")
  def to_str({:regex, _, src, flags}), do: "/" <> src <> "/" <> flags
  def to_str(:infinity), do: "Infinity"
  def to_str(:neg_infinity), do: "-Infinity"
  def to_str(:nan), do: "NaN"
  def to_str(_), do: "[unknown]"

  defp set_list({:set, id}), do: Process.get({:gg_set, id}, [])
  defp map_pairs({:map, id}), do: Process.get({:gg_map, id}, [])

  defp to_string_tag(x) do
    tag =
      cond do
        is_number(x) -> "Number"
        is_binary(x) -> "String"
        is_boolean(x) -> "Boolean"
        x == :undefined -> "Undefined"
        x == :null -> "Null"
        match?({:arr, _}, x) -> "Array"
        match?({:regex, _, _, _}, x) -> "RegExp"
        match?({:fn, _}, x) or match?({:host, _}, x) or match?({:globalfn, _}, x) -> "Function"
        true -> "Object"
      end
    "[object " <> tag <> "]"
  end

  defp has_own(o, k) do
    key = key_str(k)
    case o do
      {:cell, _} -> Map.has_key?(cell_read(o) |> elem(1), key)
      {:fn, f} -> Process.get(:gg_fnprops, %{}) |> Map.get(f, {[], %{}}) |> elem(1) |> Map.has_key?(key)
      {keys, map} when is_map(map) -> Map.has_key?(map, key)
      {:globalobj} -> Process.get(:gg_global, {[], %{}}) |> elem(1) |> Map.has_key?(key)
      {:arr, _} = a -> len = length(al(a)); key == "length" or match?({n, ""} when n >= 0 and n < len, Integer.parse(key))
      _ -> false
    end
  end

  @doc "A guest-level exception. NOT a host escape — the driver catches it as a guest error."
  def guest_error(reason) do
    if System.get_env("GAPTRACE") do
      st = Process.info(self(), :current_stacktrace) |> elem(1)
           |> Enum.filter(fn {m,_,_,_} -> m |> to_string() =~ ~r/Runtime|Guest/ end) |> Enum.take(8)
      IO.puts(:stderr, "GERR #{inspect(reason)}: #{Enum.map_join(st, " <- ", fn {_,f,a,_} -> "#{f}/#{a}" end)}")
    end
    throw({:gg_guest_error, reason})
  end

  @doc "Guest `return` — throws to the enclosing function-body catch. Routed through the Runtime so the
  emitted guest module references no external module (keeps the 'only Runtime' confinement invariant literal)."
  def ret(v), do: throw({:gg_return, v})

  @doc "Loop break/continue — routed through the Runtime so the guest references no :erlang.throw (confinement)."
  def brk(tag), do: throw({:gg_break, tag})
  def cont(tag), do: throw({:gg_continue, tag})

  @doc "Guest `throw e` — a catchable guest exception carrying the guest value."
  def throw_val(v), do: throw({:gg_throw, v})

  @doc "for-of iteration items: array elements, or a string's chars (1-char binaries)."
  def iter({:arr, _} = a), do: al(a)
  def iter({:set, _} = st), do: set_list(st)
  def iter(s) when is_binary(s), do: for <<c::utf8 <- s>>, do: <<c::utf8>>
  def iter(_), do: []

  @doc "for-in enumeration keys: object own-keys, array index strings, or none."
  def enum_keys({keys, map}) when is_map(map), do: keys
  def enum_keys({:cell, _} = c), do: elem(cell_read(c), 0)
  def enum_keys({:arr, _} = a), do: (l = al(a); if l == [], do: [], else: Enum.map(0..(length(l) - 1)//1, &Integer.to_string/1))
  def enum_keys(_), do: []

  @doc "`typeof` — a fixed set of result binaries (never guest-controlled atoms)."
  def typeof(v) when is_number(v), do: "number"
  def typeof(v) when is_binary(v), do: "string"
  def typeof(v) when is_boolean(v), do: "boolean"
  def typeof(:undefined), do: "undefined"
  def typeof({:fn, _}), do: "function"
  def typeof({:host, _}), do: "function"
  def typeof({:cell, _}), do: "object"
  def typeof({:globalobj}), do: "object"
  def typeof({:regex, _, _, _}), do: "object"
  def typeof({:global, _}), do: "function"
  def typeof({:globalfn, _}), do: "function"
  def typeof(:infinity), do: "number"
  def typeof(:neg_infinity), do: "number"
  def typeof(:nan), do: "number"
  def typeof(:null), do: "object"
  def typeof({:symbol, _, _}), do: "symbol"
  def typeof({:promise, _}), do: "object"
  def typeof({:bytes, _}), do: "object"
  def typeof({:proxy, t, _}), do: typeof(t)
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
