defmodule TinyLasers.Wasm.Transpile do
  @moduledoc """
  **Wasm's wasm→BEAM transpiler.** The second execution backend: instead of *interpreting* the
  structured instruction tree, it *compiles* a wasm function to a real BEAM function (Erlang abstract
  forms → `:compile.forms` → `:code.load_binary`), so it runs on the BeamAsm JIT at native-ish speed
  while inheriting the same isolation (it's still ordinary BEAM code in a process).

  ## How it works

  A wasm function is already *structured* (no arbitrary gotos), and its operand stack is a compile-time
  artifact — so we **compile the stack away**: we fold the instruction list maintaining a compile-time
  stack of Erlang *expressions* (not values). `local.get` pushes a local var, `i32.const` pushes a
  literal, `i32.add` pops two operands and pushes `(A + B) band 16#FFFFFFFF`. No operand stack survives
  to runtime — it became the shape of the generated AST (SSA).

  ### Locals — SSA renaming (locals live in BEAM registers, not a runtime tuple)
  Each wasm local maps to a *current* Erlang variable. `local.set i`/`local.tee i` mints a fresh var,
  binds it, and updates the per-local "current var" map. Maximally JIT-friendly.

  ### Control flow — native Erlang
    * `if`/`else`  → an Erlang `case` on the condition. Each arm runs, then the live locals + a single
      result value are bundled into a tuple so the post-merge is one pattern match.
    * `loop`       → a recursive named Erlang fun; a `br` to the loop label is a tail call (the next
      iteration), passing the live locals.
    * `block`      → a recursive-fun "join point" too: a `block` introduces a forward label, and a
      `br` to it / fallthrough both produce the block's result + locals, which the continuation matches.
      We model the whole region functionally: a construct compiles to a value+locals it yields.

  We use a **functional region model**: lowering a (possibly nested) instruction sequence yields, at
  compile time, a single Erlang expression that evaluates to `{ResultStack, LocalsTuple}` *unless* an
  early `br`/`return` escapes the region — escapes are realized with `throw`/`catch` carrying the
  target label depth, caught at the matching `block`/`loop`/function boundary. This mirrors the
  interpreter's signal protocol exactly (correct against the oracle) while compiling to native control
  flow and keeping locals in variables.

  Anything outside the supported surface returns `{:error, {:unsupported, op}}` — **never wrong code**.

  ### Direct calls
  `call` to another *local* function is supported: every reachable callee is compiled into the same
  loaded BEAM module and invoked directly. Calls to imports/host functions are out of scope.
  """
  import Bitwise
  @mask32 0xFFFFFFFF
  @mask64 0xFFFFFFFFFFFFFFFF
  @page_words 8192
  @ln 1

  # ── public API ──────────────────────────────────────────────────────────────────────────────────

  @doc """
  Compile exported function `name` to a native BEAM function. Returns `{:ok, fun}` where `fun` takes
  the argument LIST, or `{:error, {:unsupported, op}}` if it falls outside the supported surface.
  """
  def compile(mod, name) do
    try do
      fidx = export_fidx!(mod, name)
      {mname, idx_to_fun} = build_module(mod, [fidx])
      {fname, arity} = Map.fetch!(idx_to_fun, fidx)

      fun = fn args ->
        if length(args) != arity, do: throw({:tl_arity, fidx})
        # Mirror the interpreter's per-call runtime setup so memory ops compare fairly against the
        # oracle: a fresh packed `:atomics` linear memory in `:tl_mem`, sized to the module's min
        # pages, with active data segments copied in. The generated code reads/writes this SAME memory
        # (identical packed byte access), so transpiled load/store match the interpreter exactly.
        prev_mem = Process.get(:tl_mem)
        prev_globals = Process.get(:tl_globals)
        setup_memory(mod)
        Process.put(:tl_globals, TinyLasers.Wasm.init_globals(mod))

        try do
          apply(mname, fname, args)
        after
          if prev_mem == nil, do: Process.delete(:tl_mem), else: Process.put(:tl_mem, prev_mem)
          if prev_globals == nil, do: Process.delete(:tl_globals), else: Process.put(:tl_globals, prev_globals)
        end
      end

      {:ok, fun}
    catch
      {:unsupported, op} -> {:error, {:unsupported, op}}
    end
  end

  @doc """
  **Per-function TIERED compile** — the end-to-end runner's path for whole, real command modules
  (shell, quickjs, …). Unlike `compile/2` (all-or-nothing for one call graph), this transpiles EACH
  reachable function independently: a function that lowers cleanly becomes native BEAM; one that hits
  an unsupported op is simply LEFT to the interpreter. Native functions call transpiled callees
  directly (fast) and trampoline (`TinyLasers.Wasm.call_local`) into the interpreter for the rest — all on
  the SAME shared `:tl_mem`/`:tl_globals`/fuel state, so the two lanes are seamless and the
  result is bit-identical to a pure-interpreter run (oracle-gated).

  Returns `{:ok, jit}` where `jit` maps `global_fidx => {beam_module, fname, arity}`. Empty map = no
  function transpiled (run is pure interpreter). `TinyLasers.Wasm.call_io(mod, name, args, transpile: true)`
  installs the jit so the interpreter dispatches hot leaves to native code.
  """
  @doc """
  Memoized `tier/2`. Compiling + loading a module's native functions costs ~seconds, so we do it ONCE
  per distinct (module, entry) and reuse the loaded BEAM module forever (it stays resident in the code
  server; the cached jit map keeps referencing it). Keyed by a content hash of the tier-relevant module
  fields — two byte-identical modules share one build. This is the seam production runs go through.
  """
  def tier_cached(mod, entry) do
    # O(1) key when the module carries its content-hash id (set by decode_cached). Hand-built modules
    # (tests/fuzzer) have no id → fall back to a COLLISION-FREE sha of the structure, not phash2: a
    # 27-bit phash2 collides across a large differential-fuzz corpus and would serve a wrong cached build.
    id = mod.id || :crypto.hash(:sha256, :erlang.term_to_binary({mod.types, mod.funcs, mod.code, mod.imports, mod.elements}))
    key = {id, entry}

    case TinyLasers.Wasm.JitCache.get({:tier, key}) do
      :miss ->
        result = tier(mod, entry)
        # only cache a successful build; a failed/empty tier is cheap to recompute and may be transient
        if match?({:ok, _}, result), do: TinyLasers.Wasm.JitCache.put({:tier, key}, result)
        result

      {:ok, jit} = cached ->
        # LAZY eviction validation: the pool may have recycled a tier module's atom. If any cached MFA's
        # module is no longer loaded, the build is dead — drop it and recompile into a fresh slot.
        if jit == %{} or Enum.all?(jit, fn {_g, {m, _f, _a}} -> TinyLasers.Wasm.ModulePool.loaded?(m) end) do
          cached
        else
          TinyLasers.Wasm.JitCache.delete({:tier, key})
          tier_cached(mod, entry)
        end

      cached ->
        cached
    end
  end

  # functions per shared BEAM module when batching (prewarm + lazy chunk compile) — bounds each compile
  # while collapsing module-name atoms from O(functions) to O(functions / @batch_funcs).
  @batch_funcs 48

  # Disable the expensive optimizer passes — `beam_ssa_opt` is SUPERLINEAR (the source of the multi-second
  # "hangs" on our large generated forms), and our codegen is already explicit, so it gains little.
  # MUST be defined before its first use (build_forms_module) — a forms compile with this attribute nil
  # (default opts) re-enables ssa_opt and reintroduces the hang. Correctness is oracle/fuzzer-gated.
  @compile_opts [:return_errors, :no_ssa_opt, :no_type_opt, :no_bool_opt]

  @doc """
  **LAZY hot-path compile** — when function `gfidx` gets hot, compile the whole CHUNK it belongs to
  (`@batch_funcs` neighbouring functions) into shared BEAM modules ONCE, caching every function in the
  chunk, then return this function's `{:ok, {module, fun, arity}}` / `:error`. Chunk-on-demand keeps the
  lazy "pay only for the working set" property (only chunks containing a hot function compile) while
  bounding module-name atoms to O(functions / @batch_funcs) — the atom-table wall fix (wb-65ak) applied to
  the lazy path, not just prewarm. Cached in ETS (`JitCache`) so a chunk compiles at most once, ever.
  """
  def compile_one(mod, gfidx) do
    # `cached_one` does LAZY eviction validation: a cached MFA whose pool module was recycled reads back as
    # `:miss` (and is dropped), so an evicted function falls into the recompile path below — recompiling
    # into a FRESH pool slot rather than dispatching dead code.
    case mod.id && cached_one(mod.id, gfidx) do
      :miss ->
        compile_chunk(mod, gfidx)
        # every function in the chunk is now cached ({:ok, mfa} or :error); read this one back (validated).
        cached_one(mod.id, gfidx)

      nil ->
        # id-less module (can't cache/dedup) → compile this one function alone.
        build_one(mod, gfidx)

      cached ->
        cached
    end
  end

  # Compile the @batch_funcs-sized chunk containing `gfidx` into ONE shared ASM module, caching an outcome
  # for EVERY function in the chunk so it never recompiles. ASM-ONLY by design: the asm lane compiles
  # ~linearly (cheap), so batching a whole chunk is fast; the forms lane is superlinear, so forms-compiling
  # whole cold chunks on the hot path is too slow (it timed the tier test out). Non-asm functions stay
  # INTERPRETED here (cached :error) — explicit `prewarm/2` is where we pay to forms-compile them native.
  defp compile_chunk(mod, gfidx) do
    ni = length(mod.imports)
    li = gfidx - ni
    start = div(li, @batch_funcs) * @batch_funcs
    last = min(start + @batch_funcs, length(mod.code)) - 1
    chunk = for i <- start..last//1, do: ni + i

    {asm_map, tok} =
      case TinyLasers.Wasm.TranspileAsm.compile_module(mod, chunk) do
        {:ok, _m, map, _leftover, t} -> {map, t}
        _ -> {%{}, nil}
      end

    Enum.each(chunk, fn g ->
      case Map.get(asm_map, g) do
        nil -> TinyLasers.Wasm.JitCache.put({:hot, mod.id, g}, :error)
        # pin the pool generation `tok` so a later lookup detects this slot being recycled to other code.
        mfa -> TinyLasers.Wasm.JitCache.put({:hot, mod.id, g}, {:ok, mfa, tok})
      end
    end)

    :ok
  end

  @doc """
  Read the JIT cache for `(mod_id, gfidx)`: `{:ok, native}` / `:error` / `:miss`. O(1) ETS lookup.

  **Lazy eviction validation (atom-pool fix):** generated modules live in a FIXED recycled atom pool
  (`TinyLasers.Wasm.ModulePool`), so a cached MFA can be DANGLING — the pool may have recycled that atom for a
  DIFFERENT program. Two failure modes, both caught here via the pinned pool generation `tok`:
    * the slot was displaced (`:code.soft_purge`) and never reloaded → module not loaded; OR
    * the slot's atom was reloaded with NEW code (still `module_loaded`, but the OLD MFA now points at the
      wrong function) → the pool's generation token advanced.
  `ModulePool.valid?/2` checks BOTH (loaded AND token matches). A failing hit is treated as a MISS (and the
  stale entry deleted), so dispatch transparently recompiles into a fresh slot. Returns the public
  `{:ok, {m,f,a}}` shape (token stripped) so callers/dispatch are unchanged.
  """
  def cached_one(nil, _gfidx), do: :miss

  def cached_one(mod_id, gfidx) do
    key = {:hot, mod_id, gfidx}

    case TinyLasers.Wasm.JitCache.get(key) do
      {:ok, {module, _f, _a} = mfa, tok} ->
        if TinyLasers.Wasm.ModulePool.valid?(module, tok) do
          {:ok, mfa}
        else
          # the pool recycled this atom (purged, or reloaded with other code) → the MFA is dead. Drop it
          # and report a miss so the caller recompiles into a fresh slot.
          TinyLasers.Wasm.JitCache.delete(key)
          :miss
        end

      other ->
        other
    end
  end

  @doc """
  **Pre-warm a fixed module** (AOT, the goal's 'native from the first call'). Eagerly `compile_one`s
  every reachable function (the same fast per-function unit the lazy path uses — NOT the whole-module
  `tier/2`, whose single giant `:compile.forms` doesn't scale), seeding the per-function cache so
  subsequent guest runs dispatch native immediately with no per-run warmup. Idempotent + cached. Returns
  the count compiled. Use `prewarm_async/2` for big modules so boot/first-use never blocks on the build.
  """
  def prewarm(mod, entry \\ "_start", asm_only? \\ false) do
    ni = length(mod.imports)
    table = build_table(mod)
    roots = (entry_fidx(mod, entry, ni) ++ (table |> Map.values() |> Enum.filter(&(&1 >= ni)))) |> Enum.uniq()
    reachable = reach(mod, ni, roots, MapSet.new()) |> MapSet.to_list()

    # FULL prewarm (wb-65ak): batch reachable functions in chunks — each chunk's asm-lowerable funcs → ONE
    # shared asm module, the REST → ONE shared forms module (build_forms_module). Unlike the lazy path
    # (asm-only, for latency), explicit prewarm pays to forms-compile the non-asm functions so a fixed
    # shared module (coreutils/qjs/shell) is FULLY native at boot. Atoms grow O(functions / @batch_funcs).
    # `native` maps gfidx => {mfa, pool_token}: the token is pinned in the cache so a later lookup detects
    # the pool recycling that slot to other code (see cached_one/2).
    #
    # `asm_only?` (the Porffor lane): skip the abstract-forms fallback and leave asm-unsupported funcs
    # INTERPRETED. Both asm + forms lanes are now multi-value-aware (Porffor's [value,type] pairs lower to
    # a top-first result list across the asm↔interp boundary), but the forms lane still has a pre-existing
    # f64-global miscompile (`global_set` masks i32 unconditionally), so for f64-heavy Porffor we prewarm
    # only via the proven-bit-identical asm lane. i32-dominated modules keep the full asm+forms prewarm.
    native =
      reachable
      |> Enum.chunk_every(@batch_funcs)
      |> Enum.reduce(%{}, fn chunk, acc ->
        {asm_map, asm_leftover} =
          case TinyLasers.Wasm.TranspileAsm.compile_module(mod, chunk) do
            {:ok, _m, map, leftover, tok} -> {tag_token(map, tok), leftover}
            _ -> {%{}, chunk}
          end

        forms_map = if asm_only?, do: %{}, else: build_forms_module(mod, asm_leftover) |> elem(0)
        acc |> Map.merge(asm_map) |> Map.merge(forms_map)
      end)

    if mod.id, do: Enum.each(native, fn {gfidx, {mfa, tok}} -> TinyLasers.Wasm.JitCache.put({:hot, mod.id, gfidx}, {:ok, mfa, tok}) end)
    map_size(native)
  end

  # tag every {gfidx => mfa} entry with the pool generation token it was compiled under.
  defp tag_token(map, tok), do: Map.new(map, fn {g, mfa} -> {g, {mfa, tok}} end)

  # Compile `gfidxs` into ONE shared abstract-forms BEAM module, skipping functions with unsupported ops
  # (those stay interpreted). Returns `{%{gfidx => {module, fun, arity}}, leftover_gfidxs}`.
  defp build_forms_module(_mod, []), do: {%{}, []}

  defp build_forms_module(mod, gfidxs) do
    # Module name from the FIXED recycled atom pool (atom-table wall fix). `:exhausted` ⇒ every slot holds
    # a live module ⇒ leave this whole chunk interpreted (return all gfidxs as leftover). The returned map
    # tags each gfidx => {mfa, pool_token} so prewarm can pin the generation in the cache.
    case TinyLasers.Wasm.ModulePool.acquire() do
      {:ok, mname, tok} -> build_forms_module(mod, gfidxs, mname, tok)
      :exhausted -> {%{}, gfidxs}
    end
  end

  defp build_forms_module(mod, gfidxs, mname, tok) do
    ni = length(mod.imports)
    table = build_table(mod)

    {functions, exports, map, leftover} =
      Enum.reduce(gfidxs, {[], [], %{}, []}, fn gfidx, {fs, exs, m, lo} ->
        arity = fn_arity(mod, ni, gfidx)
        fname = :"wf_#{gfidx}"
        # empty calls-map → every call trampolines via call_local (atom-bounded; same as the asm lane).
        try do
          func = compile_fn(mod, gfidx, ni, fname, arity, %{}, table)
          {[func | fs], [{fname, arity} | exs], Map.put(m, gfidx, {{mname, fname, arity}, tok}), lo}
        catch
          _, _ -> {fs, exs, m, [gfidx | lo]}
        end
      end)

    if functions == [] do
      {%{}, gfidxs}
    else
      forms = [{:attribute, @ln, :module, mname}, {:attribute, @ln, :export, exports}] ++ functions

      case :compile.forms(forms, @compile_opts) do
        {:ok, ^mname, bin} ->
          {:module, ^mname} = :code.load_binary(mname, ~c"nofile", bin)
          {map, leftover}

        _ ->
          {%{}, gfidxs}
      end
    end
  end

  def prewarm_async(mod, entry \\ "_start") do
    Task.start(fn -> prewarm(mod, entry) end)
    :ok
  end

  # at most this many functions before a module is too big to prewarm cheaply (coreutils = 5289 →
  # stays lazy/interp; a single-purpose compute CLI ≈ tens of funcs → prewarm, native from call 1).
  @prewarm_func_cap 512

  @doc """
  **Bounded prewarm for the compiled-program lane.** A single-purpose compute CLI is one `main()` with
  an internal hot loop — call-count tiering never fires (main is invoked once), so the win only lands if
  we compile reachable functions UP FRONT. We do that iff the module is small enough to prewarm cheaply
  (`@prewarm_func_cap`); big multicall modules (coreutils) stay lazy. Cross-run cached, so the build is
  paid once per binary. Returns `{:prewarmed, n}` or `:skipped`.
  """
  def prewarm_bounded(mod, entry \\ "_start", asm_only? \\ false) do
    if length(mod.funcs) <= @prewarm_func_cap do
      {:prewarmed, prewarm(mod, entry, asm_only?)}
    else
      :skipped
    end
  end

  @doc """
  Compile `gfidx` in the BACKGROUND (fire-and-forget) — used by the async tier mode so a guest run
  never blocks on a compile storm. The result lands in the persistent cache (`compile_one` caches it),
  where the in-flight run picks it up via `cached_one/2` on a later call. Only meaningful for modules
  with an `id` (so the cache is keyed + retrievable); a no-op-ish spawn otherwise.

  Routes through `TinyLasers.Wasm.Transpile.AsyncCompiler` — a bounded QUEUE (up to
  `@max_inflight` concurrent compiles) that NEVER drops a hot function: excess compiles wait their
  turn instead of being silently discarded (the old `:atomics`-gate dropped them, leaving hot
  dispatchers `:pending` → interpreted for every call). CPU is still bounded so compilation never
  starves the interpreter.
  """
  def compile_one_async(mod, gfidx) do
    TinyLasers.Wasm.Transpile.AsyncCompiler.enqueue(mod, gfidx)
  end

  # Complexity ceiling: above this many (flattened) instructions a function's generated Erlang form is
  # large enough that `:compile.forms` cost (superlinear in the locals×nesting it threads) outweighs any
  # run-time win — and such functions are almost always cold (parsers/dispatchers called once), so the
  # interpreter handles them fine. Keeping them interpreted bounds compile latency everywhere (lazy
  # background AND prewarm). Hot code is small; this never excludes a real hot loop.
  @max_compile_instrs 2000
  # Nesting-depth ceiling. The structured→expression lowering carries the comp-stack + locals tuple into
  # each control construct, which blows up SUPERLINEARLY with depth for deeply-nested functions (shell/
  # parser dispatchers, depth 15-20) — to the point of hanging. Such functions are invariably cold
  # (called once per command), so the interpreter handles them fine. Skip them BEFORE lowering (a cheap
  # depth count) so we never even start the runaway. A real hot loop is shallow; this never excludes one.
  @max_compile_depth 24
  # Hard wall-clock cap on a single function's compile. Generated forms can blow up superlinearly in
  # `:compile.forms` for certain shapes (deep nesting × many locals → a variable explosion the Erlang
  # compiler is slow on). Rather than predict it, we just KILL any compile that overruns and leave that
  # function interpreted. Bounds compile latency for both the background-lazy and prewarm paths.
  @compile_timeout_ms 2_000
  # heap ceiling (words) for a single compile worker — ~400MB; an exponential lowering trips it in well
  # under a second and the worker is killed, leaving the function interpreted.
  @compile_heap_words 50_000_000

  defp build_one(mod, gfidx) do
    ni = length(mod.imports)
    fname = :"wf_#{gfidx}"
    arity = fn_arity(mod, ni, gfidx)
    {_arity, _nlocals, instrs} = function_body(mod, gfidx, ni)

    cond do
      instr_count(instrs) > @max_compile_instrs or instr_depth(instrs, 0) > @max_compile_depth ->
        :error

      # Tier-1a: the BEAM-assembly lane (wb-wzdq) — skips the Erlang frontend + beam_ssa_opt entirely.
      # Bit-identical (oracle/fuzzer gated) and fuel-safe; returns :unsupported for ops it doesn't cover
      # yet, so we fall through to the abstract-forms lane (Tier-1b) for those functions.
      match?({:ok, _}, asm = TinyLasers.Wasm.TranspileAsm.try_emit(mod, gfidx)) ->
        asm

      true ->
        compile_bounded(mod, gfidx, ni, fname, arity)
    end
  end

  # Run the compile in a HEAP-BOUNDED process. The lowering can blow up exponentially for some shapes
  # (the cheap depth/size caps don't catch all of them); rather than predict it, cap the worker's heap —
  # the BEAM kills it the instant it overruns (sub-second on exponential growth), and we leave that
  # function interpreted. A wall-clock timeout backstops any non-allocating slowness.
  defp compile_bounded(mod, gfidx, ni, fname, arity) do
    parent = self()
    ref = make_ref()

    {pid, mon} =
      :erlang.spawn_opt(
        fn -> send(parent, {ref, build_one_compile(mod, gfidx, ni, fname, arity)}) end,
        [:monitor, {:max_heap_size, %{size: @compile_heap_words, kill: true, error_logger: false}}]
      )

    receive do
      {^ref, result} ->
        Process.demonitor(mon, [:flush])
        result

      {:DOWN, ^mon, _, _, _} ->
        :error
    after
      @compile_timeout_ms ->
        Process.exit(pid, :kill)
        :error
    end
  end

  defp build_one_compile(mod, gfidx, ni, fname, arity) do
    try do
      form = gen_fn(mod, gfidx, ni, %{}, build_table(mod))

      case TinyLasers.Wasm.ModulePool.acquire() do
        :exhausted ->
          :error

        {:ok, mname, _tok} ->
          forms = [{:attribute, @ln, :module, mname}, {:attribute, @ln, :export, [{fname, arity}]}, form]

          case :compile.forms(forms, @compile_opts) do
            {:ok, ^mname, bin} ->
              {:module, ^mname} = :code.load_binary(mname, ~c"nofile", bin)
              {:ok, {mname, fname, arity}}

            _ ->
              :error
          end
      end
    rescue
      _ -> :error
    catch
      _, _ -> :error
    end
  end

  def tier(mod, entry) do
    ni = length(mod.imports)
    table = build_table(mod)
    roots = (entry_fidx(mod, entry, ni) ++ (table |> Map.values() |> Enum.filter(&(&1 >= ni)))) |> Enum.uniq()
    reachable = reach(mod, ni, roots, MapSet.new()) |> MapSet.to_list() |> Enum.sort()

    # name every reachable local fn up front (stable names across both passes)
    names = Map.new(reachable, fn fidx -> {fidx, {:"wf_#{fidx}", fn_arity(mod, ni, fidx)}} end)

    # PASS 1 — which functions compile? Try each in ISOLATION (all callees trampolined, so the verdict
    # depends only on the function's own ops). A function that throws :unsupported OR fails to compile
    # to valid Erlang is dropped to the interpreter lane.
    # debug seam: when `:tl_tier_only` holds a MapSet of fidxs, restrict transpilation to it (used to
    # bisect a tiered/interp divergence down to the offending function). Absent ⇒ tier everything possible.
    only = Process.get(:tl_tier_only)
    reachable = if only, do: Enum.filter(reachable, &MapSet.member?(only, &1)), else: reachable

    ok = Enum.filter(reachable, fn fidx -> compilable?(mod, fidx, ni, names, table) end)
    compiled = Map.take(names, ok)

    if compiled == %{} do
      {:ok, %{}}
    else
      # PASS 2 — regenerate with direct calls among the compiled set, assemble + load one BEAM module.
      forms = for fidx <- ok, do: gen_fn(mod, fidx, ni, compiled, table)

      case TinyLasers.Wasm.ModulePool.acquire() do
        :exhausted ->
          {:ok, %{}}

        {:ok, mname, _tok} ->
          exports = for {_fidx, {fname, ar}} <- compiled, do: {fname, ar}
          all = [{:attribute, @ln, :module, mname}, {:attribute, @ln, :export, exports}] ++ forms

          case :compile.forms(all, @compile_opts) do
            {:ok, ^mname, bin} ->
              {:module, ^mname} = :code.load_binary(mname, ~c"nofile", bin)
              {:ok, Map.new(compiled, fn {fidx, {fname, ar}} -> {fidx, {mname, fname, ar}} end)}

            {:error, _errs, _w} ->
              # a cross-function assembly error (should not happen — each passed solo in PASS 1) → degrade
              # gracefully to pure interpreter rather than emit wrong code.
              {:ok, %{}}
          end
      end
    end
  end

  @doc false
  def __gen_one__(mod, fidx) do
    ni = length(mod.imports)
    gen_fn(mod, fidx, ni, %{}, build_table(mod))
  end

  defp entry_fidx(mod, name, ni) do
    case Map.get(mod.exports, name) do
      nil -> []
      fidx when fidx >= ni -> [fidx]
      _ -> []
    end
  end

  @doc "Transitive closure of local function indices reachable from export `entry` (default `\"m\"`)."
  def reachable_gfidxs(mod, entry \\ "m") do
    ni = length(mod.imports)
    roots = entry_fidx(mod, entry, ni)
    reach(mod, ni, roots, MapSet.new()) |> MapSet.to_list() |> Enum.sort()
  end

  defp fn_arity(mod, ni, fidx), do: (function_body(mod, fidx, ni) |> elem(0))

  # transitive closure of LOCAL callees reachable from `roots` (scans call sites without lowering, so
  # it's safe even for functions that won't transpile).
  defp reach(_mod, _ni, [], seen), do: seen
  defp reach(mod, ni, [fidx | rest], seen) do
    if MapSet.member?(seen, fidx) or fidx < ni do
      reach(mod, ni, rest, seen)
    else
      {_arity, _nlocals, instrs} = function_body(mod, fidx, ni)
      callees = for {:call, c} <- flatten_calls(instrs), c >= ni, do: c
      reach(mod, ni, callees ++ rest, MapSet.put(seen, fidx))
    end
  end

  # PASS 1 verdict: does `fidx` lower AND compile to valid Erlang on its own (all callees trampolined)?
  defp compilable?(mod, fidx, ni, names, table) do
    {fname, _ar} = Map.fetch!(names, fidx)

    try do
      # %{} calls-map ⇒ every local callee trampolines, so the form is self-contained.
      form = gen_fn(mod, fidx, ni, %{}, table)
      # A FIXED probe module name — the probe is compiled but NEVER loaded (we only check it compiles to
      # valid Erlang), so the same atom is safe to reuse for every probe and the atom table never grows.
      probe = :tl_probe
      forms = [{:attribute, @ln, :module, probe}, {:attribute, @ln, :export, [{fname, fn_arity(mod, ni, fidx)}]}, form]
      match?({:ok, ^probe, _bin}, :compile.forms(forms, @compile_opts))
    rescue
      # a raised exception during lowering (e.g. an unhandled op shape) ⇒ leave the function to the
      # interpreter rather than crash the whole tier build. Tiering must degrade gracefully, never abort.
      _ -> false
    catch
      # an unsupported op is the expected "interpret this one" signal; any other throw/exit ⇒ same.
      {:unsupported, _} -> false
      _kind, _reason -> false
    end
  end

  # build a single function form against a given compiled-callees map (`calls`).
  defp gen_fn(mod, fidx, ni, calls, table) do
    {fname, arity} = {:"wf_#{fidx}", fn_arity(mod, ni, fidx)}
    compile_fn(mod, fidx, ni, fname, arity, calls, table)
  end

  defp export_fidx!(mod, name) do
    fidx = Map.fetch!(mod.exports, name)
    ni = length(mod.imports)
    if fidx < ni, do: throw({:unsupported, :imported_function})
    fidx
  end

  # ── module assembly ──────────────────────────────────────────────────────────────────────────────

  defp build_module(mod, roots) do
    ni = length(mod.imports)
    # function table (idx → global func index), const-folded from active element segments — every
    # table entry is a potential call_indirect target, so seed it as a compile root.
    table = build_table(mod)
    # only LOCAL funcs can be compiled-in; an indirect call landing on an import is out of scope and
    # traps :unsupported at lowering — but don't fail to collect just because the table mentions one.
    table_roots = table |> Map.values() |> Enum.filter(&(&1 >= ni))
    idx_to_fun = collect(mod, roots ++ table_roots, ni, %{})

    functions =
      for {fidx, {fname, arity}} <- idx_to_fun do
        compile_fn(mod, fidx, ni, fname, arity, idx_to_fun, table)
      end

    mname =
      case TinyLasers.Wasm.ModulePool.acquire() do
        {:ok, m, _tok} -> m
        :exhausted -> throw({:unsupported, :module_pool_exhausted})
      end

    exports = for {_fidx, {fname, arity}} <- idx_to_fun, do: {fname, arity}

    forms =
      [{:attribute, @ln, :module, mname}, {:attribute, @ln, :export, exports}] ++ functions

    case :compile.forms(forms, @compile_opts) do
      {:ok, ^mname, bin} ->
        {:module, ^mname} = :code.load_binary(mname, ~c"nofile", bin)
        {mname, idx_to_fun}

      {:error, errors, _warnings} ->
        throw({:unsupported, {:compile_error, errors}})
    end
  end

  # ── linear-memory setup (mirrors TinyLasers.Wasm.new_mem + init_data so the oracle compares fairly) ──
  # A fresh packed `:atomics` (8 bytes/slot, == the interpreter's layout), sized to the module's min
  # pages, installed in the process dict under `:tl_mem`; active data segments copied in.
  defp setup_memory(%{mem: nil}), do: Process.delete(:tl_mem)

  defp setup_memory(%{mem: {min, _max}} = mod) do
    pages = max(1, min)
    mem = :atomics.new(pages * @page_words, signed: false)
    Process.put(:tl_mem, mem)
    for seg <- mod.data, do: init_data_seg(mem, seg)
    :ok
  end

  defp init_data_seg(mem, {:active, offset_expr, bytes}) do
    addr = const_offset(offset_expr)
    bytes |> :binary.bin_to_list() |> Enum.with_index() |> Enum.each(fn {b, i} -> mput(mem, addr + i, b) end)
  end

  defp init_data_seg(_mem, _passive), do: :ok

  # function table (idx → global func index) from active element segments, mirroring TinyLasers.Wasm.
  # new_table. Element offsets are const-exprs (i32.const in practice); fold the same way as data.
  defp build_table(%{elements: elements}) do
    Enum.reduce(elements, %{}, fn {offset_expr, funcs}, acc ->
      base = const_offset(offset_expr)
      funcs |> Enum.with_index() |> Enum.reduce(acc, fn {f, i}, a -> Map.put(a, base + i, f) end)
    end)
  end

  # evaluate a tiny const-expr offset (active data segments use i32.const in practice). Globals in an
  # offset are uncommon and not needed by the transpile tests; default to 0 if we can't fold it.
  defp const_offset([{:i32_const, v} | _]), do: v &&& @mask32
  defp const_offset([{:i64_const, v} | _]), do: v &&& @mask64
  defp const_offset(_), do: 0

  # the interpreter's packed byte write (read-modify-write of the containing 64-bit word) — used here
  # ONLY for host-side data-segment init; guest load/store is generated as inline Erlang.
  defp mput(mem, addr, byte) do
    idx = (addr >>> 3) + 1
    sh = (addr &&& 7) * 8
    w = :atomics.get(mem, idx)
    w = ((w &&& bnot(0xFF <<< sh)) ||| ((byte &&& 0xFF) <<< sh)) &&& @mask64
    :atomics.put(mem, idx, w)
  end

  defp collect(_mod, [], _ni, acc), do: acc

  defp collect(mod, [fidx | rest], ni, acc) do
    cond do
      Map.has_key?(acc, fidx) ->
        collect(mod, rest, ni, acc)

      fidx < ni ->
        throw({:unsupported, {:call_import, fidx}})

      true ->
        {arity, _nlocals, instrs} = function_body(mod, fidx, ni)
        acc = Map.put(acc, fidx, {:"wf_#{fidx}", arity})
        # a call to an IMPORT isn't a compiled-in function — it lowers to invoke_host; only collect LOCAL callees
        callees = for {:call, c} <- flatten_calls(instrs), c >= ni, do: c
        collect(mod, callees ++ rest, ni, acc)
    end
  end

  defp function_body(mod, fidx, ni) do
    local_idx = fidx - ni
    {nlocals, instrs} = Enum.at(mod.code, local_idx)
    {params, _results} = Enum.at(mod.types, Enum.at(mod.funcs, local_idx))
    {length(params), nlocals, instrs}
  end

  # max control-nesting depth (for the compile-complexity ceiling — the lowering blows up with depth).
  defp instr_depth(instrs, d) do
    Enum.reduce(instrs, d, fn
      {:block, _n, b}, a -> max(a, instr_depth(b, d + 1))
      {:loop, _n, b}, a -> max(a, instr_depth(b, d + 1))
      {:if, _n, t, e}, a -> max(a, max(instr_depth(t, d + 1), instr_depth(e, d + 1)))
      _, a -> a
    end)
  end

  # total instruction count, recursing into structured bodies (for the compile-complexity ceiling).
  defp instr_count(instrs) do
    Enum.reduce(instrs, 0, fn
      {:block, _n, b}, a -> a + 1 + instr_count(b)
      {:loop, _n, b}, a -> a + 1 + instr_count(b)
      {:if, _n, t, e}, a -> a + 1 + instr_count(t) + instr_count(e)
      _, a -> a + 1
    end)
  end

  defp flatten_calls(instrs) do
    Enum.flat_map(instrs, fn
      {:call, _} = c -> [c]
      {:block, _n, body} -> flatten_calls(body)
      {:loop, _n, body} -> flatten_calls(body)
      {:if, _n, t, e} -> flatten_calls(t) ++ flatten_calls(e)
      _ -> []
    end)
  end

  # Does any branch within `instrs` target the loop at relative nesting `d` (d=0 at the loop body top)?
  # A `br n` (or br_if / br_table label) targets the loop iff its label index == the current relative
  # depth. Used to decide whether a loop needs the throw/catch back-edge wrapper or can stay a pure tail
  # call (the common case: only a terminal back-edge, handled directly).
  defp continues_to_loop?(instrs, d) do
    Enum.any?(instrs, fn
      {:br, n} -> n == d
      {:br_if, n} -> n == d
      {:br_table, labels, default} -> default == d or Enum.any?(labels, &(&1 == d))
      {:block, _n, b} -> continues_to_loop?(b, d + 1)
      {:loop, _n, b} -> continues_to_loop?(b, d + 1)
      {:if, _n, t, e} -> continues_to_loop?(t, d + 1) or continues_to_loop?(e, d + 1)
      _ -> false
    end)
  end

  # ── per-function codegen ─────────────────────────────────────────────────────────────────────────
  #
  # ctx = %{lmap: %{local_idx => erl_var}, gen: counter, calls: idx_to_fun, depth: control nesting}
  # `depth` is the count of enclosing block/loop labels (for br target resolution).
  #
  # Region lowering returns {erl_stmts, comp_stack, ctx}. `erl_stmts` are side-effecting binds; the
  # function's return is the top of the final comp_stack.

  defp compile_fn(mod, fidx, ni, fname, arity, idx_to_fun, table) do
    {^arity, nlocals, instrs} = function_body(mod, fidx, ni)
    {_params_t, results} = Enum.at(mod.types, Enum.at(mod.funcs, fidx - ni))
    nresults = length(results)
    params = for i <- 0..(arity - 1)//1, do: var("A#{i}")
    {prelude, lmap} = init_locals(params, arity, nlocals)
    ctx = %{lmap: lmap, gen: 0, calls: idx_to_fun, depth: 0, labels: %{}, table: table, mod: mod, ni: ni, nresults: nresults}

    {stmts, stack, _ctx} = lower_seq(instrs, [], ctx)
    # The function's return VALUE shape mirrors the interpreter's `interp_invoke`: void → 0 (unused),
    # single → the bare top, MULTI (n>1) → a TOP-FIRST list of the top n (== interp `Enum.take`). The
    # asm/interp call boundary's `push_results/3` consumes exactly this shape.
    ret =
      cond do
        stack == :unreachable -> {:integer, @ln, 0}
        nresults <= 1 -> (case stack do [top | _] -> top; _ -> {:integer, @ln, 0} end)
        true -> result_list(stack, nresults)
      end

    # A top-level `return` throws {:tl_ret, depth_at_return, ResultList}; wrap the body to catch it
    # and re-shape the carried list to the same return value shape (bare value vs list vs 0).
    body = wrap_return(prelude ++ stmts ++ [ret], nresults)
    {:function, @ln, fname, arity, [{:clause, @ln, params, [], body}]}
  end

  defp init_locals(params, arity, nlocals) do
    base = for {p, i} <- Enum.with_index(params), into: %{}, do: {i, p}
    if nlocals == 0 do
      {[], base}
    else
      Enum.reduce(0..(nlocals - 1)//1, {[], base}, fn k, {ss, m} ->
        idx = arity + k
        v = var("Ld#{idx}")
        {ss ++ [{:match, @ln, v, {:integer, @ln, 0}}], Map.put(m, idx, v)}
      end)
    end
  end

  # body that may `throw({:tl_ret, _, ResultList})` → catch it and return the value in the function's
  # result shape: void → 0, single → the bare element, MULTI → the carried list as-is (top-first).
  defp wrap_return(body, nresults \\ 1) do
    if nresults > 1 do
      lv = var("_RetL")

      catch_multi =
        {:clause, @ln,
         [catch_pat({:tuple, @ln, [{:atom, @ln, :tl_ret}, {:var, @ln, :_}, lv]})],
         [], [lv]}

      [{:try, @ln, body, [], [catch_multi], []}]
    else
      rv = var("_RetV")

      catch_clause =
        {:clause, @ln,
         [catch_pat({:tuple, @ln, [{:atom, @ln, :tl_ret}, {:var, @ln, :_}, {:cons, @ln, rv, {nil, @ln}}]})],
         [], [rv]}

      catch_void =
        {:clause, @ln,
         [catch_pat({:tuple, @ln, [{:atom, @ln, :tl_ret}, {:var, @ln, :_}, {nil, @ln}]})],
         [], [{:integer, @ln, 0}]}

      [{:try, @ln, body, [], [catch_clause, catch_void], []}]
    end
  end

  # an Erlang `try ... catch` clause pattern is `{Class, Reason, Stacktrace}`; we only ever throw, so
  # match `{throw, <reason>, _}`.
  defp catch_pat(reason_pat) do
    {:tuple, @ln, [{:atom, @ln, :throw}, reason_pat, {:var, @ln, :_}]}
  end

  # an Erlang list literal of arg expressions (for invoke_host's arg list)
  defp list_ast([]), do: {nil, @ln}
  defp list_ast([h | t]), do: {:cons, @ln, h, list_ast(t)}

  # `erlang:get(tl_globals)` — the mutable globals array, installed by the runner
  defp globals_ref, do: {:call, @ln, {:remote, @ln, {:atom, @ln, :erlang}, {:atom, @ln, :get}}, [{:atom, @ln, :tl_globals}]}
  defp mem_pages_ref, do: {:call, @ln, {:remote, @ln, {:atom, @ln, :erlang}, {:atom, @ln, :get}}, [{:atom, @ln, :tl_mem_pages}]}
  defp atomics_remote(f), do: {:remote, @ln, {:atom, @ln, :atomics}, {:atom, @ln, f}}

  # ── sequence + straight-line lowering ────────────────────────────────────────────────────────────

  defp lower_seq(instrs, stack, ctx) do
    Enum.reduce(instrs, {[], stack, ctx}, fn instr, {stmts, st, c} ->
      {ns, st, c} = lower(instr, st, c)
      {stmts ++ ns, st, c}
    end)
  end

  # once a sequence becomes :unreachable, subsequent ops are dead code (the wasm validator still
  # type-checks them, but they never run). Swallow them — folding the comp-stack would be ill-defined.
  defp lower(_instr, :unreachable, ctx), do: {[], :unreachable, ctx}

  defp lower({:i32_const, v}, stack, ctx), do: {[], [{:integer, @ln, v &&& @mask32} | stack], ctx}
  defp lower({:local_get, i}, stack, ctx), do: {[], [Map.fetch!(ctx.lmap, i) | stack], ctx}

  defp lower({:local_set, i}, [v | stack], ctx) do
    {stmt, ctx} = bind_local(i, v, ctx)
    {[stmt], stack, ctx}
  end

  defp lower({:local_tee, i}, [v | rest], ctx) do
    {stmt, ctx} = bind_local(i, v, ctx)
    {[stmt], [Map.fetch!(ctx.lmap, i) | rest], ctx}
  end

  # select (0x1B): `c ? a : b` — a THREE-operand op, so it can't go through the 2-operand binop path.
  # Pop c (top), b, a; push `case c /= 0 -> a ; -> b`. (The single biggest coverage gap: 417× in quickjs,
  # 1593× in coreutils — Rust/clang emit it constantly for branchless conditionals.)
  defp lower({:op, 0x1B}, [c, b, a | rest], ctx) do
    {av, ctx} = fresh(ctx, "Sa")
    {bv, ctx} = fresh(ctx, "Sb")
    {cv, ctx} = fresh(ctx, "Sc")
    {rv, ctx} = fresh(ctx, "Sr")

    sel =
      {:match, @ln, rv,
       {:case, @ln, {:op, @ln, :"/=", cv, {:integer, @ln, 0}},
        [
          {:clause, @ln, [{:atom, @ln, true}], [], [av]},
          {:clause, @ln, [{:atom, @ln, false}], [], [bv]}
        ]}}

    binds = [{:match, @ln, av, a}, {:match, @ln, bv, b}, {:match, @ln, cv, c}, sel]
    {binds, [rv | rest], ctx}
  end

  defp lower({:op, opcode}, stack, ctx) do
    n = op_pops(opcode)
    expr = apply_op(opcode, stack)
    # bind the op result so it isn't recomputed if the stack value is consumed by multiple ops.
    {v, ctx} = fresh(ctx, "V")
    {[{:match, @ln, v, expr}], [v | drop(stack, n)], ctx}
  end

  defp lower({:call, fidx}, stack, ctx) when fidx >= 0 do
    if fidx < ctx.ni do
      # a HOST IMPORT (WASI/host_exec) → the invoke_host seam, which dispatches to the same call_host the
      # interpreter uses (identical I/O). proc_exit etc. throw through, caught by the runner.
      spec = Enum.at(ctx.mod.imports, fidx)
      {params, results} = func_type(ctx.mod, ctx.ni, fidx)
      {args, rest} = Enum.split(stack, length(params))

      call =
        {:call, @ln, {:remote, @ln, {:atom, @ln, :"Elixir.TinyLasers.Wasm"}, {:atom, @ln, :invoke_host}},
         [:erl_parse.abstract(spec, @ln), list_ast(Enum.reverse(args))]}

      {v, ctx} = fresh(ctx, "H")
      push_call_result(v, call, length(results), rest, ctx)
    else
      {params, results} = func_type(ctx.mod, ctx.ni, fidx)
      {args, rest} = Enum.split(stack, length(params))

      call =
        case Map.get(ctx.calls, fidx) do
          {fname, _arity} ->
            # callee is transpiled in THIS module → a direct native BEAM call (the speed win).
            {:call, @ln, {:atom, @ln, fname}, Enum.reverse(args)}

          nil ->
            # callee is NOT transpiled (interpreted lane) → trampoline back into the interpreter via
            # `call_local`, which runs it on the SAME shared memory/globals/fuel state. This is what
            # makes PER-FUNCTION tiering correct: a hot native fn can still call a cold interpreted one.
            {:call, @ln, {:remote, @ln, {:atom, @ln, :"Elixir.TinyLasers.Wasm"}, {:atom, @ln, :call_local}},
             [{:integer, @ln, fidx}, list_ast(Enum.reverse(args))]}
        end

      {v, ctx} = fresh(ctx, "C")
      push_call_result(v, call, length(results), rest, ctx)
    end
  end

  # Bind a call's result `v := call` and splice it onto the comp stack by the callee's result arity:
  #   0 → push nothing (bind for effects only — a phantom push shifts every later op, the wb-p946 OOB);
  #   1 → push the bare value;
  #   n>1 → the result is a TOP-FIRST list (Porffor's [value,type] pairs / multi-value return); destructure
  #         it into n vars and push them top-first (matching `push_results/3` at the interp boundary).
  defp push_call_result(v, call, 0, rest, ctx), do: {[{:match, @ln, v, call}], rest, ctx}
  defp push_call_result(v, call, 1, rest, ctx), do: {[{:match, @ln, v, call}], [v | rest], ctx}

  defp push_call_result(v, call, n, rest, ctx) do
    bind = {:match, @ln, v, call}
    {splice, push, ctx} = splice_results(v, n, rest, ctx)
    {[bind] ++ splice, push, ctx}
  end

  # memory.size → current page count (the 1-slot `:tl_mem_pages` atomics the runner maintains).
  defp lower({:memory_size}, stack, ctx) do
    expr = {:call, @ln, atomics_remote(:get), [mem_pages_ref(), {:integer, @ln, 1}]}
    {v, ctx} = fresh(ctx, "Msz")
    {[{:match, @ln, v, expr}], [v | stack], ctx}
  end

  # memory.grow(n) → host helper that reallocs `:tl_mem` + bumps the page count (mirrors the
  # interpreter), returning the old page count or -1. Pops n, pushes the result.
  defp lower({:memory_grow}, [n | stack], ctx) do
    call = {:call, @ln, {:remote, @ln, {:atom, @ln, :"Elixir.TinyLasers.Wasm"}, {:atom, @ln, :guest_memory_grow}}, [n]}
    {v, ctx} = fresh(ctx, "Mgr")
    {[{:match, @ln, v, call}], [v | stack], ctx}
  end

  # bulk memory (Rust's memcpy/memset). All VOID: pop their args, call the host helper, push nothing.
  # Stack order matches the interpreter: memory.copy pops [n, src, dst]; memory.fill pops [n, val, dst].
  defp lower({:memory_copy}, [n, src, dst | rest], ctx) do
    call = {:call, @ln, {:remote, @ln, {:atom, @ln, :"Elixir.TinyLasers.Wasm"}, {:atom, @ln, :guest_memory_copy}}, [dst, src, n]}
    {v, ctx} = fresh(ctx, "Mcp")
    {[{:match, @ln, v, call}], rest, ctx}
  end

  defp lower({:memory_fill}, [n, val, dst | rest], ctx) do
    call = {:call, @ln, {:remote, @ln, {:atom, @ln, :"Elixir.TinyLasers.Wasm"}, {:atom, @ln, :guest_memory_fill}}, [dst, val, n]}
    {v, ctx} = fresh(ctx, "Mfl")
    {[{:match, @ln, v, call}], rest, ctx}
  end

  # data.drop — frees a passive data segment; our active-segment model has nothing to free → no-op.
  defp lower({:data_drop}, stack, ctx), do: {[], stack, ctx}

  # global.get/set over the module's mutable globals array (installed in `:tl_globals` by the runner).
  defp lower({:global_get, i}, stack, ctx) do
    expr = {:call, @ln, atomics_remote(:get), [globals_ref(), {:integer, @ln, i + 1}]}
    {v, ctx} = fresh(ctx, "Gg")
    {[{:match, @ln, v, expr}], [v | stack], ctx}
  end

  defp lower({:global_set, i}, [val | stack], ctx) do
    # the interpreter masks global writes to 32 bits — mirror it exactly for oracle agreement
    masked = {:op, @ln, :band, val, {:integer, @ln, @mask32}}
    stmt = {:call, @ln, atomics_remote(:put), [globals_ref(), {:integer, @ln, i + 1}, masked]}
    {[stmt], stack, ctx}
  end

  defp lower({:drop}, [_ | stack], ctx), do: {[], stack, ctx}
  defp lower({:nop}, stack, ctx), do: {[], stack, ctx}
  # unreachable (0x00): trap exactly like the interpreter; everything after is dead (:unreachable stack).
  defp lower({:unreachable}, _stack, ctx), do: {[trap_call(:unreachable)], :unreachable, ctx}

  # trunc_sat (0xFC 0-7): saturating float→int. Mirrors the interpreter (trunc if float else passthrough),
  # masked to i32 (n 0..3) or i64 (n 4..7). NB: the interpreter's trunc_sat is a simple trunc (edge
  # clamping refined later); we match it exactly so the lanes agree.
  defp lower({:trunc_sat, n}, [a | stack], ctx) do
    mask = if n < 4, do: @mask32, else: @mask64
    expr = {:op, @ln, :band, call_remote(__MODULE__, :wtrunc_sat, [a]), {:integer, @ln, mask}}
    {v, ctx} = fresh(ctx, "Ts")
    {[{:match, @ln, v, expr}], [v | stack], ctx}
  end

  # ── call_indirect: dispatch through the (compile-time-known) function table ───────────────────────
  # Pop the index; switch on it. Each known table slot resolves to a global func index whose type we
  # know statically, so we pre-check it against the expected type (signature at `typeidx`): a match
  # compiles to a DIRECT call to the compiled-in local function; a type mismatch / missing slot / an
  # import target lowers to the SAME trap the interpreter raises.
  defp lower({:call_indirect, typeidx}, [idx_e | stack], ctx) do
    expected = Enum.at(ctx.mod.types, typeidx)
    {params, results} = expected
    arity = length(params)
    {args, rest} = Enum.split(stack, arity)
    arg_exprs = Enum.reverse(args)

    {iv, ctx} = fresh(ctx, "Ci")
    {av, avstmts, ctx} = bind_args(arg_exprs, ctx)
    bind_idx = {:match, @ln, iv, idx_e}

    clauses =
      for {slot, gfidx} <- Enum.sort(ctx.table) do
        body =
          cond do
            func_type(ctx.mod, ctx.ni, gfidx) != expected ->
              trap_call(:indirect_call_type_mismatch)

            gfidx < ctx.ni ->
              # target is an import — out of the transpiler's scope; bail to the unsupported path.
              throw({:unsupported, {:call_indirect_import, gfidx}})

            true ->
              case Map.get(ctx.calls, gfidx) do
                {fname, _ar} ->
                  {:call, @ln, {:atom, @ln, fname}, av}

                nil ->
                  # target not transpiled (interpreted lane, or tiering PASS-1) → trampoline through the
                  # interpreter on the shared state, exactly like a direct `call` to a cold function.
                  {:call, @ln, {:remote, @ln, {:atom, @ln, :"Elixir.TinyLasers.Wasm"}, {:atom, @ln, :call_local}},
                   [{:integer, @ln, gfidx}, list_ast(av)]}
              end
          end

        {:clause, @ln, [{:integer, @ln, slot}], [], [body]}
      end

    default = {:clause, @ln, [{:var, @ln, :_}], [], [trap_call(:undefined_element)]}
    {cv, ctx} = fresh(ctx, "Cr")
    switch = {:match, @ln, cv, {:case, @ln, iv, clauses ++ [default]}}
    pre = [bind_idx] ++ avstmts ++ [switch]
    # void → push nothing; single → cv; multi → cv is a top-first list, splice it (push_results boundary).
    {post, push, ctx} = push_call_result_tail(cv, length(results), rest, ctx)
    {pre ++ post, push, ctx}
  end

  # like push_call_result but the result is ALREADY bound in `cv` (call_indirect's case switch).
  defp push_call_result_tail(_cv, 0, rest, ctx), do: {[], rest, ctx}
  defp push_call_result_tail(cv, 1, rest, ctx), do: {[], [cv | rest], ctx}
  defp push_call_result_tail(cv, n, rest, ctx), do: splice_results(cv, n, rest, ctx)

  # ── constants ────────────────────────────────────────────────────────────────────────────────────
  defp lower({:i64_const, v}, stack, ctx), do: {[], [{:integer, @ln, v &&& @mask64} | stack], ctx}

  # float const: finite floats compile to a literal; a non-finite const ({:nonfinite,_,_}) is rare in
  # our test surface — keep it unsupported rather than miscompile.
  defp lower({:fconst, v}, stack, ctx) when is_float(v) do
    {[], [{:float, @ln, v} | stack], ctx}
  end

  # non-finite consts (NaN/Inf) decode to a `{:nonfinite, bits, size}` tuple the interpreter pushes
  # as-is; push the same literal so the lanes match (float ops on it trap in BOTH — consistent).
  defp lower({:fconst, other}, stack, ctx), do: {[], [:erl_parse.abstract(other, @ln) | stack], ctx}

  # ── memory load/store ────────────────────────────────────────────────────────────────────────────
  # Effective address = base + static offset; bounds-checked against the LOGICAL memory size (derived
  # from the atomics backing: slots*8 bytes == pages*65536) → :out_of_bounds trap, exactly as interp.
  defp lower({:i32_load, o}, [a | s], ctx), do: load_int(a, o, 4, :u, s, ctx)
  defp lower({:i32_load8u, o}, [a | s], ctx), do: load_int(a, o, 1, :u, s, ctx)
  defp lower({:i32_load8s, o}, [a | s], ctx), do: load_int(a, o, 1, {:s, 32}, s, ctx)
  defp lower({:i32_load16u, o}, [a | s], ctx), do: load_int(a, o, 2, :u, s, ctx)
  defp lower({:i32_load16s, o}, [a | s], ctx), do: load_int(a, o, 2, {:s, 32}, s, ctx)
  defp lower({:i64_load, o, 8, _}, [a | s], ctx), do: load_int(a, o, 8, :u, s, ctx)
  defp lower({:i64_load, o, n, true}, [a | s], ctx), do: load_int(a, o, n, {:s, 64}, s, ctx)
  defp lower({:i64_load, o, n, false}, [a | s], ctx), do: load_int(a, o, n, :u, s, ctx)
  defp lower({:i32_store, o}, [v, a | s], ctx), do: store_int(a, v, o, 4, s, ctx)
  defp lower({:i32_store8, o}, [v, a | s], ctx), do: store_int(a, v, o, 1, s, ctx)
  defp lower({:i32_store16, o}, [v, a | s], ctx), do: store_int(a, v, o, 2, s, ctx)
  defp lower({:i64_store, o, n}, [v, a | s], ctx), do: store_int(a, v, o, n, s, ctx)
  defp lower({:f32_load, o}, [a | s], ctx), do: load_float(a, o, 4, s, ctx)
  defp lower({:f64_load, o}, [a | s], ctx), do: load_float(a, o, 8, s, ctx)
  defp lower({:f32_store, o}, [v, a | s], ctx), do: store_float(a, v, o, 4, s, ctx)
  defp lower({:f64_store, o}, [v, a | s], ctx), do: store_float(a, v, o, 8, s, ctx)

  # ── br_table: switch on the (clamped) index → the right depth-tagged exit / loop tail-call ─────────
  defp lower({:br_table, labels, default}, [idx_e | stack], ctx), do: lower_br_table(labels, default, idx_e, stack, ctx)

  # ── control flow ─────────────────────────────────────────────────────────────────────────────────

  defp lower({:if, nres, then_b, else_b}, [cond_e | stack], ctx), do: lower_if(nres, cond_e, then_b, else_b, stack, ctx)
  defp lower({:block, nres, body}, stack, ctx), do: lower_block(nres, body, stack, ctx)
  defp lower({:loop, nres, body}, stack, ctx), do: lower_loop(nres, body, stack, ctx)
  defp lower({:br, n}, stack, ctx), do: {[do_br(n, stack, ctx)], :unreachable, ctx}
  defp lower({:br_if, n}, [cond_e | stack], ctx), do: lower_br_if(n, cond_e, stack, ctx)
  defp lower({:return}, stack, ctx), do: {[do_return(stack, ctx)], :unreachable, ctx}

  defp lower(other, _stack, _ctx), do: throw({:unsupported, other})

  # ── br / return: throw a tagged signal caught at the target label ────────────────────────────────
  # Branch target depth: a `br n` exits `n+1` enclosing labels. We compute the absolute label depth it
  # lands at = ctx.depth - n - 1, and throw {:tl_br, target_depth, ResultList, LocalsTuple}. The
  # enclosing block/loop installed at that depth catches it.

  defp do_br(n, stack, ctx) do
    target = ctx.depth - n - 1

    # Both forward exits (br to a BLOCK) and back-edges (br to a LOOP = continue) are realized as a
    # THROW the target construct catches: a block turns it into the region's {result, locals}; a loop
    # catches its OWN target and recurses with the carried locals. This is the only correct shape for a
    # CONDITIONAL back-edge (`br_if` to a loop): a continue must unwind the rest of the current iteration
    # rather than fall through into it. (An earlier direct-recursive-call form for loop continues silently
    # discarded its value and fell through — wrong whenever the back-edge wasn't an unconditional tail.)
    # carry exactly the target construct's result arity. A `br` to a LOOP targets the loop ENTRY (params,
    # 0 in the non-multivalue-param case → carry 0); a `br` to a BLOCK/IF carries its `nres` results.
    arity =
      case Map.get(ctx.labels, target) do
        {:block, nres} -> nres
        {:loop, _atom, _nres} -> 0
        _ -> 1
      end

    {:call, @ln, {:remote, @ln, {:atom, @ln, :erlang}, {:atom, @ln, :throw}},
     [{:tuple, @ln, [{:atom, @ln, :tl_br}, {:integer, @ln, target}, result_list(stack, arity), locals_tuple(ctx)]}]}
  end

  defp do_return(stack, ctx) do
    {:call, @ln, {:remote, @ln, {:atom, @ln, :erlang}, {:atom, @ln, :throw}},
     [{:tuple, @ln, [{:atom, @ln, :tl_ret}, {:integer, @ln, ctx.depth}, result_list(stack, Map.get(ctx, :nresults, 1))]}]}
  end

  # the values a br/return/region carries = the top `n` of the stack as an n-element list, TOP FIRST
  # (matching the interpreter's `Enum.take(stack, n)` order so the asm/interp boundary is consistent).
  # `n` is the construct's declared result arity (block/loop/if `nres`, or the function result count).
  # Default n=1 keeps every existing single/void call-site bit-identical.
  defp result_list(stack), do: result_list(stack, 1)
  defp result_list(:unreachable, _n), do: {nil, @ln}
  defp result_list(_stack, 0), do: {nil, @ln}
  defp result_list(stack, n) when is_list(stack), do: list_ast(Enum.take(stack, n))

  # the result arity a region/arm yields: its declared `nres`, but 0 if the path is unreachable (the
  # value arrives via a caught throw instead). Used to drive how many values to splice back.
  defp region_arity(:unreachable, _nres), do: 0
  defp region_arity(_stack, nres), do: nres

  defp locals_tuple(ctx) do
    n = map_size(ctx.lmap)
    {:tuple, @ln, for(i <- 0..(n - 1)//1, do: Map.fetch!(ctx.lmap, i))}
  end

  # ── if/else → case, with locals merged ───────────────────────────────────────────────────────────

  defp lower_if(nres, cond_e, then_b, else_b, stack, ctx) do
    nlocals = map_size(ctx.lmap)

    # Compile each arm in a child ctx; the arm yields {ResultList, LocalsTuple}. (br/return inside an
    # arm escape via throw and are caught higher up — they don't fall through this merge.)
    {then_expr, then_arity, ctx} = compile_arm(nres, then_b, ctx)
    {else_expr, else_arity, ctx} = compile_arm(nres, else_b, ctx)
    result_arity = max(then_arity, else_arity)

    rv = {:var, @ln, :"_If#{ctx.gen}"}
    case_e =
      {:match, @ln, rv,
       {:case, @ln, {:op, @ln, :"/=", cond_e, {:integer, @ln, 0}},
        [
          {:clause, @ln, [{:atom, @ln, true}], [], [then_expr]},
          {:clause, @ln, [{:atom, @ln, false}], [], [else_expr]}
        ]}}

    # rv = {ResultList, LocalsTuple}; pull locals back into fresh SSA vars + push result.
    sv = {:var, @ln, :"_IfS#{ctx.gen}"}
    lv = {:var, @ln, :"_IfL#{ctx.gen}"}
    destructure = {:match, @ln, {:tuple, @ln, [sv, lv]}, rv}

    ctx = %{ctx | gen: ctx.gen + 1}
    {lstmts, ctx} = rebind_locals_from_tuple(lv, nlocals, ctx)

    {splice, push, ctx} = splice_results(sv, result_arity, stack, ctx)
    {[case_e, destructure] ++ lstmts ++ splice, push, ctx}
  end

  # Splice a region's ResultList (`sv`) onto the comp stack: pull the top `n` elements (TOP FIRST, the
  # list's head order) into fresh vars and push them. n==0 leaves the stack unchanged. Generalizes the
  # old single-`hd` push to multi-value (Porffor's [value,type] pairs). Returns {stmts, new_stack, ctx}.
  defp splice_results(_sv, 0, stack, ctx), do: {[], stack, ctx}

  defp splice_results(sv, n, stack, ctx) do
    {stmts, vars_rev, ctx} =
      Enum.reduce(0..(n - 1)//1, {[], [], ctx}, fn i, {ss, vs, c} ->
        {v, c} = fresh(c, "Rsp")
        # element i (0-based from the head = TOP) is list position i ⇒ lists:nth(i+1, sv).
        get = {:match, @ln, v, {:call, @ln, {:remote, @ln, {:atom, @ln, :lists}, {:atom, @ln, :nth}}, [{:integer, @ln, i + 1}, sv]}}
        {ss ++ [get], [v | vs], c}
      end)

    # vars_rev = [v(n-1), …, v0]; the comp stack is head=TOP, so v0 (the top) must be the head ⇒
    # prepend v0,…,v(n-1) = Enum.reverse(vars_rev) onto the stack.
    {stmts, Enum.reverse(vars_rev) ++ stack, ctx}
  end

  # Compile an arm (instr list) to an expression evaluating to {ResultList, LocalsTuple}. Returns
  # {expr, result_arity}. Runs in a child block that catches no signals (br/return propagate out).
  defp compile_arm(nres, instrs, ctx) do
    {stmts, stack, ctx2} = lower_seq(instrs, [], ctx)
    arity = region_arity(stack, nres)
    yield = {:tuple, @ln, [result_list(stack, arity), locals_tuple(ctx2)]}
    # The arm runs in its own `begin` block (separate case clause), so its local rebindings don't
    # survive the merge — we restore the parent lmap. But the gen counter MUST keep advancing globally
    # so region vars never collide across siblings/nesting.
    {block_expr(stmts ++ [yield]), arity, %{ctx | gen: ctx2.gen}}
  end

  # ── block → a labelled forward region; br to it / fallthrough both yield {result, locals} ─────────

  defp lower_block(nres, body, stack, ctx) do
    target_depth = ctx.depth
    nlocals = map_size(ctx.lmap)
    # record the block's result arity at its label so a `br` targeting it carries exactly `nres` values.
    inner = %{ctx | depth: ctx.depth + 1, labels: Map.put(ctx.labels, target_depth, {:block, nres})}

    # body compiled in a child block: it yields {result, locals} on fallthrough; a `br target_depth`
    # throws {:tl_br, target_depth, ...} which we catch here and turn into the same shape.
    {stmts, bstack, bctx} = lower_seq(body, [], inner)
    fall_arity = region_arity(bstack, nres)
    fall = {:tuple, @ln, [result_list(bstack, fall_arity), locals_tuple(bctx)]}
    body_expr = block_expr(stmts ++ [fall])

    # advance the parent gen past everything the body minted, so region vars are globally unique.
    ctx = %{ctx | gen: bctx.gen + 1}
    region = try_catch_label(body_expr, target_depth, ctx.gen)
    # The block join carries `nres` values whenever it's REACHABLE: either the body falls through
    # (bstack != :unreachable) or some inner `br 0` jumps to it. Dead joins (no fall-through, no br to
    # this label) yield 0. In valid wasm every reaching path agrees on the count (== nres).
    reach = bstack != :unreachable or branches_to?(body, 0)
    consume_region(region, if(reach, do: nres, else: 0), stack, nlocals, ctx)
  end

  # Does any branch within `instrs` target the construct at relative nesting `d` (d=0 = this construct)?
  defp branches_to?(instrs, d) do
    Enum.any?(instrs, fn
      {:br, n} -> n == d
      {:br_if, n} -> n == d
      {:br_table, labels, default} -> default == d or Enum.any?(labels, &(&1 == d))
      {:block, _n, b} -> branches_to?(b, d + 1)
      {:loop, _n, b} -> branches_to?(b, d + 1)
      {:if, _n, t, e} -> branches_to?(t, d + 1) or branches_to?(e, d + 1)
      _ -> false
    end)
  end

  # ── loop → recursive named fun; br to loop label = recurse with current locals ───────────────────

  defp lower_loop(nres, body, stack, ctx) do
    target_depth = ctx.depth
    nlocals = map_size(ctx.lmap)

    # The loop compiles to a recursive named fun over the locals tuple. A `br target_depth` (continue)
    # is lowered by `do_br` to a DIRECT recursive call to this fun (no exception) — a proper BEAM tail
    # call when it sits in tail position. Fallthrough yields {result, locals}; a `br`/`return` to an
    # OUTER label is a throw the outer construct catches.
    id = ctx.gen
    fun_name = {:var, @ln, :"_Loop#{id}"}
    lv = {:var, @ln, :"_LpL#{id}"}

    inner_lmap = lmap_from_tuple(lv, nlocals)
    fun_atom = elem(fun_name, 2)

    inner = %{
      ctx
      | depth: ctx.depth + 1,
        lmap: inner_lmap,
        gen: ctx.gen + 1,
        labels: Map.put(ctx.labels, target_depth, {:loop, fun_atom, nres})
    }

    # charge fuel on each loop iteration (entry) so a transpiled loop traps :out_of_fuel like the
    # interpreter instead of spinning unbounded — TinyLasers.Wasm.charge_fuel/0 raises the same trap.
    charge = {:call, @ln, {:remote, @ln, {:atom, @ln, :"Elixir.TinyLasers.Wasm"}, {:atom, @ln, :charge_fuel}}, []}
    recurse = fn lctx -> {:call, @ln, {:var, @ln, fun_atom}, [locals_tuple(lctx)]} end

    # FAST PATH: the common compiler-emitted shape is a back-edge as the loop body's LAST instruction —
    # `br 0` (unconditional continue) or `br_if 0` (continue-or-exit). Compile that terminal directly as a
    # BEAM TAIL CALL (true branch) instead of a throw, so the hot loop spins via tail recursion (cheap)
    # rather than throw/catch per iteration. A NON-terminal/nested back-edge (rare) still throws and is
    # caught below — so correctness holds for every shape.
    {body_seq, body_init_for_try_check, exit_arity, body_gen} =
      case List.last(body) do
        {:br, 0} ->
          init = Enum.drop(body, -1)
          {stmts, _bstack, bctx} = lower_seq(init, [], inner)
          # unconditional terminal continue: the only normal exits are inner throws to outer labels, so
          # this loop's own fallthrough is unreachable ⇒ arity 0.
          {[charge | stmts] ++ [recurse.(bctx)], init, 0, bctx.gen}

        {:br_if, 0} ->
          init = Enum.drop(body, -1)
          {stmts, bstack, bctx} = lower_seq(init, [], inner)
          [cond_e | rest] = bstack
          ex_arity = region_arity(rest, nres)
          exit_tuple = {:tuple, @ln, [result_list(rest, ex_arity), locals_tuple(bctx)]}
          term =
            {:case, @ln, {:op, @ln, :"/=", cond_e, {:integer, @ln, 0}},
             [
               {:clause, @ln, [{:atom, @ln, true}], [], [recurse.(bctx)]},
               {:clause, @ln, [{:atom, @ln, false}], [], [exit_tuple]}
             ]}

          {[charge | stmts] ++ [term], init, ex_arity, bctx.gen}

        _ ->
          {stmts, bstack, bctx} = lower_seq(body, [], inner)
          # no terminal back-edge ⇒ any continue is nested ⇒ force the try by reporting a back-edge.
          ex_arity = region_arity(bstack, nres)
          {[charge | stmts] ++ [{:tuple, @ln, [result_list(bstack, ex_arity), locals_tuple(bctx)]}], body, ex_arity, bctx.gen}
      end

    # Only a NESTED back-edge to THIS loop (a continue inside an if/block, not the terminal) needs the
    # catch-and-recurse. When the loop's sole back-edge is the terminal one (the overwhelmingly common
    # case), we skip the try so the terminal recurse stays a real BEAM TAIL CALL — cheap unbounded loops.
    body_expr =
      if continues_to_loop?(body_init_for_try_check, 0) do
        cl = {:var, @ln, :"_LpC#{id}"}
        continue_clause =
          {:clause, @ln,
           [catch_pat({:tuple, @ln, [{:atom, @ln, :tl_br}, {:integer, @ln, target_depth}, {:var, @ln, :_}, cl]})],
           [], [{:call, @ln, {:var, @ln, fun_atom}, [cl]}]}

        {:try, @ln, [block_expr(body_seq)], [], [continue_clause], []}
      else
        block_expr(body_seq)
      end

    loop_fun =
      {:named_fun, @ln, fun_atom, [{:clause, @ln, [lv], [], [body_expr]}]}

    init_call = {:call, @ln, loop_fun, [locals_tuple(ctx)]}

    # advance parent gen past the loop body's mints before consuming.
    ctx = %{ctx | gen: body_gen + 1}
    consume_region(init_call, exit_arity, stack, nlocals, ctx)
  end

  # ── shared: wrap a region expr to catch a br to `target_depth`, and splice its {result,locals} back ─

  # try the body; if a {:tl_br, target_depth, S, L} escapes it, that's a br OUT of this block → its
  # carried result+locals become the region's value. Any other signal (outer br / ret) re-propagates.
  defp try_catch_label(body_expr, target_depth, id) do
    sv = {:var, @ln, :"_BrS#{id}"}
    lv = {:var, @ln, :"_BrL#{id}"}
    catch_here =
      {:clause, @ln,
       [catch_pat({:tuple, @ln, [{:atom, @ln, :tl_br}, {:integer, @ln, target_depth}, sv, lv]})],
       [], [{:tuple, @ln, [sv, lv]}]}

    {:try, @ln, [body_expr], [], [catch_here], []}
  end

  # region_expr evaluates to {ResultList, LocalsTuple}; destructure, rebind locals, push result.
  defp consume_region(region_expr, result_arity, stack, nlocals, ctx) do
    rv = {:var, @ln, :"_Rg#{ctx.gen}"}
    sv = {:var, @ln, :"_RgS#{ctx.gen}"}
    lv = {:var, @ln, :"_RgL#{ctx.gen}"}
    bind = {:match, @ln, rv, region_expr}
    destr = {:match, @ln, {:tuple, @ln, [sv, lv]}, rv}
    ctx = %{ctx | gen: ctx.gen + 1}
    {lstmts, ctx} = rebind_locals_from_tuple(lv, nlocals, ctx)
    {splice, push, ctx} = splice_results(sv, result_arity, stack, ctx)
    {[bind, destr] ++ lstmts ++ splice, push, ctx}
  end

  # ── br_if: cond ? (br n) : fallthrough ───────────────────────────────────────────────────────────
  defp lower_br_if(n, cond_e, stack, ctx) do
    br = do_br(n, stack, ctx)
    case_e =
      {:case, @ln, {:op, @ln, :"/=", cond_e, {:integer, @ln, 0}},
       [
         {:clause, @ln, [{:atom, @ln, true}], [], [br]},
         {:clause, @ln, [{:atom, @ln, false}], [], [{:atom, @ln, :ok}]}
       ]}

    {[case_e], stack, ctx}
  end

  # ── locals plumbing ──────────────────────────────────────────────────────────────────────────────

  defp bind_local(i, expr, ctx) do
    v = var("L#{i}_#{ctx.gen}")
    {{:match, @ln, v, expr}, %{ctx | gen: ctx.gen + 1, lmap: Map.put(ctx.lmap, i, v)}}
  end

  defp lmap_from_tuple(tuple_var, nlocals) do
    for i <- 0..(nlocals - 1)//1, into: %{} do
      {i, {:call, @ln, {:atom, @ln, :element}, [{:integer, @ln, i + 1}, tuple_var]}}
    end
  end

  # element-extract each local out of `tuple_var` into a fresh SSA var; update lmap.
  defp rebind_locals_from_tuple(tuple_var, nlocals, ctx) do
    Enum.reduce(0..(nlocals - 1)//1, {[], ctx}, fn i, {ss, c} ->
      nv = var("L#{i}_#{c.gen}")
      c = %{c | gen: c.gen + 1, lmap: Map.put(c.lmap, i, nv)}
      get = {:match, @ln, nv, {:call, @ln, {:atom, @ln, :element}, [{:integer, @ln, i + 1}, tuple_var]}}
      {ss ++ [get], c}
    end)
  end

  defp fresh(ctx, prefix) do
    {var("#{prefix}#{ctx.gen}"), %{ctx | gen: ctx.gen + 1}}
  end

  # bind each call_indirect arg to a fresh var (the dispatch switch references them in every clause, so
  # evaluating them once up front avoids recomputation + keeps each clause a clean direct call).
  defp bind_args(arg_exprs, ctx) do
    {vars_rev, stmts, ctx} =
      Enum.reduce(arg_exprs, {[], [], ctx}, fn e, {vs, ss, c} ->
        {v, c} = fresh(c, "Ca")
        {[v | vs], ss ++ [{:match, @ln, v, e}], c}
      end)

    {Enum.reverse(vars_rev), stmts, ctx}
  end

  # the resolved {params, results} type of a global func index (import or local).
  defp func_type(mod, ni, fidx) do
    tidx = if fidx < ni, do: elem(Enum.at(mod.imports, fidx), 2), else: Enum.at(mod.funcs, fidx - ni)
    Enum.at(mod.types, tidx)
  end

  # wrap a stmt list as an Erlang `begin ... end` block expression
  defp block_expr(stmts), do: {:block, @ln, stmts}

  # ── memory access codegen ────────────────────────────────────────────────────────────────────────
  # All access goes through the SAME packed `:atomics` (`:tl_mem`) the interpreter uses, with the
  # identical little-endian byte layout, so transpiled ⟷ interpreted byte effects are bit-identical.

  # Mem = Process.get(:tl_mem)  (fetch once per op; cheap dict read)
  defp mem_get do
    {:call, @ln, {:remote, @ln, {:atom, @ln, Process}, {:atom, @ln, :get}}, [{:atom, @ln, :tl_mem}]}
  end

  # Erlang for (mget(Mem, Addr)) — read byte at Addr from the packed word. Addr is an Erlang expr.
  # word = atomics:get(Mem, (Addr bsr 3) + 1); (word bsr ((Addr band 7)*8)) band 255
  defp mget_expr(mem_v, addr_v) do
    word =
      {:call, @ln, {:remote, @ln, {:atom, @ln, :atomics}, {:atom, @ln, :get}},
       [mem_v, {:op, @ln, :+, {:op, @ln, :bsr, addr_v, {:integer, @ln, 3}}, {:integer, @ln, 1}}]}

    sh = {:op, @ln, :*, {:op, @ln, :band, addr_v, {:integer, @ln, 7}}, {:integer, @ln, 8}}
    {:op, @ln, :band, {:op, @ln, :bsr, word, sh}, {:integer, @ln, 0xFF}}
  end

  # bounds!: limit = atomics:info(Mem).size * 8 (== pages*65536). if Addr<0 orelse Addr+n>limit -> trap.
  # Emitted as a guard-style case so it traps with the interpreter's :out_of_bounds reason.
  defp bounds_check(mem_v, addr_v, n) do
    size = {:call, @ln, {:remote, @ln, {:atom, @ln, :erlang}, {:atom, @ln, :map_get}},
            [{:atom, @ln, :size}, {:call, @ln, {:remote, @ln, {:atom, @ln, :atomics}, {:atom, @ln, :info}}, [mem_v]}]}
    limit = {:op, @ln, :*, size, {:integer, @ln, 8}}
    cond_e =
      {:op, @ln, :orelse,
       {:op, @ln, :<, addr_v, {:integer, @ln, 0}},
       {:op, @ln, :>, {:op, @ln, :+, addr_v, {:integer, @ln, n}}, limit}}

    {:case, @ln, cond_e,
     [
       {:clause, @ln, [{:atom, @ln, true}], [], [trap_call(:out_of_bounds)]},
       {:clause, @ln, [{:atom, @ln, false}], [], [{:atom, @ln, :ok}]}
     ]}
  end

  # build a value expr that reads n little-endian bytes at base address Addr (an Erlang var):
  #   B0 bor (B1 bsl 8) bor ... — each Bi = mget(Mem, Addr+i)
  defp load_value_expr(mem_v, addr_v, n) do
    Enum.reduce(0..(n - 1)//1, {:integer, @ln, 0}, fn i, acc ->
      byte = mget_expr(mem_v, {:op, @ln, :+, addr_v, {:integer, @ln, i}})
      shifted = if i == 0, do: byte, else: {:op, @ln, :bsl, byte, {:integer, @ln, i * 8}}
      if i == 0, do: shifted, else: {:op, @ln, :bor, acc, shifted}
    end)
  end

  # ── aligned-word memory FAST PATH (research finding A) ────────────────────────────────────────────
  # When an n-byte access fits in ONE packed `:atomics` word — `(addr band 7) + n =< 8`, the
  # aligned/common case clang/rustc emit — do a SINGLE atomics op instead of the n-byte loop (an i64
  # store goes 16 ops → 1; i32 load 4 → 1). Alignment is a RUNTIME property (the align immediate is
  # only a hint), so it's a runtime branch; word-spanning accesses fall back to the byte loop. n=1 is
  # already one op, so no branch. The result is bit-identical to the byte path (oracle-guarded).
  defp load_word_or_bytes(mem_v, addr_v, 1), do: load_value_expr(mem_v, addr_v, 1)

  defp load_word_or_bytes(mem_v, addr_v, n) do
    {:case, @ln, fits_one_word(addr_v, n),
     [
       {:clause, @ln, [{:atom, @ln, true}], [], [fast_load_expr(mem_v, addr_v, n)]},
       {:clause, @ln, [{:atom, @ln, false}], [], [load_value_expr(mem_v, addr_v, n)]}
     ]}
  end

  defp store_word_or_bytes(mem_v, addr_v, val_v, 1), do: mput_stmt(mem_v, addr_v, byte_of(val_v, 0))

  defp store_word_or_bytes(mem_v, addr_v, val_v, n) do
    byte_puts = for i <- 0..(n - 1)//1, do: mput_stmt(mem_v, {:op, @ln, :+, addr_v, {:integer, @ln, i}}, byte_of(val_v, i))

    {:case, @ln, fits_one_word(addr_v, n),
     [
       {:clause, @ln, [{:atom, @ln, true}], [], [fast_store_put(mem_v, addr_v, val_v, n)]},
       {:clause, @ln, [{:atom, @ln, false}], [], byte_puts}
     ]}
  end

  defp fits_one_word(addr_v, n) do
    {:op, @ln, :"=<", {:op, @ln, :+, {:op, @ln, :band, addr_v, {:integer, @ln, 7}}, {:integer, @ln, n}}, {:integer, @ln, 8}}
  end

  defp word_idx(addr_v), do: {:op, @ln, :+, {:op, @ln, :bsr, addr_v, {:integer, @ln, 3}}, {:integer, @ln, 1}}
  defp word_sh(addr_v), do: {:op, @ln, :*, {:op, @ln, :band, addr_v, {:integer, @ln, 7}}, {:integer, @ln, 8}}
  defp atomics_call(f, args), do: {:call, @ln, {:remote, @ln, {:atom, @ln, :atomics}, {:atom, @ln, f}}, args}

  defp fast_load_expr(mem_v, addr_v, n) do
    shifted = {:op, @ln, :bsr, atomics_call(:get, [mem_v, word_idx(addr_v)]), word_sh(addr_v)}
    {:op, @ln, :band, shifted, {:integer, @ln, (1 <<< (n * 8)) - 1}}
  end

  defp fast_store_put(mem_v, addr_v, val_v, n) do
    idx = word_idx(addr_v)
    sh = word_sh(addr_v)
    mask = (1 <<< (n * 8)) - 1
    cleared = {:op, @ln, :band, atomics_call(:get, [mem_v, idx]), mk_bnot({:op, @ln, :bsl, {:integer, @ln, mask}, sh})}
    vbits = {:op, @ln, :bsl, {:op, @ln, :band, val_v, {:integer, @ln, mask}}, sh}
    atomics_call(:put, [mem_v, idx, {:op, @ln, :bor, cleared, vbits}])
  end

  # emit: Mem=get; AddrV = base+offset; bounds!; V = <load>; [sign-extend]; push V
  defp load_int(base_e, offset, n, signw, stack, ctx) do
    {memv, ctx} = fresh(ctx, "Mem")
    {addrv, ctx} = fresh(ctx, "Adr")
    {rawv, ctx} = fresh(ctx, "Lv")
    mem_bind = {:match, @ln, memv, mem_get()}
    addr_bind = {:match, @ln, addrv, eff_addr(base_e, offset)}
    bc = bounds_check(memv, addrv, n)
    load_bind = {:match, @ln, rawv, load_word_or_bytes(memv, addrv, n)}

    {result, extra, ctx} =
      case signw do
        :u -> {rawv, [], ctx}
        {:s, width} -> sext_expr(rawv, n * 8, width, ctx)
      end

    {[mem_bind, addr_bind, bc, load_bind] ++ extra, [result | stack], ctx}
  end

  defp load_float(base_e, offset, n, stack, ctx) do
    {memv, ctx} = fresh(ctx, "Mem")
    {addrv, ctx} = fresh(ctx, "Adr")
    {fv, ctx} = fresh(ctx, "Fv")
    mem_bind = {:match, @ln, memv, mem_get()}
    addr_bind = {:match, @ln, addrv, eff_addr(base_e, offset)}
    bc = bounds_check(memv, addrv, n)
    # gather n bytes into a binary, then reinterpret as a little-endian float.
    bits = load_value_expr(memv, addrv, n)
    fbind = {:match, @ln, fv, float_from_bits_expr(bits, n)}
    {[mem_bind, addr_bind, bc, fbind], [fv | stack], ctx}
  end

  defp store_int(base_e, val_e, offset, n, stack, ctx) do
    {memv, ctx} = fresh(ctx, "Mem")
    {addrv, ctx} = fresh(ctx, "Adr")
    {valv, ctx} = fresh(ctx, "Sv")
    mem_bind = {:match, @ln, memv, mem_get()}
    addr_bind = {:match, @ln, addrv, eff_addr(base_e, offset)}
    val_bind = {:match, @ln, valv, val_e}
    bc = bounds_check(memv, addrv, n)
    {[mem_bind, addr_bind, val_bind, bc, store_word_or_bytes(memv, addrv, valv, n)], stack, ctx}
  end

  defp store_float(base_e, val_e, offset, n, stack, ctx) do
    {memv, ctx} = fresh(ctx, "Mem")
    {addrv, ctx} = fresh(ctx, "Adr")
    {bitsv, ctx} = fresh(ctx, "Sb")
    mem_bind = {:match, @ln, memv, mem_get()}
    addr_bind = {:match, @ln, addrv, eff_addr(base_e, offset)}
    bits_bind = {:match, @ln, bitsv, bits_from_float_expr(val_e, n)}
    bc = bounds_check(memv, addrv, n)
    puts = for i <- 0..(n - 1)//1, do: mput_stmt(memv, {:op, @ln, :+, addrv, {:integer, @ln, i}}, byte_of(bitsv, i))
    {[mem_bind, addr_bind, bits_bind, bc] ++ puts, stack, ctx}
  end

  # effective addr = base + static offset (offset is a non-negative immediate)
  defp eff_addr(base_e, 0), do: base_e
  defp eff_addr(base_e, offset), do: {:op, @ln, :+, base_e, {:integer, @ln, offset}}

  # (V bsr (i*8)) band 255
  defp byte_of(val_v, 0), do: {:op, @ln, :band, val_v, {:integer, @ln, 0xFF}}
  defp byte_of(val_v, i), do: {:op, @ln, :band, {:op, @ln, :bsr, val_v, {:integer, @ln, i * 8}}, {:integer, @ln, 0xFF}}

  # mput(Mem, AddrExpr, ByteExpr) as a statement: read-modify-write the packed word.
  #   Idx = (Addr bsr 3)+1, Sh=(Addr band 7)*8, W=atomics:get(Mem,Idx),
  #   atomics:put(Mem, Idx, ((W band (bnot(255 bsl Sh))) bor ((Byte band 255) bsl Sh)) band MASK64)
  # We inline Addr/Byte; to avoid recomputing Addr we expect AddrExpr to be cheap (var +/- int).
  defp mput_stmt(mem_v, addr_e, byte_e) do
    idx = {:op, @ln, :+, {:op, @ln, :bsr, addr_e, {:integer, @ln, 3}}, {:integer, @ln, 1}}
    sh = {:op, @ln, :*, {:op, @ln, :band, addr_e, {:integer, @ln, 7}}, {:integer, @ln, 8}}
    w = {:call, @ln, {:remote, @ln, {:atom, @ln, :atomics}, {:atom, @ln, :get}}, [mem_v, idx]}
    cleared = {:op, @ln, :band, w, mk_bnot({:op, @ln, :bsl, {:integer, @ln, 0xFF}, sh})}
    set = {:op, @ln, :bsl, {:op, @ln, :band, byte_e, {:integer, @ln, 0xFF}}, sh}
    neww = {:op, @ln, :band, {:op, @ln, :bor, cleared, set}, {:integer, @ln, @mask64}}
    {:call, @ln, {:remote, @ln, {:atom, @ln, :atomics}, {:atom, @ln, :put}}, [mem_v, idx, neww]}
  end

  defp mk_bnot(e), do: {:op, @ln, :bnot, e}

  # sign-extend a `from`-bit value (raw var) to a `to`-bit masked representation; returns {expr,stmts,ctx}
  defp sext_expr(raw_v, from_bits, to_bits, ctx) do
    mask = if to_bits == 32, do: @mask32, else: @mask64
    half = 1 <<< (from_bits - 1)
    full = 1 <<< from_bits
    {ov, ctx} = fresh(ctx, "Sx")
    expr =
      {:case, @ln, {:op, @ln, :>=, raw_v, {:integer, @ln, half}},
       [
         {:clause, @ln, [{:atom, @ln, true}], [],
          [{:op, @ln, :band, {:op, @ln, :-, raw_v, {:integer, @ln, full}}, {:integer, @ln, mask}}]},
         {:clause, @ln, [{:atom, @ln, false}], [], [raw_v]}
       ]}

    {ov, [{:match, @ln, ov, expr}], ctx}
  end

  # reinterpret n little-endian bytes (as an integer expr `bits`) → a float (32 or 64 bit IEEE-754).
  # binary:encode_unsigned won't pad/order; use a binary comprehension via erlang bit-syntax instead:
  #   <<F:n*8/float-little>> = <<Bits:n*8/integer-little>>  ... but generating that in abstract form is
  # awkward. Use erlang term: float from bits via a helper in TinyLasers.Wasm.Transpile.FloatBits.
  defp float_from_bits_expr(bits_e, 4),
    do: {:call, @ln, {:remote, @ln, {:atom, @ln, __MODULE__}, {:atom, @ln, :f32_from_bits}}, [bits_e]}

  defp float_from_bits_expr(bits_e, 8),
    do: {:call, @ln, {:remote, @ln, {:atom, @ln, __MODULE__}, {:atom, @ln, :f64_from_bits}}, [bits_e]}

  defp bits_from_float_expr(f_e, 4),
    do: {:call, @ln, {:remote, @ln, {:atom, @ln, __MODULE__}, {:atom, @ln, :f32_to_bits}}, [f_e]}

  defp bits_from_float_expr(f_e, 8),
    do: {:call, @ln, {:remote, @ln, {:atom, @ln, __MODULE__}, {:atom, @ln, :f64_to_bits}}, [f_e]}

  # ── float<->bits runtime helpers (called by generated code) ──────────────────────────────────────
  # Decode a raw bit pattern to a float. A non-finite pattern (±Inf/NaN) cannot bind to a BEAM float var,
  # so — exactly like the interpreter's `decode_f/2` — fall back to carrying it as {:nonfinite, bits, size}.
  @doc false
  def f32_from_bits(bits) do
    <<f::float-32-little>> = <<bits::32-little>>
    f
  rescue
    _ -> {:nonfinite, bits, 32}
  end

  @doc false
  def f64_from_bits(bits) do
    <<f::float-64-little>> = <<bits::64-little>>
    f
  rescue
    _ -> {:nonfinite, bits, 64}
  end

  @doc false
  # A non-finite float is carried as {:nonfinite, bits, size}; its reinterpret-to-int is just those bits
  # (mirrors the interpreter's reinterpret_to_i/2). Only FINITE floats can be packed into an IEEE binary.
  def f32_to_bits({:nonfinite, bits, _}), do: bits

  def f32_to_bits(f) do
    <<i::32-little>> = <<f::float-32-little>>
    i
  end

  @doc false
  def f64_to_bits({:nonfinite, bits, _}), do: bits

  def f64_to_bits(f) do
    <<i::64-little>> = <<f::float-64-little>>
    i
  end

  # round a double to f32 precision (pack→unpack as 32-bit IEEE-754) — matches the interpreter's f32r.
  # A non-finite value (±Inf/NaN, carried as {:nonfinite,…}) is already single-precision-safe → passthrough,
  # exactly like the interpreter's `f32r({:nonfinite,_,_}=x) -> x` clause.
  @doc false
  def f32r({:nonfinite, _, _} = x), do: x

  def f32r(x) do
    <<v::float-32-little>> = <<x::float-32-little>>
    v
  end

  # ── float runtime helpers (called from transpiled code; MUST mirror the interpreter bit-for-bit) ──
  @doc false
  def ftruncf(a), do: trunc(a) * 1.0

  # clz/ctz/popcnt + saturating trunc — mirror the interpreter's private helpers bit-for-bit.
  @doc false
  def wclz(a, bits), do: bits - wbitlen(a, 0)
  defp wbitlen(0, acc), do: acc
  defp wbitlen(a, acc), do: wbitlen(Bitwise.bsr(a, 1), acc + 1)

  @doc false
  def wctz(0, bits), do: bits
  def wctz(a, _bits), do: wctz_(a, 0)
  defp wctz_(a, n), do: if(Bitwise.band(a, 1) == 1, do: n, else: wctz_(Bitwise.bsr(a, 1), n + 1))

  @doc false
  def wpopcnt(a), do: wpop_(a, 0)
  defp wpop_(0, n), do: n
  defp wpop_(a, n), do: wpop_(Bitwise.bsr(a, 1), n + Bitwise.band(a, 1))

  @doc false
  def wtrunc_sat(a) when is_float(a), do: trunc(a)
  def wtrunc_sat(a), do: a

  @doc false
  def fnearest(a) do
    f = Float.floor(a)

    case a - f do
      d when d < 0.5 -> f
      d when d > 0.5 -> f + 1.0
      _ -> if rem(trunc(f), 2) == 0, do: f, else: f + 1.0
    end
  end

  @doc false
  def fcopysign(a, b), do: if(b < 0, do: -abs(a), else: abs(a))

  @doc false
  def ftrunc_int(a, lo, hi) when is_float(a) do
    t = trunc(a)
    if t < lo or t > hi, do: TinyLasers.Wasm.Trap.trap!(:conversion_overflow), else: t
  end

  def ftrunc_int(_a, _lo, _hi), do: TinyLasers.Wasm.Trap.trap!(:invalid_conversion)

  # ── br_table: a switch over the branch index ─────────────────────────────────────────────────────
  # interp: target = if i < length(labels), do: labels[i], else: default. We compile each distinct
  # target's br to its do_br lowering (loop tail-call or depth-tagged throw), and switch on the index.
  defp lower_br_table(labels, default, idx_e, stack, ctx) do
    {iv, ctx} = fresh(ctx, "Bt")
    bind = {:match, @ln, iv, idx_e}

    clauses =
      for {label, i} <- Enum.with_index(labels) do
        {:clause, @ln, [{:integer, @ln, i}], [], [do_br(label, stack, ctx)]}
      end

    default_clause = {:clause, @ln, [{:var, @ln, :_}], [], [do_br(default, stack, ctx)]}
    switch = {:case, @ln, iv, clauses ++ [default_clause]}
    {[bind, switch], :unreachable, ctx}
  end

  # ── operand ops ──────────────────────────────────────────────────────────────────────────────────

  # unary opcodes (pop 1): i32/i64 eqz, clz/ctz/popcnt, the i↔f conversions, sign-extend, and the
  # f32/f64 unary maths (abs/neg/sqrt/ceil/floor/trunc/nearest).
  @unary_ops [
    0x45, 0x50,                          # i32.eqz, i64.eqz
    0x67, 0x68, 0x69,                    # i32 clz/ctz/popcnt
    0x79, 0x7A, 0x7B,                    # i64 clz/ctz/popcnt
    0x8B, 0x8C, 0x8D, 0x8E, 0x8F, 0x90, 0x91,  # f32 abs/neg/ceil/floor/trunc/nearest/sqrt
    0x99, 0x9A, 0x9B, 0x9C, 0x9D, 0x9E, 0x9F,  # f64 abs/neg/ceil/floor/trunc/nearest/sqrt
    0xA7, 0xAC, 0xAD,                    # i32.wrap_i64, i64.extend_i32_s/u
    0xA8, 0xA9, 0xAA, 0xAB,              # i32.trunc_f32_s/u, f64_s/u
    0xAE, 0xAF, 0xB0, 0xB1,              # i64.trunc_f32_s/u, f64_s/u
    0xB2, 0xB3, 0xB4, 0xB5,              # f32.convert_i32_s/u, i64_s/u
    0xB6,                                # f32.demote_f64
    0xB7, 0xB8, 0xB9, 0xBA,              # f64.convert_i32_s/u, i64_s/u
    0xBB,                                # f64.promote_f32
    0xBC, 0xBD, 0xBE, 0xBF,              # reinterprets
    0xC0, 0xC1, 0xC2, 0xC3, 0xC4         # sign-extend ops
  ]

  defp op_pops(o) when o in @unary_ops, do: 1
  defp op_pops(_), do: 2

  defp apply_op(opcode, stack) do
    case op_pops(opcode) do
      1 -> [a | _] = stack; unop(opcode, a)
      2 -> [b, a | _] = stack; binop(opcode, a, b)
    end
  end

  defp drop(list, 0), do: list
  defp drop([_ | t], n), do: drop(t, n - 1)

  defp binop(0x6A, a, b), do: mask32({:op, @ln, :+, a, b})
  defp binop(0x6B, a, b), do: mask32({:op, @ln, :-, a, b})
  defp binop(0x6C, a, b), do: mask32({:op, @ln, :*, a, b})
  defp binop(0x6D, a, b), do: mask32(trap_div(a, b, :div, true, true))
  defp binop(0x6E, a, b), do: mask32(trap_div(a, b, :div, false, false))
  defp binop(0x6F, a, b), do: mask32(trap_div(a, b, :rem, false, true))
  defp binop(0x70, a, b), do: mask32(trap_div(a, b, :rem, false, false))
  defp binop(0x71, a, b), do: {:op, @ln, :band, a, b}
  defp binop(0x72, a, b), do: {:op, @ln, :bor, a, b}
  defp binop(0x73, a, b), do: {:op, @ln, :bxor, a, b}
  defp binop(0x74, a, b), do: mask32({:op, @ln, :bsl, a, shcount(b)})
  defp binop(0x75, a, b), do: mask32({:op, @ln, :bsr, s32(a), shcount(b)})
  defp binop(0x76, a, b), do: {:op, @ln, :bsr, a, shcount(b)}
  defp binop(0x46, a, b), do: cmp(:"==", a, b)
  defp binop(0x47, a, b), do: cmp(:"/=", a, b)
  defp binop(0x48, a, b), do: cmp(:<, s32(a), s32(b))
  defp binop(0x49, a, b), do: cmp(:<, a, b)
  defp binop(0x4A, a, b), do: cmp(:>, s32(a), s32(b))
  defp binop(0x4B, a, b), do: cmp(:>, a, b)
  defp binop(0x4C, a, b), do: cmp(:"=<", s32(a), s32(b))
  defp binop(0x4D, a, b), do: cmp(:"=<", a, b)
  defp binop(0x4E, a, b), do: cmp(:>=, s32(a), s32(b))
  defp binop(0x4F, a, b), do: cmp(:>=, a, b)

  # ── i64 binops (mask to 64 bits) ──
  defp binop(0x51, a, b), do: cmp(:"==", a, b)
  defp binop(0x52, a, b), do: cmp(:"/=", a, b)
  defp binop(0x53, a, b), do: cmp(:<, s64(a), s64(b))
  defp binop(0x54, a, b), do: cmp(:<, a, b)
  defp binop(0x55, a, b), do: cmp(:>, s64(a), s64(b))
  defp binop(0x56, a, b), do: cmp(:>, a, b)
  defp binop(0x57, a, b), do: cmp(:"=<", s64(a), s64(b))
  defp binop(0x58, a, b), do: cmp(:"=<", a, b)
  defp binop(0x59, a, b), do: cmp(:>=, s64(a), s64(b))
  defp binop(0x5A, a, b), do: cmp(:>=, a, b)
  defp binop(0x7C, a, b), do: mask64({:op, @ln, :+, a, b})
  defp binop(0x7D, a, b), do: mask64({:op, @ln, :-, a, b})
  defp binop(0x7E, a, b), do: mask64({:op, @ln, :*, a, b})
  defp binop(0x7F, a, b), do: mask64(trap_div64(a, b, :div, true, true))
  defp binop(0x80, a, b), do: mask64(trap_div64(a, b, :div, false, false))
  defp binop(0x81, a, b), do: mask64(trap_div64(a, b, :rem, false, true))
  defp binop(0x82, a, b), do: mask64(trap_div64(a, b, :rem, false, false))
  defp binop(0x83, a, b), do: {:op, @ln, :band, a, b}
  defp binop(0x84, a, b), do: {:op, @ln, :bor, a, b}
  defp binop(0x85, a, b), do: {:op, @ln, :bxor, a, b}
  defp binop(0x86, a, b), do: mask64({:op, @ln, :bsl, a, shcount64(b)})
  defp binop(0x87, a, b), do: mask64({:op, @ln, :bsr, s64(a), shcount64(b)})
  defp binop(0x88, a, b), do: {:op, @ln, :bsr, a, shcount64(b)}
  defp binop(0x89, a, b), do: rot64(a, b, :l)
  defp binop(0x8A, a, b), do: rot64(a, b, :r)

  # i32 rotl/rotr (were unsupported before)
  defp binop(0x77, a, b), do: rot32(a, b, :l)
  defp binop(0x78, a, b), do: rot32(a, b, :r)

  # ── f64 binops (BEAM floats; no rounding) ──
  defp binop(0xA0, a, b), do: {:op, @ln, :+, a, b}
  defp binop(0xA1, a, b), do: {:op, @ln, :-, a, b}
  defp binop(0xA2, a, b), do: {:op, @ln, :*, a, b}
  defp binop(0xA3, a, b), do: {:op, @ln, :/, a, b}
  defp binop(0xA4, a, b), do: fmin(a, b)
  defp binop(0xA5, a, b), do: fmax(a, b)
  defp binop(0xA6, a, b), do: call_remote(__MODULE__, :fcopysign, [a, b])   # f64.copysign
  defp binop(0x61, a, b), do: cmp(:"==", a, b)
  defp binop(0x62, a, b), do: cmp(:"/=", a, b)
  defp binop(0x63, a, b), do: cmp(:<, a, b)
  defp binop(0x64, a, b), do: cmp(:>, a, b)
  defp binop(0x65, a, b), do: cmp(:"=<", a, b)
  defp binop(0x66, a, b), do: cmp(:>=, a, b)

  # ── f32 binops (round result to single precision via f32r) ──
  defp binop(0x92, a, b), do: f32r_e({:op, @ln, :+, a, b})
  defp binop(0x93, a, b), do: f32r_e({:op, @ln, :-, a, b})
  defp binop(0x94, a, b), do: f32r_e({:op, @ln, :*, a, b})
  defp binop(0x95, a, b), do: f32r_e({:op, @ln, :/, a, b})
  defp binop(0x96, a, b), do: fmin(a, b)
  defp binop(0x97, a, b), do: fmax(a, b)
  defp binop(0x98, a, b), do: f32r_e(call_remote(__MODULE__, :fcopysign, [a, b]))   # f32.copysign
  defp binop(0x5B, a, b), do: cmp(:"==", a, b)
  defp binop(0x5C, a, b), do: cmp(:"/=", a, b)
  defp binop(0x5D, a, b), do: cmp(:<, a, b)
  defp binop(0x5E, a, b), do: cmp(:>, a, b)
  defp binop(0x5F, a, b), do: cmp(:"=<", a, b)
  defp binop(0x60, a, b), do: cmp(:>=, a, b)

  defp binop(op, _a, _b), do: throw({:unsupported, {:op, op}})

  # ── unary ops ──
  defp unop(0x45, a), do: cmp(:"==", a, {:integer, @ln, 0})
  defp unop(0x50, a), do: cmp(:"==", a, {:integer, @ln, 0})        # i64.eqz

  # i32.wrap_i64 / i64.extend_i32_s / i64.extend_i32_u
  defp unop(0xA7, a), do: mask32(a)
  defp unop(0xAC, a), do: sext64_e({:op, @ln, :band, a, {:integer, @ln, @mask32}}, 32)
  defp unop(0xAD, a), do: {:op, @ln, :band, a, {:integer, @ln, @mask64}}

  # f64 unary maths
  defp unop(0x99, a), do: call_remote(:erlang, :abs, [a])
  defp unop(0x9A, a), do: {:op, @ln, :-, a}
  defp unop(0x9F, a), do: call_remote(:math, :sqrt, [a])
  # f32 unary maths (round result)
  defp unop(0x8B, a), do: f32r_e(call_remote(:erlang, :abs, [a]))
  defp unop(0x8C, a), do: f32r_e({:op, @ln, :-, a})
  defp unop(0x91, a), do: f32r_e(call_remote(:math, :sqrt, [a]))

  # count leading/trailing zeros + popcount (no BEAM BIF; mirror the interpreter's helpers exactly)
  defp unop(0x67, a), do: call_remote(__MODULE__, :wclz, [a, {:integer, @ln, 32}])
  defp unop(0x68, a), do: call_remote(__MODULE__, :wctz, [a, {:integer, @ln, 32}])
  defp unop(0x69, a), do: call_remote(__MODULE__, :wpopcnt, [a])
  defp unop(0x79, a), do: call_remote(__MODULE__, :wclz, [a, {:integer, @ln, 64}])
  defp unop(0x7A, a), do: call_remote(__MODULE__, :wctz, [a, {:integer, @ln, 64}])
  defp unop(0x7B, a), do: call_remote(__MODULE__, :wpopcnt, [a])

  # ceil/floor/trunc/nearest — mirror the interpreter EXACTLY (Float.ceil/floor, trunc·1.0, ties-to-even)
  # so the lanes agree bit-for-bit. f32 variants re-round to single precision via f32r.
  defp unop(0x8D, a), do: f32r_e(call_remote(Float, :ceil, [a]))
  defp unop(0x8E, a), do: f32r_e(call_remote(Float, :floor, [a]))
  defp unop(0x8F, a), do: f32r_e(call_remote(__MODULE__, :ftruncf, [a]))
  defp unop(0x90, a), do: f32r_e(call_remote(__MODULE__, :fnearest, [a]))
  defp unop(0x9B, a), do: call_remote(Float, :ceil, [a])
  defp unop(0x9C, a), do: call_remote(Float, :floor, [a])
  defp unop(0x9D, a), do: call_remote(__MODULE__, :ftruncf, [a])
  defp unop(0x9E, a), do: call_remote(__MODULE__, :fnearest, [a])

  # float→int truncation with the WASM range check (traps :conversion_overflow / :invalid_conversion),
  # then mask to the target width (matches the interpreter's `ftrunc(a,lo,hi) &&& mask`).
  defp unop(0xA8, a), do: trunc_int_e(a, -0x80000000, 0x7FFFFFFF, @mask32)
  defp unop(0xA9, a), do: trunc_int_e(a, 0, 0xFFFFFFFF, @mask32)
  defp unop(0xAA, a), do: trunc_int_e(a, -0x80000000, 0x7FFFFFFF, @mask32)
  defp unop(0xAB, a), do: trunc_int_e(a, 0, 0xFFFFFFFF, @mask32)
  defp unop(0xAE, a), do: trunc_int_e(a, -0x8000000000000000, 0x7FFFFFFFFFFFFFFF, @mask64)
  defp unop(0xAF, a), do: trunc_int_e(a, 0, 0xFFFFFFFFFFFFFFFF, @mask64)
  defp unop(0xB0, a), do: trunc_int_e(a, -0x8000000000000000, 0x7FFFFFFFFFFFFFFF, @mask64)
  defp unop(0xB1, a), do: trunc_int_e(a, 0, 0xFFFFFFFFFFFFFFFF, @mask64)

  # conversions int->float
  defp unop(0xB2, a), do: f32r_e(int_to_float(s32(a)))           # f32.convert_i32_s
  defp unop(0xB3, a), do: f32r_e(int_to_float(a))               # f32.convert_i32_u
  defp unop(0xB4, a), do: f32r_e(int_to_float(s64(a)))           # f32.convert_i64_s
  defp unop(0xB5, a), do: f32r_e(int_to_float(a))               # f32.convert_i64_u
  defp unop(0xB7, a), do: int_to_float(s32(a))                  # f64.convert_i32_s
  defp unop(0xB8, a), do: int_to_float(a)                       # f64.convert_i32_u
  defp unop(0xB9, a), do: int_to_float(s64(a))                  # f64.convert_i64_s
  defp unop(0xBA, a), do: int_to_float(a)                       # f64.convert_i64_u
  defp unop(0xB6, a), do: f32r_e(a)                            # f32.demote_f64
  defp unop(0xBB, a), do: int_to_float_promote(a)               # f64.promote_f32 (float→float, no-op)

  # reinterprets (bit-exact)
  defp unop(0xBC, a), do: call_remote(__MODULE__, :f32_to_bits, [a])  # i32.reinterpret_f32
  defp unop(0xBD, a), do: call_remote(__MODULE__, :f64_to_bits, [a])  # i64.reinterpret_f64
  defp unop(0xBE, a), do: call_remote(__MODULE__, :f32_from_bits, [{:op, @ln, :band, a, {:integer, @ln, @mask32}}])  # f32.reinterpret_i32
  defp unop(0xBF, a), do: call_remote(__MODULE__, :f64_from_bits, [{:op, @ln, :band, a, {:integer, @ln, @mask64}}])  # f64.reinterpret_i64

  # sign-extend ops within a type
  defp unop(0xC0, a), do: sext32_e({:op, @ln, :band, a, {:integer, @ln, 0xFF}}, 8)
  defp unop(0xC1, a), do: sext32_e({:op, @ln, :band, a, {:integer, @ln, 0xFFFF}}, 16)
  defp unop(0xC2, a), do: sext64_e({:op, @ln, :band, a, {:integer, @ln, 0xFF}}, 8)
  defp unop(0xC3, a), do: sext64_e({:op, @ln, :band, a, {:integer, @ln, 0xFFFF}}, 16)
  defp unop(0xC4, a), do: sext64_e({:op, @ln, :band, a, {:integer, @ln, @mask32}}, 32)

  defp unop(op, _a), do: throw({:unsupported, {:op, op}})

  defp cmp(operator, a, b) do
    {:case, @ln, {:op, @ln, operator, a, b},
     [
       {:clause, @ln, [{:atom, @ln, true}], [], [{:integer, @ln, 1}]},
       {:clause, @ln, [{:atom, @ln, false}], [], [{:integer, @ln, 0}]}
     ]}
  end

  # case {A,B} of {_,0} -> trap; {INT_MIN,-1} -> trap (div_s only); {A,B} -> A op B end
  defp trap_div(a, b, op, overflow?, signed?) do
    av = if signed?, do: s32(a), else: a
    bv = if signed?, do: s32(b), else: b
    avar = uvar("DvA")
    bvar = uvar("DvB")

    zero = {:clause, @ln, [{:tuple, @ln, [{:var, @ln, :_}, {:integer, @ln, 0}]}], [], [trap_call(:div_by_zero)]}

    ovf =
      if overflow? do
        [{:clause, @ln, [{:tuple, @ln, [{:integer, @ln, -0x80000000}, {:integer, @ln, -1}]}], [], [trap_call(:int_overflow)]}]
      else
        []
      end

    main = {:clause, @ln, [{:tuple, @ln, [avar, bvar]}], [], [{:op, @ln, op, avar, bvar}]}
    {:case, @ln, {:tuple, @ln, [av, bv]}, [zero] ++ ovf ++ [main]}
  end

  defp trap_call(reason) do
    {:call, @ln, {:remote, @ln, {:atom, @ln, TinyLasers.Wasm.Trap}, {:atom, @ln, :trap!}}, [{:atom, @ln, reason}]}
  end

  defp shcount(b), do: {:op, @ln, :band, b, {:integer, @ln, 31}}
  defp shcount64(b), do: {:op, @ln, :band, b, {:integer, @ln, 63}}

  defp call_remote(mod, fun, args),
    do: {:call, @ln, {:remote, @ln, {:atom, @ln, mod}, {:atom, @ln, fun}}, args}

  # round an f32-result expr to single precision (matches the interpreter's f32r)
  defp f32r_e(expr), do: call_remote(__MODULE__, :f32r, [expr])

  # float→int trunc (range-checked) then mask to width: ftrunc_int(a,lo,hi) band mask
  defp trunc_int_e(a, lo, hi, mask) do
    {:op, @ln, :band, call_remote(__MODULE__, :ftrunc_int, [a, {:integer, @ln, lo}, {:integer, @ln, hi}]),
     {:integer, @ln, mask}}
  end

  # int * 1.0 → float
  defp int_to_float(expr), do: {:op, @ln, :*, expr, {:float, @ln, 1.0}}
  # f64.promote_f32: the value is already a BEAM float; identity
  defp int_to_float_promote(expr), do: expr

  # erlang:min/max — matches the interpreter's Elixir min/max (no NaN special-casing on either side)
  defp fmin(a, b), do: call_remote(:erlang, :min, [a, b])
  defp fmax(a, b), do: call_remote(:erlang, :max, [a, b])

  # i64 signed div/rem trap (zero divisor + INT64_MIN / -1 overflow for div_s)
  defp trap_div64(a, b, op, overflow?, signed?) do
    av = if signed?, do: s64(a), else: a
    bv = if signed?, do: s64(b), else: b
    avar = uvar("Dv64A")
    bvar = uvar("Dv64B")
    zero = {:clause, @ln, [{:tuple, @ln, [{:var, @ln, :_}, {:integer, @ln, 0}]}], [], [trap_call(:div_by_zero)]}

    ovf =
      if overflow? do
        [{:clause, @ln, [{:tuple, @ln, [{:integer, @ln, -0x8000000000000000}, {:integer, @ln, -1}]}], [], [trap_call(:int_overflow)]}]
      else
        []
      end

    main = {:clause, @ln, [{:tuple, @ln, [avar, bvar]}], [], [{:op, @ln, op, avar, bvar}]}
    {:case, @ln, {:tuple, @ln, [av, bv]}, [zero] ++ ovf ++ [main]}
  end

  # rotate: ((A bsl n) bor (A bsr (W-n))) band MASK, with n already in [0,W). Matches rotl/rotr32/64.
  defp rot32(a, b, dir), do: rot(a, b, 32, @mask32, dir)
  defp rot64(a, b, dir), do: rot(a, b, 64, @mask64, dir)

  defp rot(a, b, width, mask, dir) do
    av = uvar("RtA")
    nv = uvar("RtN")
    {l, r} =
      case dir do
        :l -> {nv, {:op, @ln, :-, {:integer, @ln, width}, nv}}
        :r -> {{:op, @ln, :-, {:integer, @ln, width}, nv}, nv}
      end

    body =
      {:op, @ln, :band,
       {:op, @ln, :bor, {:op, @ln, :bsl, av, l}, {:op, @ln, :bsr, av, r}},
       {:integer, @ln, mask}}

    # n==0 → identity (avoid `bsr A 32`/`bsl A 0`-style edge yielding wrong bits when width-n==width)
    {:block, @ln,
     [
       {:match, @ln, av, a},
       {:match, @ln, nv, {:op, @ln, :band, b, {:integer, @ln, width - 1}}},
       {:case, @ln, nv,
        [
          {:clause, @ln, [{:integer, @ln, 0}], [], [av]},
          {:clause, @ln, [{:var, @ln, :_}], [], [body]}
        ]}
     ]}
  end

  defp mask64(expr), do: {:op, @ln, :band, expr, {:integer, @ln, @mask64}}

  # sign-extend an n-bit (already-masked) value to the 32/64-bit unsigned representation.
  defp sext32_e(masked, bits), do: sext_to(masked, bits, 32, @mask32)
  defp sext64_e(masked, bits), do: sext_to(masked, bits, 64, @mask64)

  defp sext_to(masked, bits, _width, mask) do
    half = 1 <<< (bits - 1)
    full = 1 <<< bits
    v = uvar("Se")
    {:block, @ln,
     [
       {:match, @ln, v, masked},
       {:case, @ln, {:op, @ln, :>=, v, {:integer, @ln, half}},
        [
          {:clause, @ln, [{:atom, @ln, true}], [], [{:op, @ln, :band, {:op, @ln, :-, v, {:integer, @ln, full}}, {:integer, @ln, mask}}]},
          {:clause, @ln, [{:atom, @ln, false}], [], [v]}
        ]}
     ]}
  end

  defp s64(expr) do
    v = uvar("Sg64")
    {:case, @ln, expr,
     [
       {:clause, @ln, [v], [[{:op, @ln, :>=, v, {:integer, @ln, 0x8000000000000000}}]], [{:op, @ln, :-, v, {:integer, @ln, 0x10000000000000000}}]},
       {:clause, @ln, [v], [], [v]}
     ]}
  end

  defp s32(expr) do
    v = uvar("Sg")
    {:case, @ln, expr,
     [
       {:clause, @ln, [v], [[{:op, @ln, :>=, v, {:integer, @ln, 0x80000000}}]], [{:op, @ln, :-, v, {:integer, @ln, 0x100000000}}]},
       {:clause, @ln, [v], [], [v]}
     ]}
  end

  defp mask32(expr), do: {:op, @ln, :band, expr, {:integer, @ln, @mask32}}

  defp var(name) when is_binary(name), do: {:var, @ln, String.to_atom(name)}

  # A UNIQUE Erlang variable. Helpers like s32/s64/sext/div/rot bind a temp in BOTH case clauses, which
  # Erlang then EXPORTS to the enclosing scope — so reusing one fixed name across two calls in the same
  # expression (e.g. `s32(a) =< s32(b)`) turns the second binding into a match against the first value →
  # CaseClauseError. A per-call unique suffix keeps each temp independent.
  defp uvar(base), do: {:var, @ln, :"_#{base}#{:erlang.unique_integer([:positive])}"}
end
