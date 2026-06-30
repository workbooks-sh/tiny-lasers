defmodule TinyLasers.Js.Debug do
  @moduledoc """
  Durable observability for the **Porffor JS→WASM→TinyLasers.Wasm** lane.

  Debugging this lane used to mean ephemeral scripts + 600s reruns + ad-hoc instrumentation thrown away
  each time. This module makes it one call. `diagnose/2` compiles a JS program through Porffor (with the
  wasm "name" section, so every function is named), runs it on the TinyLasers.Wasm interpreter with a **bounded** fuel
  budget and **per-function call profiling**, then returns a structured report:

      %TinyLasers.Js.Debug.Report{
        output: "h1=<h1>Hello</h1>",          # what the guest printed
        error:  {:TypeError, "x is not a function"},  # decoded [ptr,type], or nil
        trap:   :out_of_bounds,               # TinyLasers.Wasm trap reason, or nil
        hot:    [{"__Porffor_malloc", 48547}, {"__TypeError_prototype_toString", 23127}, ...],
        elapsed_ms: 1200,
        completed: false
      }

  The `hot` list is the killer feature: a runaway loop or a trap localizes instantly to NAMED Porffor
  functions (a repeated `__TypeError_prototype_toString` = an exception thrown every iteration; a dominant
  `__Porffor_malloc` = runaway allocation), no recompile-with-`-d` dance, no guessing.

  CLI: `mix porffor.debug <file.js> [--fuel N] [--top N] [--transpile] [--prelude P]`.

  ## Predictive conformance stack (cheap gates before test262/bundles)

  Use `mix porffor.check [file.js]` for the full tiered workflow, or individual tools:

    * `mix porffor.preflight <file.js>` — AST seam scanner (`TinyLasers.Js.Preflight`)
    * `mix porffor.census [--compare]` — feature probe matrix vs node (`TinyLasers.Js.Census`)
    * `mix porffor.coverage <file.js>` — WASM→ASM native % (`TinyLasers.Js.AsmCoverage`)
    * `TinyLasers.Js.Porffor.check_invariants/1` — closure-conversion invariant gate

  See `conformance/README.work` for CI posture and tier ordering.

  ## Methodology — how to debug the Porffor→TinyLasers.Wasm lane fast (read before grinding)

  The wall-clock killer is **serial guess-and-rerun**. The fixes that made this lane tractable:

  1. **MEASURE the assumption before fixing it.** Two "obvious" diagnoses this lane were both WRONG until
     measured: the "ASM-lane divergence/infinite-loop" was ordinary regex/codegen bugs (not an ASM-specific
     problem — it failed on interp too); and the marked "table needs no-GC memory" was a −2000 negative
     pointer (raising the memory cap 256MB→3GB changed nothing). One cheap measurement each killed a
     would-be multi-day rewrite. Never fix a layer until a measurement points at it.

  2. **Bisect with the corpus, not one case at a time.** Run a whole package's feature corpus, collect ALL
     failures in one pass (per-case = fresh wasm instance, since many parses in one instance hit the no-GC
     ceiling), then fix in batches. `run_corpus.exs` (CASE=<i> LANE=ASM|interp) is the harness.

  3. **Reproduce minimally, off the real artifact.** When a feature fails inside marked, lift the exact
     sub-expression (the regex, the `var` decl, the `splitCells` body) into a 5-line repro and diff the runtime vs
     `node`. Most bugs are general JS-semantics gaps (var-declarator zero-init, char-class byte-truncation,
     RegExp.lastIndex setter) that repro in isolation — and the fix then helps every package, not just marked.

  4. **Two lanes, both required, but pick the right one to debug on.** interp (`transpile: false`) is the
     oracle; the ASM transpiler (`transpile: true`) is what ships. They diverge in exactly one known way —
     `Sandbox.run_command` PREWARMS (eager transpile) and miscompiles (drops chars, G5); the LAZY transpile
     path this tool uses is correct. So debug + assert via this tool, never `Sandbox.run_command`.

  5. **Instrument TinyLasers.Wasm, gated.** `Process.put(:tl_oob_debug, true)` prints `{addr, n, limit, pages}` on
     every out-of-bounds — an `addr` near 2^32 is a wrapped negative pointer (a bad index), not memory
     exhaustion. `Process.put(:tl_callcount_on, true)` + `:tl_callcount` powers the named hot profile.
     Both are gated and cost nothing when off.

  The loop is: corpus → pick a failure → `diagnose` for the named function + decoded error/trap → if OOB,
  flip `:tl_oob_debug` for the address → minimal repro → fix the general gap → regen builtins → re-corpus.

  ## Both-sides x-ray (input AND output)

  We x-ray the **input** wasm with `wasm-tools print --print-offsets` (and `node runtime/index.js file -d`).
  For the **output** — what TinyLasers.Wasm's transpiler actually emits as BEAM — use `beam_asm/2` (or the gated
  `:tl_asm_dump`): it returns the emitted `:from_asm` forms AND `:beam_disasm.file/1` of the loaded
  `.beam`. (Note: these pool modules are loaded from an in-memory binary with no retained object code, so
  `erts_debug:df`/`:code.get_object_code` return `{:undef}`/`:error` — capture the binary at compile time
  instead, which is what `:tl_asm_dump` does.) This closes the loop: confirm the BEAM we generate matches
  intent, and diff our codegen shapes against what the OTP compiler emits for equivalent Elixir.
  """

  alias TinyLasers.Js.Porffor

  # Discovery root for compilers/<lang>/ (local — tiny-lasers owns the JS lane).
  defp default_root do
    Enum.find(["compilers", Path.expand("compilers", File.cwd!())], &File.dir?/1) || "compilers"
  end

  defmodule Report do
    @moduledoc false
    defstruct output: "", error: nil, trap: nil, hot: [], elapsed_ms: 0, completed: false, wasm_bytes: 0
  end

  # Porffor internal error type ids. SOURCE OF TRUTH = the value a real throw actually surfaces on the ASM
  # lane (MEASURED, not re-derived): compiling `throw new <X>Error()` and decoding the thrown `[ptr, type]`
  # gives TypeError=38, ReferenceError=39, SyntaxError=40, RangeError=41 (so Error=36, AggregateError=37,
  # EvalError=42, URIError=43, Test262Error=44 by the registration order in compiler/types.js). A static
  # re-read of types.js once suggested a +1 shift (a phantom `__Porffor_Empty` slot); the lane DISPROVED it
  # — the 36-based map is correct. This is verified empirically; do not "fix" it from source again.
  @error_types %{
    36 => :Error,
    37 => :AggregateError,
    38 => :TypeError,
    39 => :ReferenceError,
    40 => :SyntaxError,
    41 => :RangeError,
    42 => :EvalError,
    43 => :URIError,
    44 => :Test262Error
  }

  # TYPE_FLAGS (parity 0x80, length 0x40) can ride along on a type byte. Error types carry none, but mask
  # defensively so a flagged surfacing still resolves to the base error name rather than a bogus `typeN`.
  @type_flag_mask 0b00111111

  @default_fuel 2_000_000_000

  @doc """
  Compile + run `js` through the Porffor→TinyLasers.Wasm lane under a fuel cap, returning a `%Report{}`.

  Opts: `:fuel` (instruction budget, default #{@default_fuel}), `:top` (hot funcs to keep, default 25),
  `:entry` (exported function, default `"m"`), `:transpile` (asm lane, default false — pure interp gives
  the cleanest profile), `:root` (compiler root).
  """
  def diagnose(js, opts \\ []) when is_binary(js) do
    fuel = Keyword.get(opts, :fuel, @default_fuel)
    top = Keyword.get(opts, :top, 25)
    entry = Keyword.get(opts, :entry, "m")
    transpile = Keyword.get(opts, :transpile, false)
    max_pages = Keyword.get(opts, :max_pages)
    root = Keyword.get(opts, :root, default_root())

    # `report_error: true` makes Porffor.compile surface the raw compiler stderr on failure
    # (`{:error, {:compile_error, msg}}`) instead of the opaque `:unsupported`, so the test262 harness can
    # classify a parse-phase SyntaxError (a spec-correct rejection) distinctly. Off by default.
    # `skip_invariants: true` bypasses the cc_invariants gate — for probing whether a flagged shape is a REAL
    # miscompile (run + compare) or a false positive, without weakening the production gate.
    compile_opts = [debug: true] ++ Keyword.take(opts, [:report_error, :skip_invariants])

    with {:ok, wasm} <- Porffor.compile(js, root, compile_opts),
         {:ok, mod} <- TinyLasers.Wasm.decode_cached(wasm) do
      run(mod, byte_size(wasm), fuel, top, entry, transpile, max_pages)
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp run(mod, wasm_bytes, fuel, top, entry, transpile, max_pages \\ nil) do
    call_opts = [transpile: transpile, fuel: fuel] ++ if(max_pages, do: [max_pages: max_pages], else: [])
    out_append = fn s -> Process.put(:tl_out, [s | Process.get(:tl_out, [])]) end

    Process.put(:tl_imports, %{
      "a" => fn [v] -> out_append.(num_to_string(v)); nil end,
      "b" => fn [v] -> out_append.(<<trunc(v)::utf8>>); nil end,
      "c" => fn [] -> 0.0 end,
      "d" => fn [] -> 0.0 end,
      "e" => &TinyLasers.Js.PorfforHost.host_call/1
    })

    Process.put(:tl_backend, :map)
    Process.put(:tl_fds, %{})
    Process.put(:tl_nextfd, 4)
    Process.put(:tl_callcount_on, true)
    Process.put(:tl_callcount, %{})

    t0 = System.monotonic_time(:millisecond)

    {completed, error, trap, ok_out} =
      try do
        # call_io captures stdout and RETURNS it (then restores the prior :tl_out), so use the return on
        # success. On a throw it does NOT restore, so the catch reads the live dict instead.
        {_res, io} = TinyLasers.Wasm.call_io(mod, entry, [], call_opts)
        {true, nil, nil, IO.iodata_to_binary(io)}
      catch
        _, %TinyLasers.Wasm.Trap{reason: reason} -> {false, nil, reason, nil}
        _, {:wasm_exc, _, [ptr, type]} when is_number(ptr) -> {false, decode_error(type, ptr), nil, nil}
        _, other -> {false, {:caught, inspect(other, limit: 5)}, nil, nil}
      end

    elapsed = System.monotonic_time(:millisecond) - t0

    output =
      ok_out || (Process.get(:tl_out, []) |> Enum.reverse() |> IO.iodata_to_binary())

    Process.delete(:tl_callcount_on)

    hot =
      Process.get(:tl_callcount, %{})
      |> Enum.sort_by(fn {_, n} -> -n end)
      |> Enum.take(top)
      |> Enum.map(fn {key, n} ->
        {kind, idx} = case key do {:ind, f} -> {:indirect, f}; f -> {:direct, f} end
        name = Map.get(mod.func_names, idx, "func##{idx}")
        %{name: name, calls: n, index: idx, kind: kind}
      end)

    {:ok,
     %Report{
       output: output,
       error: error,
       trap: trap,
       hot: hot,
       elapsed_ms: elapsed,
       completed: completed,
       wasm_bytes: wasm_bytes
     }}
  end

  # A thrown Porffor error is `[ptr, type]`; the message string lives at `load_i32(ptr) -> msgptr`, then a
  # bytestring `<len::i32><bytes>` at msgptr. Memory survives the throw in `:tl_mem` (not restored on a
  # raised exception), so we can read it here.
  defp decode_error(type, ptr) do
    mem = Process.get(:tl_mem)
    id = Bitwise.band(trunc(type), @type_flag_mask)
    name = Map.get(@error_types, id, :"type#{trunc(type)}")

    msg =
      try do
        msgptr = u32(mem, trunc(ptr))
        len = u32(mem, msgptr)
        TinyLasers.Wasm.read_bytes(mem, msgptr + 4, min(len, 500))
      rescue
        _ -> "<unreadable>"
      end

    {name, msg}
  end

  defp u32(mem, addr) do
    <<v::little-32>> = TinyLasers.Wasm.read_bytes(mem, addr, 4)
    v
  end

  # Porffor prints numbers via the host `print` import; mirror Sandbox's integer-vs-float formatting.
  defp num_to_string(v) when is_integer(v), do: Integer.to_string(v)
  defp num_to_string(v) when is_float(v) do
    if v == Float.round(v) and abs(v) < 1.0e15, do: Integer.to_string(trunc(v)), else: Float.to_string(v)
  end

  defp num_to_string(v), do: to_string(v)

  @doc """
  Output-side x-ray: compile `js`, transpile its `:entry` export through the TinyLasers.Wasm wasm→BEAM-ASM lane, and
  return `[{module, emitted_asm_forms, loaded_bytecode}]` — the BEAM counterpart to `wasm-tools print` on the
  input. `emitted_asm_forms` is what TinyLasers.Wasm generates (`{:function, :wf_N, arity, …, [beam asm tuples]}`);
  `loaded_bytecode` is `:beam_disasm.file/1` of the compiled `.beam`. Use it to confirm the generated BEAM is
  what we intended, and to diff our codegen shapes against what the OTP compiler emits for equivalent Elixir
  (e.g. that our binary-loads match the `bs_match` shapes that matter). Opts: `:entry` (default "m"), `:root`.
  """
  def beam_asm(js, opts \\ []) when is_binary(js) do
    entry = Keyword.get(opts, :entry, "m")
    root = Keyword.get(opts, :root, default_root())

    with {:ok, wasm} <- Porffor.compile(js, root),
         {:ok, mod} <- TinyLasers.Wasm.decode_cached(wasm),
         fidx when is_integer(fidx) <- Map.get(mod.exports, entry) do
      Process.put(:tl_asm_dump, true)
      Process.put(:tl_asm_dumps, [])

      try do
        TinyLasers.Wasm.TranspileAsm.compile_module(mod, [fidx])
        Enum.reverse(Process.get(:tl_asm_dumps, []))
      after
        Process.delete(:tl_asm_dump)
        Process.delete(:tl_asm_dumps)
      end
    else
      nil -> {:error, {:no_export, entry}}
      other -> other
    end
  end

  @doc "Pretty one-line-per-row report for the CLI / IEx."
  def format(%Report{} = r) do
    status =
      cond do
        r.completed -> "COMPLETED"
        r.trap -> "TRAP #{r.trap}"
        r.error -> "THREW #{inspect(r.error)}"
        true -> "STOPPED"
      end

    head =
      "#{status} in #{r.elapsed_ms}ms  (wasm #{div(r.wasm_bytes, 1024)}KB)\n" <>
        "output: #{inspect(r.output)}\n" <>
        "--- hot functions (name : calls) ---"

    rows =
      r.hot
      |> Enum.map(fn h ->
        k = if h.kind == :indirect, do: "*", else: " "
        "#{k} #{String.pad_trailing(h.name, 42)} #{h.calls}"
      end)
      |> Enum.join("\n")

    head <> "\n" <> rows
  end
end
