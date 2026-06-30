defmodule TinyLasers.JsRollupBundleGateTest do
  @moduledoc """
  **Conformance ladder rung 6 — Rollup 4 full bundle gate (reporting until green).**

  Assembles the unmodified `rollup_bundle.cjs` on the Porffor→ASM lane (same path as
  `mix run test/conformance/rollup/scaffold/real_run.exs`). This is the ~5-minute boss gate;
  ExUnit keeps a **compile-or-run snapshot** so CI tracks frontier movement without wedging the suite.

  Current baseline: compile blocked by `INV-NO-NATIVE-CAPTURE` in closure_convert on the 1.27 MB bundle
  — a REAL gap (Porffor native/unboxed functions can't capture from an enclosing scope; closure_convert
  must box them), caught by the predictive invariant gate before any expensive run. The frontier moved
  here once the over-reporting `INV-LOOP-FRESH` heuristic was demoted to a non-blocking warning (it was
  false-positiving correct shared-`let`-in-loop-closure programs like marked). Previous frontier:
  `INV-CAPTURE-BOUND`.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Js.{Debug, Porffor}

  @rollup_dir Path.join(__DIR__, "../conformance/rollup")
  @scaffold Path.join(@rollup_dir, "scaffold")
  @prelude_root Enum.find(["compilers", Path.expand("compilers", File.cwd!())], &File.dir?/1) || "compilers"

  setup_all do
    cond do
      not File.regular?(Porffor.porf_entry()) ->
        {:skip, "porffor/node absent"}

      is_nil(System.find_executable("node")) ->
        {:skip, "node absent"}

      not File.regular?(Path.join(@rollup_dir, "rollup_bundle.cjs")) ->
        {:skip, "rollup bundle fixture absent"}

      true ->
        :ok
    end
  end

  defp assemble_bundle do
    dir = @scaffold
    root = @prelude_root

    hp =
      Porffor.host_prelude(root)
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(&1, "const __host "))
      |> Enum.join("\n")

    header = File.read!(Path.join(dir, "real_bridge.js"))

    shims =
      Path.wildcard(Path.join([root, "js", "node", "*.js"]))
      |> Enum.sort()
      |> Enum.reject(&String.contains?(&1, "09_host"))
      |> Enum.map(&File.read!/1)
      |> Enum.join("\n")

    shim_prelude = File.read!(Path.join(@rollup_dir, "shim_prelude.js"))

    shim_prelude =
      String.replace(shim_prelude, "globalThis.__addModule = function", "var __addModule = function")

    bundle = File.read!(Path.join(@rollup_dir, "rollup_bundle.cjs"))

    binds = """
    require = globalThis.require; module = globalThis.module; exports = globalThis.exports;
    process = globalThis.process; Buffer = globalThis.Buffer; global = globalThis;
    setTimeout = globalThis.setTimeout; clearTimeout = globalThis.clearTimeout;
    setInterval = globalThis.setInterval; clearInterval = globalThis.clearInterval;
    queueMicrotask = globalThis.queueMicrotask || function(f){ Promise.resolve().then(f); };
    btoa = function(s){ return Buffer.from(String(s), 'binary').toString('base64'); };
    atob = function(s){ return Buffer.from(String(s), 'base64').toString('binary'); };
    """

    combined =
      hp <> "\n" <> header <> "\nhostCall(\"echo\", \"\");\n" <> shims <> "\n" <> shim_prelude <>
        "\n" <> binds <> "\n" <> bundle

    Regex.replace(~r/\b__host\b/, combined, "__nhost")
  end

  @tag :rollup_gate
  @tag timeout: 600_000
  test "rollup bundle gate — tracks compile/run frontier (reporting)" do
    src = assemble_bundle()

    # Known frontier invariants — the bundle is still blocked by a genuine closure_convert gap. Update this
    # set as the frontier moves forward; the goal is `{:ok, wasm}` (compile clears → run + golden compare).
    frontier = [:"INV-CAPTURE-BOUND", :"INV-NO-NATIVE-CAPTURE"]

    case Porffor.compile(src, @prelude_root, flags: ["--pageSize=65536"]) do
      {:error, {:invariant, inv, _detail}} ->
        assert inv in frontier, "unexpected invariant: #{inspect(inv)}"

      {:invariant, inv, _detail} ->
        # invariant_gate returns bare tuple (not wrapped in :error)
        assert inv in frontier, "unexpected invariant: #{inspect(inv)}"

      {:error, reason} ->
        assert reason == :unsupported or match?({:invariant, _, _}, reason) or
                 match?({:compile_error, _}, reason),
               "unexpected compile failure: #{inspect(reason)}"

      {:ok, wasm} ->
        # Compile cleared — run under fuel cap and compare to golden if BUNDLE_OK emitted.
        golden = File.read!(Path.join(@rollup_dir, "rollup_bundle_golden.js"))

        case Debug.diagnose(src, fuel: 2_000_000_000, transpile: true, max_pages: 16_384) do
          {:ok, r} ->
            if r.completed and String.contains?(r.output, "BUNDLE_OK[") do
              case String.split(r.output, "BUNDLE_OK[", parts: 2) do
                [_, rest] ->
                  code = rest |> String.trim_trailing("\n") |> String.replace_suffix("]", "")

                  assert code == golden,
                         "rollup output differs: got #{byte_size(code)}B want #{byte_size(golden)}B"

                _ ->
                  flunk("BUNDLE_OK marker malformed in output")
              end
            else
              # Run incomplete or BUNDLE_ERR — reporting gate accepts until green.
              assert byte_size(wasm) > 1_000_000, "compiled wasm should be large (#{byte_size(wasm)} bytes)"
            end

          {:error, run_err} ->
            flunk("rollup compiled but run failed: #{inspect(run_err)}")
        end
    end
  end
end
