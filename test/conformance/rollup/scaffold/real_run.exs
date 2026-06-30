# Run the UNMODIFIED real rollup_bundle.cjs on the Porffor→TinyLasers.Wasm ASM (transpile) lane.
# Assembly: host_prelude + real_bridge.js + node shims + shim_prelude + binds + bundle.
# Compares emitted bundle to rollup_bundle_golden.js (66 bytes).
#
# Usage (from tiny-lasers/):
#   mix run test/conformance/rollup/scaffold/real_run.exs
#   FUEL=4000000000 MAX_PAGES=16384 mix run test/conformance/rollup/scaffold/real_run.exs
import Bitwise

dir = __DIR__
root =
  Enum.find(["compilers", Path.expand("compilers", File.cwd!())], &File.dir?/1) ||
    "compilers"

hp =
  TinyLasers.Js.Porffor.host_prelude(root)
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

shim_prelude = File.read!(Path.join([dir, "..", "shim_prelude.js"]))

shim_prelude =
  String.replace(shim_prelude, "globalThis.__addModule = function", "var __addModule = function")

bundle = File.read!(Path.join([dir, "..", "rollup_bundle.cjs"]))
golden = File.read!(Path.join([dir, "..", "rollup_bundle_golden.js"]))

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
  hp <> "\n" <> header <> "\nhostCall(\"echo\", \"\");\n" <> shims <> "\n" <> shim_prelude <> "\n" <>
    binds <> "\n" <> bundle

combined = Regex.replace(~r/\b__host\b/, combined, "__nhost")

IO.puts("ASSEMBLED #{byte_size(combined)} bytes")

compile_opts = [flags: ["--pageSize=65536"]]
# SKIP_INV=1 bypasses the cc_invariants gate to probe whether a flagged shape is a REAL miscompile
# (compare to golden) or a false positive — without weakening the production gate.
compile_opts =
  if System.get_env("SKIP_INV") == "1", do: Keyword.put(compile_opts, :skip_invariants, true), else: compile_opts

case TinyLasers.Js.Porffor.compile(combined, root, compile_opts) do
  {:ok, wasm} ->
    IO.puts("COMPILED wasm #{byte_size(wasm)}b")
    {:ok, mod} = TinyLasers.Wasm.decode(wasm)
    Process.put(:porffor_out, [])
    emit = fn s -> Process.put(:porffor_out, [s | Process.get(:porffor_out, [])]) end

    Process.put(:tl_imports, %{
      "a" => fn [v] -> emit.(to_string(v)); nil end,
      "b" => fn [v] -> emit.(<<trunc(v)::utf8>>); nil end,
      "c" => fn [] -> 0.0 end,
      "d" => fn [] -> 0.0 end,
      "e" => &TinyLasers.Js.PorfforHost.host_call/1
    })

    full = fn -> Process.get(:porffor_out, []) |> Enum.reverse() |> IO.iodata_to_binary() end

    report = fn ->
      s = full.()

      v =
        Regex.run(~r/BUNDLE_(OK|ERR)[^\n]*/, s)
        |> case do
          nil -> "NONE"
          [m | _] -> m
        end

      IO.puts("verdict=#{String.slice(v, 0, 200)}")

      case String.split(s, "BUNDLE_OK[", parts: 2) do
        [_, rest] ->
          code = rest |> String.trim_trailing("\n") |> String.replace_suffix("]", "")

          IO.puts(
            if code == golden,
              do: "*** BYTE-MATCH GOLDEN ***",
              else: "DIFF len got=#{byte_size(code)} want=#{byte_size(golden)}"
          )

        _ ->
          IO.puts("tail=" <> String.slice(s, max(byte_size(s) - 600, 0), 600))
      end
    end

    fuel = String.to_integer(System.get_env("FUEL") || "2000000000")

    try do
      TinyLasers.Wasm.call_io(mod, "m", [],
        fuel: fuel,
        transpile: true,
        max_pages: String.to_integer(System.get_env("MAX_PAGES") || "16384")
      )

      IO.puts("DONE")
      report.()
    rescue
      e ->
        IO.puts("TRAP #{Exception.message(e)}")
        report.()
    catch
      :throw, {:wasm_exc, _, [ptr, t]} ->
        msg =
          try do
            p = trunc(ptr)
            mem = Process.get(:tl_mem)
            <<mp::little-32>> = TinyLasers.Wasm.read_bytes(mem, p, 4)
            <<len::little-32>> = TinyLasers.Wasm.read_bytes(mem, mp, 4)
            TinyLasers.Wasm.read_bytes(mem, mp + 4, min(max(len, 0), 200))
          rescue
            _ -> "?"
          end

        IO.puts("THROW t=#{t} MSG=[#{msg}]")
        report.()
    end

  e ->
    IO.puts("COMPILE-FAIL #{inspect(e)}")
end
