defmodule TinyLasers.Js.Test262 do
  @moduledoc """
  A **test262 conformance harness** for the Porffor→Washy WASM→BEAM ASM transpiler lane — the lane that
  runs untrusted JS *emulated in WASM* (EMULATION THESIS). It decouples language-gap discovery from the
  expensive Rollup-bundle rung: instead of porting a big app to surface a gap reactively, we run the
  *official ECMAScript spec tests* cheaply and systematically and catalogue what the lane can't do yet.

  Native node is an **oracle only** — it never runs the tested code; it defines what the spec *says* via the
  vendored test262 harness (`assert.js`/`sta.js`, which THROW on a failed assertion). A positive test that
  runs to completion with no guest throw = pass; a negative test must throw the named error at the named
  phase.

  ## What this module does, given one test262 `.js` file path

    1. `parse_frontmatter/1` — reads the `/*--- … ---*/` YAML metadata block: `flags`
       (onlyStrict/noStrict/raw/async/module/generated), `negative` {phase, type}, `includes` (harness
       helpers), `features`.
    2. `assemble/2` — builds the full program: the standard harness includes (`assert.js`, `sta.js`) plus
       any `includes:`, plus the case body. `raw` flag = body only (no harness). `onlyStrict` = prepend
       `"use strict";`. The cjs prelude (globalThis/module/require shims the lane needs) is prepended too.
    3. `run_file/2` — compiles on the ASM lane (`TinyLasers.Js.Debug.diagnose/2`, `transpile: true`) and
       classifies the result against the spec expectation into a `%Result{}`.

  ## Result statuses (one per test)

    * `:pass`                — spec expectation met (positive: clean run; negative: right error at right phase)
    * `{:fail, :wrong_error, want, got}`  — negative test threw the WRONG error type
    * `{:fail, :no_throw}`                — negative test did not throw at all
    * `{:fail, :unexpected_throw, err}`   — positive test threw (assert.js failure or a real gap), decoded
    * `{:fail, :compile_error, reason}`   — Porffor/transform could not compile the program
    * `{:fail, :trap, reason}`            — the wasm trapped (OOB / unreachable) at runtime
    * `{:skip, reason}`                   — unsupported flag (module/async/raw-eval) — known not-yet-wired

  ## NO-JSON / DOGFOOD note

  Parsing test262's YAML frontmatter is a genuine data-format boundary (it is the upstream wire format), so
  it is fine. Our OWN curated-slice manifest is authored as a `.work` block
  (`test/conformance/test262/manifest.work`) per the NO-JSON-EVER rule — the blocks are the source of truth.
  """

  alias TinyLasers.Js.Debug

  defmodule Result do
    @moduledoc false
    defstruct [:path, :rel, :status, :strict, elapsed_ms: 0, error: nil]
  end

  # Flags we cannot honor on the lane yet → skip with a reason (never silently drop).
  @unsupported_flags ~w(module async raw)a

  @doc "Default harness dir inside the vendored clone (gitignored)."
  def harness_dir, do: Path.join(clone_root(), "harness")

  @doc "Root of the gitignored full test262 clone (in-tree, next to mix.exs)."
  def clone_root, do: Path.join(File.cwd!(), ".test262")

  @doc """
  Parse the `/*--- … ---*/` YAML frontmatter of a test262 file body.

  Returns a map with `:flags` (list of atoms), `:negative` (`%{phase: , type: }` or nil), `:includes`
  (list of harness filenames), `:features` (list of strings). Absent block ⇒ all-empty (a bare test).
  """
  def parse_frontmatter(body) when is_binary(body) do
    case Regex.run(~r{/\*---(.*?)---\*/}s, body, capture: :all_but_first) do
      [yaml] -> parse_yaml(yaml)
      _ -> %{flags: [], negative: nil, includes: [], features: [], raw_yaml: ""}
    end
  end

  # A deliberately small YAML reader: test262 frontmatter is a flat map with only the keys we care about
  # (flags/includes/features as `[a, b]` or block lists; negative as a 2-key sub-map). We avoid pulling a
  # YAML dep for this narrow, well-specified shape.
  defp parse_yaml(yaml) do
    flags = list_value(yaml, "flags") |> Enum.map(&String.to_atom/1)
    includes = list_value(yaml, "includes")
    features = list_value(yaml, "features")
    %{flags: flags, includes: includes, features: features, negative: negative(yaml), raw_yaml: yaml}
  end

  # `flags: [onlyStrict, async]` inline, OR a block list under `includes:` / `features:` on following lines.
  defp list_value(yaml, key) do
    inline =
      case Regex.run(~r{^\s*#{key}:\s*\[(.*?)\]}m, yaml, capture: :all_but_first) do
        [items] -> items |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
        _ -> nil
      end

    block =
      case Regex.run(~r{^\s*#{key}:\s*\n((?:\s*-\s*.+\n?)+)}m, yaml, capture: :all_but_first) do
        [lines] ->
          Regex.scan(~r{^\s*-\s*(.+?)\s*$}m, lines, capture: :all_but_first) |> Enum.map(&hd/1)

        _ -> nil
      end

    inline || block || []
  end

  defp negative(yaml) do
    case Regex.run(~r{^\s*negative:\s*\n((?:\s+.+\n?)+)}m, yaml, capture: :all_but_first) do
      [block] ->
        phase = scalar(block, "phase")
        type = scalar(block, "type")
        if type, do: %{phase: phase || "runtime", type: type}, else: nil

      _ ->
        nil
    end
  end

  defp scalar(s, key) do
    case Regex.run(~r{^\s*#{key}:\s*(\S+)}m, s, capture: :all_but_first) do
      [v] -> String.trim(v)
      _ -> nil
    end
  end

  @doc """
  Assemble the full runnable program for a parsed test. `opts[:strict]` forces `"use strict";`.
  `opts[:harness_dir]` overrides where include files are read from.
  """
  def assemble(body, meta, opts \\ []) do
    hdir = Keyword.get(opts, :harness_dir, harness_dir())
    strict = Keyword.get(opts, :strict, false)
    prelude = prelude()

    # `raw` cases get NO harness and NO prelude — but we skip them upstream, so this branch is defensive.
    if :raw in meta.flags do
      body
    else
      includes = ["assert.js", "sta.js"] ++ (meta.includes -- ["assert.js", "sta.js"])
      inc_src = Enum.map_join(includes, "\n", &read_include(hdir, &1))
      use_strict = if strict, do: ~s|"use strict";\n|, else: ""
      use_strict <> prelude <> "\n" <> inc_src <> "\n" <> body
    end
  end

  defp read_include(hdir, name) do
    path = Path.join(hdir, name)
    case File.read(path) do
      {:ok, s} -> s
      _ -> "// MISSING INCLUDE #{name}\n"
    end
  end

  # The cjs prelude shims (globalThis/module/require/process) the Porffor lane needs. Reuse the committed
  # conformance prelude so we don't drift two copies.
  defp prelude do
    p = Path.join([File.cwd!(), "test", "conformance", "porffor_cjs", "cjs_prelude.js"])
    case File.read(p) do
      {:ok, s} -> s
      _ -> "var globalThis={};var global=globalThis;var module={exports:{}};var exports=module.exports;\n"
    end
  end

  @doc """
  Run a single test262 file on the ASM lane and classify it. `opts` are forwarded to `diagnose/2`
  (`:fuel`, `:root`) and may carry `:rel` (the committed-relative path for reporting) and `:strict`.

  A test with both onlyStrict+noStrict absent runs in non-strict here (single representative run); the
  `:test262` gate runs both modes where a case demands it via `run_with_modes/2`.
  """
  def run_file(path, opts \\ []) do
    body = File.read!(path)
    meta = parse_frontmatter(body)
    rel = Keyword.get(opts, :rel, path)

    cond do
      Enum.any?(@unsupported_flags, &(&1 in meta.flags)) ->
        flag = Enum.find(@unsupported_flags, &(&1 in meta.flags))
        %Result{path: path, rel: rel, status: {:skip, "flag :#{flag} not wired"}}

      true ->
        run_assembled(path, body, meta, opts, rel)
    end
  end

  defp run_assembled(path, body, meta, opts, rel) do
    strict = Keyword.get(opts, :strict, false)
    asm_opts = [strict: strict] ++ Keyword.take(opts, [:harness_dir])
    src = assemble(body, meta, asm_opts)
    fuel = Keyword.get(opts, :fuel, 2_000_000_000)
    # `report_error: true` surfaces the raw compiler stderr on a compile failure so a parse-phase rejection
    # (engine refused to compile — e.g. `123n` bigint, a numeric-separator violation) can be recognised as a
    # spec SyntaxError@parse rather than miscounted as a generic compile_error gap.
    diag_opts = [fuel: fuel, transpile: true, report_error: true] ++ Keyword.take(opts, [:root])

    {status, err, ms} =
      case Debug.diagnose(src, diag_opts) do
        {:ok, r} -> classify(r, meta)
        {:error, reason} -> classify_compile_error(reason, meta)
      end

    %Result{path: path, rel: rel, status: status, error: err, strict: strict, elapsed_ms: ms}
  end

  # Map a %Debug.Report{} + spec expectation → status.
  defp classify(r, %{negative: neg}) do
    cond do
      # ── NEGATIVE test: spec demands a throw of a named type ──────────────────────────────
      neg != nil ->
        want = neg.type
        phase = neg.phase

        cond do
          # parse-phase negatives: a SyntaxError must surface at compile time (Porffor parse) OR as a
          # guest SyntaxError throw. Either way the type name must match.
          r.completed ->
            {{:fail, :no_throw, want}, nil, r.elapsed_ms}

          r.trap != nil ->
            # A trap is not the spec error — count as wrong, but record the trap.
            {{:fail, :wrong_error, want, "trap:#{r.trap}"}, r.trap, r.elapsed_ms}

          true ->
            got = error_name(r.error)
            if got == want,
              do: {:pass, nil, r.elapsed_ms},
              else: {{:fail, :wrong_error, want, "#{phase}:#{got}"}, r.error, r.elapsed_ms}
        end

      # ── POSITIVE test: clean completion (assert.js throws on failure) = pass ──────────────
      r.completed ->
        {:pass, nil, r.elapsed_ms}

      r.trap != nil ->
        {{:fail, :trap, r.trap}, r.trap, r.elapsed_ms}

      true ->
        {{:fail, :unexpected_throw, error_desc(r.error)}, r.error, r.elapsed_ms}
    end
  end

  # A compile failure is a PARSE-PHASE event (the engine refused to produce a module). Classify it against
  # the spec expectation:
  #   • negative {phase: parse, type: SyntaxError} + the compiler stderr IS a SyntaxError  ⇒ :pass
  #     (the engine correctly rejected the program at parse time — both type AND phase match).
  #   • negative expecting a SyntaxError at a NON-parse phase, or a non-SyntaxError type    ⇒ wrong_error/phase.
  #   • positive test, or any other expectation                                            ⇒ compile_error gap.
  # We never inflate: a parse rejection only passes a test that asked for SyntaxError@parse.
  defp classify_compile_error(reason, %{negative: neg}) do
    syntax? = compile_syntax_error?(reason)
    detail = inspect(reason, limit: 8)

    cond do
      neg != nil and neg.type == "SyntaxError" and neg.phase == "parse" and syntax? ->
        {:pass, nil, 0}

      neg != nil and neg.type == "SyntaxError" and syntax? ->
        # right type, wrong phase (spec wanted it at runtime/resolution, engine rejected at parse)
        {{:fail, :wrong_error, neg.type, "parse:SyntaxError(want phase #{neg.phase})"}, reason, 0}

      neg != nil and syntax? ->
        # engine raised SyntaxError@parse but spec wanted a different error type
        {{:fail, :wrong_error, neg.type, "parse:SyntaxError"}, reason, 0}

      true ->
        {{:fail, :compile_error, detail}, reason, 0}
    end
  end

  # Is this compile failure a *program* parse-phase SyntaxError — i.e. Porffor's parser rejected the tested
  # JS? `report_error: true` gives `{:compile_error, msg}` (raw stderr). A genuine spec rejection is thrown
  # from the program parser (`compiler/parse.js:66` normalizes 3rd-party parse errors → `new SyntaxError`),
  # so its trace names `parse.js`. We REQUIRE that origin to avoid a FALSE PASS from an *infrastructure*
  # SyntaxError — e.g. a node ESM module-load error (`node:internal/modules/…`, a half-written codegen.js)
  # is also a "SyntaxError" but must never be scored as the engine correctly rejecting a test.
  defp compile_syntax_error?({:compile_error, msg}) when is_binary(msg) do
    msg =~ "SyntaxError" and msg =~ "parse.js" and not (msg =~ "node:internal/modules")
  end

  defp compile_syntax_error?(_), do: false

  # The compile path can also reject a negative parse test — surface that as the named error if it matches.
  defp error_name({name, _msg}) when is_atom(name), do: Atom.to_string(name)
  defp error_name({:caught, _}), do: "caught"
  defp error_name(nil), do: "none"
  defp error_name(other), do: inspect(other, limit: 4)

  defp error_desc({name, msg}) when is_atom(name), do: "#{name}: #{String.slice(to_string(msg), 0, 120)}"
  defp error_desc(other), do: inspect(other, limit: 6)

  @doc """
  Run every `.js` (non-`_FIXTURE`) test under `dir` and return `{results, summary}`. `dir` may be inside the
  committed slice OR the gitignored clone. `opts[:limit]` caps the count (handy for spot probes).
  """
  def run_dir(dir, opts \\ []) do
    files =
      Path.wildcard(Path.join(dir, "**/*.js"))
      |> Enum.reject(&String.ends_with?(&1, "_FIXTURE.js"))
      |> Enum.sort()
      |> maybe_limit(Keyword.get(opts, :limit))

    results = Enum.map(files, fn f -> run_file(f, Keyword.put(opts, :rel, Path.relative_to(f, dir))) end)
    {results, summarize(results)}
  end

  defp maybe_limit(files, nil), do: files
  defp maybe_limit(files, n), do: Enum.take(files, n)

  @doc """
  Run only test files whose last cached signature matches `opts[:signature]`, or all files in `dir`
  when no cache exists. Falls back to full `run_dir/2` if cache missing and no sig filter.
  """
  def run_signatures(dir, opts \\ []) do
    sig = Keyword.get(opts, :signature)
    cache = signature_cache_path()

    files =
      Path.wildcard(Path.join(dir, "**/*.js"))
      |> Enum.reject(&String.ends_with?(&1, "_FIXTURE.js"))
      |> Enum.sort()

    filtered =
      cond do
        sig && File.regular?(cache) ->
          rels = Map.get(load_signature_cache(cache), sig, [])
          MapSet.new(rels)
          |> then(fn set ->
            Enum.filter(files, fn f -> MapSet.member?(set, Path.relative_to(f, dir)) end)
          end)

        true ->
          files
      end
      |> maybe_limit(Keyword.get(opts, :limit))

    results = Enum.map(filtered, fn f -> run_file(f, Keyword.put(opts, :rel, Path.relative_to(f, dir))) end)
    {results, summarize(results)}
  end

  defp signature_cache_path do
    Path.join([File.cwd!(), "test", "conformance", "test262", "last_run.work"])
  end

  @doc "Write signature → rel list cache (line format: `sig\\trel`)."
  def write_signature_cache(results, path \\ signature_cache_path()) do
    lines =
      results
      |> Enum.group_by(&signature/1, & &1.rel)
      |> Enum.flat_map(fn {sig, rels} ->
        Enum.map(rels, fn rel -> "#{sig}\t#{rel}" end)
      end)
      |> Enum.sort()

    header = "# test262 signature cache — generated by TinyLasers.Js.Test262.write_signature_cache/2\n"
    File.write!(path, header <> Enum.join(lines, "\n") <> "\n")
    :ok
  end

  @doc "Load signature cache as `%{signature => [rel, …]}`."
  def load_signature_cache(path \\ signature_cache_path()) do
    unless File.regular?(path), do: %{}, else: load_signature_cache!(path)
  end

  defp load_signature_cache!(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "\t", parts: 2) do
        [sig, rel] -> Map.update(acc, sig, [rel], &[rel | &1])
        _ -> acc
      end
    end)
  end

  @doc "Aggregate results → `%{total, pass, fail, skip, pass_pct, by_signature: %{sig => [rel,…]}}`."
  def summarize(results) do
    total = length(results)
    pass = Enum.count(results, &(&1.status == :pass))
    skip = Enum.count(results, &match?({:skip, _}, &1.status))
    fail = total - pass - skip

    by_sig =
      results
      |> Enum.filter(&match?({:fail, _, _}, &1.status) or match?({:fail, _, _, _}, &1.status) or match?({:fail, _}, &1.status))
      |> Enum.group_by(&signature/1, & &1.rel)

    %{
      total: total,
      pass: pass,
      fail: fail,
      skip: skip,
      pass_pct: if(total - skip > 0, do: Float.round(pass * 100 / (total - skip), 1), else: 0.0),
      by_signature: by_sig
    }
  end

  @doc "A coarse failure signature for grouping (shared root cause across many tests = a high-leverage rung)."
  def signature(%Result{status: status}), do: signature(status)
  def signature({:fail, :wrong_error, want, got}), do: "wrong_error want=#{want} got=#{got}"
  def signature({:fail, :no_throw, want}), do: "no_throw expected=#{want}"
  def signature({:fail, :trap, reason}), do: "trap:#{reason}"
  def signature({:fail, :compile_error, _}), do: "compile_error"
  def signature({:fail, :unexpected_throw, desc}), do: "throw:#{first_clause(desc)}"
  def signature({:skip, reason}), do: "skip:#{reason}"
  def signature(other), do: inspect(other)

  # group "TypeError: x is not a function" → "throw:TypeError" so a shared error class clusters.
  defp first_clause(desc) when is_binary(desc), do: desc |> String.split(":") |> hd()
  defp first_clause(desc), do: inspect(desc)

  @doc "Pretty-print a summary + grouped failures for the CLI/mix task."
  def format_report(summary, label) do
    head =
      "=== test262 on ASM lane: #{label} ===\n" <>
        "pass #{summary.pass}/#{summary.total - summary.skip} (#{summary.pass_pct}%)  " <>
        "fail #{summary.fail}  skip #{summary.skip}\n"

    groups =
      summary.by_signature
      |> Enum.sort_by(fn {_sig, rels} -> -length(rels) end)
      |> Enum.map_join("\n", fn {sig, rels} ->
        "  [#{length(rels)}] #{sig}\n" <>
          (rels |> Enum.sort() |> Enum.take(8) |> Enum.map_join("\n", &"      - #{&1}")) <>
          if(length(rels) > 8, do: "\n      … +#{length(rels) - 8} more", else: "")
      end)

    head <> "\n--- failures grouped by signature ---\n" <> groups <> "\n"
  end
end
