# Diagnose the rollup bundle: compile, run with a fuel cap + callcounts + trap-trace, then report
# (a) the top hot functions and whether each is ASM-OK or which instr forces an interp bail,
# (b) the innermost function if it traps :unreachable before the fuel runs out.
import Bitwise

dir = __DIR__
root = Enum.find(["compilers", Path.expand("compilers", File.cwd!())], &File.dir?/1) || "compilers"

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
shim_prelude = String.replace(shim_prelude, "globalThis.__addModule = function", "var __addModule = function")
bundle = File.read!(Path.join([dir, "..", "rollup_bundle.cjs"]))

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

{:ok, wasm} = TinyLasers.Js.Porffor.compile(combined, root, flags: ["--pageSize=65536"], skip_invariants: true)
{:ok, mod} = TinyLasers.Wasm.decode(wasm)
ni = length(mod.imports)
IO.puts("COMPILED wasm=#{div(byte_size(wasm),1024)}KB code=#{length(mod.code)} ni=#{ni}")

emit = fn s -> Process.put(:porffor_out, [s | Process.get(:porffor_out, [])]) end
Process.put(:tl_imports, %{
  "a" => fn [v] -> emit.(to_string(v)); nil end,
  "b" => fn [v] -> emit.(<<trunc(v)::utf8>>); nil end,
  "c" => fn [] -> 0.0 end,
  "d" => fn [] -> 0.0 end,
  "e" => &TinyLasers.Js.PorfforHost.host_call/1
})
Process.put(:tl_backend, :map)
Process.put(:tl_fds, %{})
Process.put(:tl_nextfd, 4)
Process.put(:tl_callcount_on, true)
Process.put(:tl_callcount, %{})
Process.put(:tl_trap_trace, true)

fuel = String.to_integer(System.get_env("FUEL") || "1000000000")
IO.puts("running fuel=#{fuel} ...")

{us, outcome} =
  :timer.tc(fn ->
    try do
      TinyLasers.Wasm.call_io(mod, "m", [], fuel: fuel, transpile: true, max_pages: 16384)
      :done
    rescue
      e in TinyLasers.Wasm.Trap ->
        IO.puts(:stderr, "TRAP reason=#{inspect(e.reason)}")
        :trap
    catch
      :throw, {:wasm_exc, _, _} -> :wasm_exc
      k, v -> {k, v}
    end
  end)

IO.puts("outcome=#{inspect(outcome)} elapsed=#{div(us,1000)}ms")

cc = Process.get(:tl_callcount, %{}) |> Enum.filter(fn {k, _} -> is_integer(k) end)
ranked = cc |> Enum.sort_by(fn {_, c} -> -c end) |> Enum.take(30)
total = ranked |> Enum.map(fn {_, c} -> c end) |> Enum.sum()
IO.puts("hot 30 local indices (#{total} calls counted):")
Enum.each(ranked, fn {li, c} -> IO.puts("  li=#{li} calls=#{c}") end)

IO.puts("\ndiagnose top 20 hot:")
ranked |> Enum.take(20) |> Enum.each(fn {li, c} ->
  gfidx = ni + li
  case TinyLasers.Wasm.TranspileAsm.diagnose_one(mod, gfidx) do
    {:ok, nlabels, nlocals, ninstr} ->
      IO.puts("  li=#{li} calls=#{c} => ASM-OK (ninstr=#{ninstr})")
    {:unsupported, instr} ->
      IO.write(["  li=", Integer.to_string(li), " calls=", Integer.to_string(c), " => UNSUPPORTED instr="])
      IO.inspect(instr, limit: :infinity)
  end
end)
