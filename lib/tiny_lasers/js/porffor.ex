defmodule TinyLasers.Js.Porffor do
  @moduledoc """
  **The Porffor JS→wasm fast lane — one layer, no inner interpreter.**

  Porffor (https://porffor.dev, MIT, vendored at `compilers/js/porffor/`) is an ahead-of-time JS/TS→wasm
  compiler: it compiles the program *itself* to a tiny wasm module, instead of shipping a JS engine that
  interprets it. Run on TinyLasers.Wasm's transpiler lane that is **near-native** — measured ~2500× faster than the
  same JS through quickjs-on-TinyLasers.Wasm on the AOT-friendly subset.

  Porffor compiles a **static subset** of JS (no `eval`/`new Function`; closures/async/generators/regex and
  swaths of stdlib are partial — see the gap census). A hard compile failure ⇒ `{:error, :unsupported}`.
  Silent miscompiles (wrong runtime output for a buggy feature) are NOT caught here — they're caught by the
  conformance harness that diffs Porffor output against an oracle during fork development.

  ## Module shape (differs from the quickjs WASI command module)
  Porffor output is **not** WASI: no `_start`, no `fd_write`. It exports the program top level as function
  **`m`** and imports its host I/O as single-char names assigned by `createImport` order
  (`String.fromCharCode(97 + index)`, builtins.js): **`a`=print(number), `b`=printChar(charcode),
  `c`=time, `d`=timeOrigin**. `run/2` provides these on TinyLasers.Wasm, captures `print`/`printChar` into the
  stdout buffer, and invokes `m`.
  """
  require Logger

  # Porffor's compiler (and our acorn pre-passes) recurse over the program AST; a large real bundle
  # (marked 49KB, rollup 1.27MB) blows V8's default stack → `RangeError: Maximum call stack size
  # exceeded` before any real codegen error. Raise the V8 stack for every Node invocation in the lane.
  # (2000 is well within the OS thread stack, so overflow stays a catchable RangeError, never a segfault.)
  @node_stack "--stack-size=3000"
  # Codegen for a large bundle (e.g. the 1.27MB Rollup artifact → a ~70MB wasm module) holds a lot of live
  # AST/wasm in the V8 old space; the default heap (~2–4GB) OOMs mid-codegen. Give generous headroom so a
  # real npm-scale workload compiles. Paired with @node_stack on every Node invocation in the lane.
  @node_heap "--max-old-space-size=8192"

  # Porffor's host imports, by their fixed single-char wasm name (createImport order). Only the USED ones
  # are emitted per program; providing all is harmless (TinyLasers.Wasm only calls imported funcs).
  @print "a"
  @print_char "b"
  @time "c"
  @time_origin "d"
  # The host-call bridge import (memory-exchange seam; see TinyLasers.Js.PorfforHost). Assigned the
  # next single-char wasm name by createImport order (after a/b/c/d).
  @host_call "e"

  # Discovery root for compilers/<lang>/ — the porffor tree lives at <root>/js/porffor. Resolves relative
  # to the current working dir (mix test/run from the tiny-lasers app root). (Local: was the shared
  # Nexus.Compilers.Shared.default_root; tiny-lasers owns the whole JS lane now, so it owns this too.)
  defp default_root do
    Enum.find(["compilers", Path.expand("compilers", File.cwd!())], &File.dir?/1) || "compilers"
  end

  # Owner-only (0700) private work dir for a per-compile tmp staging area. (Local: was Nexus.Paths.)
  defp mkdir_private!(dir) do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    dir
  end

  @doc "Path to the vendored Porffor `porf` CLI entrypoint."
  def porf_entry(root \\ default_root()),
    do: Path.expand(Path.join([root, "js", "porffor", "runtime", "index.js"]))

  @doc """
  The guest-side host-call bridge prelude (`hostCall`/`__host` over the `__host_call` import). Prepend it
  to a program that needs to call back into the host (e.g. a build tool routing parse to the Rust parser).
  Returns `""` if the file is absent.
  """
  def host_prelude(root \\ default_root()) do
    path = Path.expand(Path.join([root, "js", "porffor", "host_prelude.js"]))
    if File.regular?(path), do: File.read!(path), else: ""
  end

  # Porffor compiles async exactly like Rust/Tokio — async fns → in-wasm state machines, a Promise
  # microtask `jobQueue`, and `__Porffor_promise_runJobs` (the executor). But that executor is only driven
  # at main's end when the program references `Promise` EXPLICITLY (codegen.js:7072). An `async fn + .then`
  # doesn't, so the queue is never drained and callbacks never fire. Force the drive by referencing
  # `Promise` when the program uses async/await/then. (Real async I/O leaves — timers/network — would route
  # to the BEAM as the reactor; pure-compute async needs only this.)
  defp drive_async(source) do
    if source =~ ~r/\basync\b|\bawait\b|\.then\s*\(|\bPromise\b/ and not String.contains?(source, "Promise.resolve(0)/*drv*/"),
      do: "Promise.resolve(0)/*drv*/;\n" <> source,
      else: source
  end

  @transform_passes [
    "arguments_desugar.cjs",
    "map_desugar.cjs",
    "spread_desugar.cjs",
    "async_transform.cjs",
    "generator_transform.cjs",
    "destructure_desugar.cjs",
    "optional_call_desugar.cjs",
    "closure_convert.cjs"
  ]

  @doc "Run the AST pre-pass pipeline (same order as compile). Does not invoke Porffor."
  def transform_source(source, root \\ default_root()) when is_binary(source) do
    source
    |> drive_async()
    |> then(fn s ->
      Enum.reduce(@transform_passes, s, fn script, acc ->
        run_transform(acc, script, root, cc_invariants: cc_invariants_env?([]))
      end)
    end)
  end

  defp cc_invariants_env?(opts), do: Keyword.get(opts, :cc_invariants, false)

  @doc """
  Check closure-conversion invariants on source (runs transform pipeline + cc_invariants).
  Returns `{:ok, :clean}` or `{:error, {:invariant, inv, detail}}` or `{:error, reason}`.
  """
  def check_invariants(source, opts \\ []) when is_binary(source) do
    root = Keyword.get(opts, :root, default_root())
    script = Path.expand(Path.join([root, "js", "porffor", "check_invariants.cjs"]))

    unless File.regular?(script) do
      {:error, {:invariants_missing, script}}
    else
      tmp = Path.join(System.tmp_dir!(), "tl_inv_#{System.unique_integer([:positive])}.js")

      try do
        transformed = transform_source(source, root)
        File.write!(tmp, transformed)

        case System.cmd("node", [@node_stack, @node_heap, script, tmp, "--transformed"], stderr_to_stdout: true) do
          {out, 0} ->
            parse_invariants_out(out)

          {out, 1} ->
            case parse_invariants_out(out) do
              {:ok, :clean} -> {:error, {:invariant, :unknown, "violation reported but unparsed"}}
              {:error, {:invariant, inv, detail}} -> {:error, {:invariant, inv, detail}}
              other -> other
            end

          {out, _} ->
            {:error, {:invariants_failed, String.slice(out, 0, 300)}}
        end
      after
        File.rm(tmp)
      end
    end
  end

  defp parse_invariants_out(out) do
    line = out |> String.trim() |> String.split("\n") |> List.last() || "{}"

    cond do
      line =~ ~s("ok":true) or line =~ ~s("ok": true) ->
        {:ok, :clean}

      true ->
        # try first violation object in violations array
        case Regex.run(
               ~r/"violations"\s*:\s*\[\s*\{\s*"inv"\s*:\s*"([^"]+)"[^}]*"detail"\s*:\s*"((?:\\.|[^"\\])*)"/,
               line
             ) do
          [_, inv, detail] ->
            {:error, {:invariant, String.to_atom(inv), unescape_json(detail)}}

          _ ->
            case Regex.run(~r/"inv"\s*:\s*"([^"]+)"\s*,\s*"where"\s*:\s*"([^"]*)"\s*,\s*"detail"\s*:\s*"((?:\\.|[^"\\])*)"/, line) do
              [_, inv, _where, detail] ->
                {:error, {:invariant, String.to_atom(inv), unescape_json(detail)}}

              _ ->
                if line =~ ~s("ok":false) do
                  {:error, {:invariant, :violation, String.slice(line, 0, 200)}}
                else
                  {:error, {:invariants_parse, line}}
                end
            end
        end
    end
  end

  defp unescape_json(s),
    do: s |> String.replace("\\n", "\n") |> String.replace("\\\"", "\"") |> String.replace("\\\\", "\\")

  # Run an AST pre-pass script (compilers/js/porffor/<script>) on the host via Node. Returns the
  # transformed JS, or the original source on any error / missing script (the scripts self-fall-back too).
  defp run_transform(source, script_name, root, opts \\ []) do
    script = Path.expand(Path.join([root, "js", "porffor", script_name]))

    if File.regular?(script) do
      tmp = Path.join(System.tmp_dir!(), "nxc_cp_#{System.unique_integer([:positive])}.js")
      env = if cc_invariants_env?(opts) and script_name == "closure_convert.cjs", do: [{"CC_INVARIANTS", "1"}], else: []

      try do
        File.write!(tmp, source)

        case System.cmd("node", [@node_stack, @node_heap, script, tmp], env: env, stderr_to_stdout: false) do
          {out, 0} when byte_size(out) > 0 -> out
          _ -> source
        end
      rescue
        _ -> source
      catch
        _, _ -> source
      after
        File.rm(tmp)
      end
    else
      source
    end
  end

  @doc """
  Compile JS source → `{:ok, wasm_bytes}` or `{:error, :unsupported}`. Shells the vendored Porffor on the
  host's Node (build-time/trusted — the *output* wasm is what runs untrusted on TinyLasers.Wasm). Any Porffor failure
  (parse error, unsupported feature, link gap, empty output) classifies as `:unsupported` so the caller can
  decide; never a hard crash.
  """
  def compile(source, root \\ default_root(), opts \\ []) when is_binary(source) do
    entry = porf_entry(root)

    if not File.regular?(entry) do
      {:error, {:porffor_missing, entry}}
    else
      work = Path.join(System.tmp_dir!(), "nxc_porf_#{System.unique_integer([:positive])}")
      mkdir_private!(work)
      in_js = Path.join(work, "in.js")
      out_wasm = Path.join(work, "out.wasm")
      # AST pre-pass pipeline (wb-akrf): each isolated acorn→astring transform works around a Porffor gap,
      # falling back to its input on any error (so a pass never makes things worse). Order matters —
      # generators first (may introduce closures), then closure conversion (per-instance capture).
      cc_inv? = Keyword.get(opts, :cc_invariants, Mix.env() == :test)

      transformed =
        source
        |> drive_async()
        |> then(fn s ->
          Enum.reduce(@transform_passes, s, fn script, acc ->
            run_transform(acc, script, root, cc_invariants: cc_inv?)
          end)
        end)

      inv_result =
        if opts[:skip_invariants],
          do: {:ok, :clean},
          else: invariant_gate(check_invariants_on_transformed(transformed, root))

      with {:ok, :clean} <- inv_result do
        File.write!(in_js, transformed)

        wasm_args =
          ["wasm"] ++
            if(opts[:debug], do: ["-d"], else: []) ++
            (opts[:flags] || []) ++
            [in_js, out_wasm]

        try do
          case System.cmd("node", [@node_stack, @node_heap, entry | wasm_args], stderr_to_stdout: true) do
            {_out, 0} ->
              if File.regular?(out_wasm) and File.stat!(out_wasm).size > 0,
                do: {:ok, File.read!(out_wasm)},
                else: {:error, :unsupported}

            {out, _code} ->
              Logger.debug("porffor: unsupported — #{String.slice(out, 0, 200)}")
              if opts[:report_error], do: {:error, {:compile_error, String.slice(out, 0, 500)}}, else: {:error, :unsupported}
          end
        rescue
          e ->
            Logger.debug("porffor: invoke failed — #{Exception.message(e)}")
            {:error, :unsupported}
        after
          File.rm_rf(work)
        end
      end
    end
  end

  defp invariant_gate({:ok, :clean}), do: {:ok, :clean}
  defp invariant_gate({:error, {:invariant, _, _} = err}), do: err
  # checker/parse failures must not block compile — Porffor is the authority for syntax errors
  defp invariant_gate(_), do: {:ok, :clean}

  defp check_invariants_on_transformed(transformed, root) do
    script = Path.expand(Path.join([root, "js", "porffor", "check_invariants.cjs"]))
    tmp = Path.join(System.tmp_dir!(), "tl_inv_#{System.unique_integer([:positive])}.js")

    try do
      File.write!(tmp, transformed)

      case System.cmd("node", [@node_stack, @node_heap, script, tmp, "--transformed"], stderr_to_stdout: true) do
        {out, 0} -> parse_invariants_out(out)
        {out, 1} -> parse_invariants_out(out)
        {out, _} -> {:error, {:invariants_failed, String.slice(out, 0, 300)}}
      end
    after
      File.rm(tmp)
    end
  end

  @doc """
  Run a Porffor wasm module on TinyLasers.Wasm (transpiler lane), returning `{:ok, stdout}`. Provides the print/
  printChar/time imports and invokes the exported `m`. Runs in an isolated task (per-run process dict).
  """
  def run(wasm_bytes, opts \\ []) when is_binary(wasm_bytes) do
    task =
      Task.async(fn ->
        try do
        case TinyLasers.Wasm.decode(wasm_bytes) do
          {:ok, mod} ->
            Process.put(:porffor_out, [])
            emit = fn s -> Process.put(:porffor_out, [s | Process.get(:porffor_out, [])]) end

            imports =
              %{
                @print => fn [v] -> emit.(num_to_string(v)); nil end,
                @print_char => fn [v] -> emit.(<<trunc(v)::utf8>>); nil end,
                @time => fn [] -> 0.0 end,
                @time_origin => fn [] -> 0.0 end,
                @host_call => &TinyLasers.Js.PorfforHost.host_call/1
              }
              # generator-fiber host imports (idents f/g/h): __porffor_gen_spawn/yield/resume.
              |> Map.merge(TinyLasers.Js.GeneratorHost.imports())

            Process.put(:tl_imports, imports)

            transpile? = Keyword.get(opts, :transpile, true)

            case TinyLasers.Wasm.instance_start(mod, "m", [], transpile: transpile?) do
              {:ok, _inst, _} ->
                {:ok, Process.get(:porffor_out, []) |> Enum.reverse() |> IO.iodata_to_binary()}

              other ->
                {:error, {:porffor_run, other}}
            end

          err ->
            err
        end
        rescue
          e -> {:error, {:porffor_run, Exception.message(e)}}
        catch
          kind, val -> {:error, {:porffor_run, {kind, val}}}
        end
      end)

    case Task.yield(task, Keyword.get(opts, :timeout_ms, 120_000)) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, {:porffor_run, :timeout}}
    end
  end

  @doc "Compile + run in one step: JS source → `{:ok, stdout}` | `{:error, :unsupported | reason}`."
  def eval(source, opts \\ []) do
    case compile(source) do
      {:ok, wasm} -> run(wasm, opts)
      err -> err
    end
  end

  # JS Number#toString for the f64 Porffor hands to `print`. Non-finite values are TinyLasers.Wasm's {:nonfinite,
  # bits, size} (BEAM has no NaN/Inf) → JS renders NaN/Infinity/-Infinity. Whole numbers render without a
  # decimal (999000.0 → "999000"); fractional via Elixir's shortest float repr. (Not yet full ECMAScript
  # ToString — Grisu/shortest-round-trip edge cases are a known gap, tracked for the conformance pass.)
  defp num_to_string({:nonfinite, bits, _size}) do
    cond do
      bits == 0x7FF0000000000000 -> "Infinity"
      bits == 0xFFF0000000000000 -> "-Infinity"
      true -> "NaN"
    end
  end

  defp num_to_string(v) when is_float(v) do
    if v == Float.round(v) and abs(v) < 9.007199254740992e15,
      do: Integer.to_string(trunc(v)),
      else: Float.to_string(v)
  end

  defp num_to_string(v), do: to_string(v)
end
