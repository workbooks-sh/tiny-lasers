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
  def oget({:cell, id} = c, k) do
    key = key_str(k)

    case Map.get(cell_read(c) |> elem(1), key, :__miss) do
      :__miss ->
        case Process.get({:gg_instproto, id}) do
          nil -> :undefined
          proto -> oget(proto, key)
        end

      v ->
        v
    end
  end

  # a function's `.prototype` is a stable per-function cell (ES5 method bag: `Ctor.prototype.m = fn`).
  def oget({:fn, _} = fnv, "prototype"), do: fn_proto(fnv)
  def oget({:fn, f}, k), do: (Process.get(:gg_fnprops, %{}) |> Map.get(f, {[], %{}}) |> elem(1) |> Map.get(key_str(k), :undefined))
  def oget({_keys, map}, k) when is_map(map), do: Map.get(map, key_str(k), :undefined)
  def oget({:set, _} = st, "size"), do: length(set_list(st)) * 1.0
  def oget({:map, _} = mp, "size"), do: length(map_pairs(mp)) * 1.0

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
  def oget(s, "length") when is_binary(s), do: byte_size(s) * 1.0
  def oget(s, i) when is_binary(s) and is_number(i) do
    idx = trunc(i)
    if idx >= 0 and idx < byte_size(s), do: binary_part(s, idx, 1), else: :undefined
  end

  @doc "global namespace/property reads (Math.PI, Number.MAX_VALUE, Object.prototype)."
  def oget({:global, "Math"}, "PI"), do: :math.pi()
  def oget({:global, "Number"}, "MAX_VALUE"), do: 1.7976931348623157e308
  def oget({:global, "Number"}, "MIN_VALUE"), do: 5.0e-324
  def oget({:global, "Number"}, "MAX_SAFE_INTEGER"), do: 9_007_199_254_740_991.0
  def oget({:global, name}, "prototype"), do: {:proto, name}
  def oget({:global, _}, _), do: :undefined

  def oget({:proto, _}, "toString"), do: {:protom, :tostring}
  def oget({:proto, _}, "hasOwnProperty"), do: {:protom, :hasown}
  def oget({:proto, _}, _), do: :undefined

  def oget(_not_obj, _k), do: :undefined

  @doc "Spread-merge b into a (Object.assign({}, a, b) shape). Returns a NEW object, b's keys last/override."
  def omerge({ak, amap}, {bk, bmap}) do
    {keys, map} =
      Enum.reduce(bk, {ak, amap}, fn k, {ks, m} ->
        if Map.has_key?(m, k), do: {ks, Map.put(m, k, bmap[k])}, else: {ks ++ [k], Map.put(m, k, bmap[k])}
      end)

    {keys, map}
  end

  def omerge({:cell, _} = c, b), do: omerge(cell_read(c), b)
  def omerge(a, {:cell, _} = c), do: omerge(a, cell_read(c))
  def omerge(a, _non_obj), do: a

  @doc "Ordered own-keys of a direct-term object."
  def okeys({keys, map}) when is_map(map), do: keys
  def okeys({:cell, _} = c), do: elem(cell_read(c), 0)
  def okeys({:globalobj}), do: Process.get(:gg_global, {[], %{}}) |> elem(0)
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
      _ -> guest_error("not a function")
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

  defp al({:arr, id}), do: Process.get({:gg_vec, id}, {[], %{}}) |> elem(0)
  defp ap({:arr, id}), do: Process.get({:gg_vec, id}, {[], %{}}) |> elem(1)
  defp aset({:arr, id} = a, list, props), do: (Process.put({:gg_vec, id}, {list, props}); a)
  defp aset_l({:arr, _} = a, list), do: aset(a, list, ap(a))

  @doc "Array literal from evaluated elements."
  def alit(elems) when is_list(elems), do: avec(elems)

  @doc "Array literal WITH spread elements: parts are `{:one, v}` | `{:spread, iterable}`."
  def aspread(parts) do
    avec(Enum.flat_map(parts, fn {:spread, v} -> iter(v); {:one, v} -> [v] end))
  end

  @doc "Flatten call arguments with spread elements into a plain args list (`f(...xs, y)`)."
  def spread_args(parts), do: Enum.flat_map(parts, fn {:spread, v} -> iter(v); {:one, v} -> [v] end)

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
  def method({:map, id} = mp, "set", [k, v | _]), do: (Process.put({:gg_map, id}, List.keystore(map_pairs(mp), 0, {k, v})); mp)
  def method({:map, _} = mp, "has", [k | _]), do: List.keymember?(map_pairs(mp), k, 0)
  def method({:map, id} = mp, "delete", [k | _]), do: (had = method(mp, "has", [k]); Process.put({:gg_map, id}, List.keydelete(map_pairs(mp), k, 0)); had)
  def method({:map, id}, "clear", _), do: (Process.put({:gg_map, id}, []); :undefined)
  def method({:map, _} = mp, "forEach", [f | _]), do: (Enum.each(map_pairs(mp), fn {k, v} -> call(f, [v, k]) end); :undefined)
  def method({:map, _} = mp, "keys", _), do: avec(Enum.map(map_pairs(mp), &elem(&1, 0)))
  def method({:map, _} = mp, "values", _), do: avec(Enum.map(map_pairs(mp), &elem(&1, 1)))
  # ── all array methods on a mutable reference: mutating ops write the table in place (aliases share); pure
  # ops return a NEW array. ──
  def method({:arr, _} = a, name, args) do
    list = al(a)
    a0 = List.first(args)
    arr_method(a, list, name, a0, args)
  end

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
      m when m in ["toString", "valueOf"] -> list |> Enum.map(&to_str/1) |> Enum.join(",")
      _ ->
        # a function-valued named property (rare): call it; else it is not a function.
        case Map.get(ap(a), name, :undefined) do
          {:fn, _} = f -> invoke(f, a, args)
          _ -> guest_error("not a function")
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
      _ -> if System.get_env("GAPLOG"), do: IO.puts(:stderr, "GAP cellmeth #{inspect(name)}"); guest_error("not a function")
    end
  end

  # ── global namespaces (Object/Array/Math/JSON/Number/String) — static methods + a few properties ──
  def method({:global, "Object"}, name, args), do: object_static(name, args)
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
      has_own(desc, "get") -> oput(o, to_str(k), invoke(oget(desc, "get"), o, []))
      true -> o
    end
  end
  defp object_static("getPrototypeOf", _), do: :undefined
  defp object_static("setPrototypeOf", [o | _]), do: o
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

  # a property call on a function object: `marked.parse(md)` — look up the function-valued property + invoke.
  def method({:fn, _} = fnv, name, args) do
    case oget(fnv, name) do
      {:fn, _} = g -> invoke(g, fnv, args)
      _ -> guest_error("not a function")
    end
  end

  # calling a method that doesn't resolve (incl. on `:undefined`, e.g. `os.cmd(...)`) is a guest TypeError,
  # NOT a host escape — the receiver was never a host reference.
  def method(r, nm, _a) do
    if System.get_env("GAPLOG"), do: IO.puts(:stderr, "GAP method #{inspect(nm)} on #{inspect(r) |> String.slice(0, 40)}")
    guest_error("not a function")
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

  defp str_slice(s, a, rest) do
    n = byte_size(s)
    start = trunc(num(a))
    start = if start < 0, do: max(n + start, 0), else: min(start, n)
    stop = case rest do
      [b | _] when b != :undefined -> e = trunc(num(b)); if e < 0, do: max(n + e, 0), else: min(e, n)
      _ -> n
    end
    binary_part(s, start, max(stop - start, 0))
  end

  # substring(a,b): clamps to [0,len], swaps if a>b (JS semantics), no negatives.
  defp str_substring(s, a, rest) do
    len = byte_size(s)
    a = a |> trunc() |> max(0) |> min(len)
    b = case rest do [x | _] when is_number(x) -> x |> trunc() |> max(0) |> min(len); _ -> len end
    lo = min(a, b)
    binary_part(s, lo, max(a, b) - lo)
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
  def construct({:global, "Object"}, _), do: cell_new([])
  def construct({:global, "Set"}, args) do
    id = __id()
    init = case args do [{:arr, _} = av | _] -> Enum.uniq(al(av)); _ -> [] end
    Process.put({:gg_set, id}, init)
    {:set, id}
  end

  def construct({:global, "Map"}, args) do
    id = __id()
    init = case args do [{:arr, _} = av | _] -> Enum.map(al(av), fn e -> case (if match?({:arr,_},e), do: al(e), else: []) do [k, v | _] -> {k, v}; _ -> {:undefined, :undefined} end end); _ -> [] end
    Process.put({:gg_map, id}, init)
    {:map, id}
  end

  def construct(_not_ctor, _args), do: guest_error("not a constructor")

  @doc "Invoke a guest function with an explicit `this` receiver (method call). Ungranted callees error."
  def invoke({:fn, f}, this, args) when is_function(f, 2), do: f.(this, args)
  def invoke({:host, cap_id}, _this, args), do: host_call(cap_id, args)
  def invoke(_not_callable, _this, _args), do: guest_error("not a function")

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
  def call(nc, _args) do
    if System.get_env("GAPLOG"), do: IO.puts(:stderr, "GAP call on #{inspect(nc) |> String.slice(0, 40)}")
    guest_error("not a function")
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
  def binop(_op, _a, _b), do: guest_error("bad operands")

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
  def guest_error(reason), do: throw({:gg_guest_error, reason})

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
