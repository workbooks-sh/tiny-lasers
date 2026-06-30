defmodule TinyLasers.WasmPorfforRollupBridgeTest do
  @moduledoc """
  **Porffor↔HostRollup bridge end-to-end — `rollup_parse` returns the AST buffer to the guest.**

  Proves the byte-ABI path a build tool needs: Porffor guest → `PorfforHost.host_call/1` →
  `TinyLasers.Wasm.HostRollup` (Rust parser sibling module) → flat AST bytes back into guest memory.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Js.Porffor

  @moduletag :porffor
  @dir Path.join(__DIR__, "../conformance/rollup")

  setup_all do
    cond do
      not File.regular?(Porffor.porf_entry()) ->
        {:skip, "porffor/node absent"}

      is_nil(System.find_executable("node")) ->
        {:skip, "node absent"}

      not File.regular?(Path.join(@dir, "rollup_parser.wasm")) ->
        {:skip, "rollup_parser.wasm absent"}

      true ->
        :ok
    end
  end

  defp run(body) do
    prog = Porffor.host_prelude() <> "\n" <> body

    case Porffor.eval(prog) do
      {:ok, out} -> {:ok, String.replace(out, ~r/\e\[[0-9;]*m/, "")}
      other -> other
    end
  end

  test "byte round-trip through guest memory (echo_upper)" do
    assert {:ok, out} =
             run("""
             const r = hostCall("echo_upper", "hello world");
             console.log(r.length); console.log(r[0]); console.log(r[1]);
             """)

    assert String.trim(out) |> String.split() == ["11", "72", "69"]
  end

  test "rollup_parse routes through HostRollup and returns the AST buffer to the guest" do
    assert {:ok, out} =
             run("""
             const ast = hostCall("rollup_parse", "const x = 1 + 2;");
             console.log(ast.length > 0 ? "GOT" : "EMPTY");
             """)

    assert String.trim(out) == "GOT"
  end

  test "rollup_parse_b64 returns base64 AST text for the unmodified bundle bridge" do
    assert {:ok, out} =
             run("""
             const b64 = hostCall("rollup_parse_b64", "export const x = 1;");
             console.log(b64.length > 10 ? "B64" : "SHORT");
             """)

    assert String.trim(out) == "B64"
  end
end
