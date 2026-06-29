defmodule TinyLasers.WasmPorfforHostCallTest do
  @moduledoc """
  **The Porffor↔host memory-exchange bridge on TinyLasers.Wasm — the mechanism rollup's I/O rides.**

  A Porffor-compiled guest (prelude + program) calls `__host('echo_upper', 'hello world')`. The `e`
  import (`__host_call`) reads the op + request bytes out of the guest's live linear memory, dispatches,
  writes the result region back, and returns the byte count — nothing but integers cross the wasm
  boundary. This is the EXACT ABI rollup's `__host('rollup_parse', …)` uses; proving it here de-risks the
  whole host-call I/O lane WITHOUT needing nexus's rollup machinery (the Rust parser, the render path).

  The dispatch (`echo_upper` → `String.upcase`) is implemented test-locally — identical to nexus's
  `PorfforHost.host_call` — so a byte-match proves: TinyLasers.Wasm executes a real host-calling guest
  identically to the nexus lane, with zero nexus coupling. The fixture is generated + validated on the
  nexus lane first (`tools/gen_porffor_fixtures.exs`).
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Wasm

  @fixtures_dir Path.expand(Path.join(__DIR__, "../fixtures/porffor"))

  setup_all do
    if File.regular?(Path.join(@fixtures_dir, "hostcall_echo.wasm")),
      do: :ok,
      else: {:skip, "host-call fixture absent — run tools/gen_porffor_fixtures.exs from nexus"}
  end

  test "guest __host('echo_upper', s) round-trips through linear memory on TinyLasers.Wasm" do
    got =
      Path.join(@fixtures_dir, "hostcall_echo.wasm")
      |> File.read!()
      |> run_with_hostcall()
      |> String.replace(~r/\e\[[0-9;]*m/, "")
      |> String.trim()

    assert got == "HELLO WORLD"
  end

  # a/b/c/d as the pure-compute lane, plus `e` = the host-call bridge. The `e` handler mirrors nexus's
  # PorfforHost.host_call: read op+req from the live :washy_mem, dispatch, write the result region back,
  # return the byte count (or -1.0 on overflow / unknown op). Dispatch is test-local — no nexus dep.
  defp run_with_hostcall(wasm) do
    {:ok, mod} = Wasm.decode(wasm)
    Process.put(:porffor_out, [])
    emit = fn s -> Process.put(:porffor_out, [s | Process.get(:porffor_out, [])]) end

    imports = %{
      "a" => fn [v] -> emit.(num_to_string(v)); nil end,
      "b" => fn [v] -> emit.(<<trunc(v)::utf8>>); nil end,
      "c" => fn [] -> 0.0 end,
      "d" => fn [] -> 0.0 end,
      "e" => &host_call/1
    }

    Process.put(:washy_imports, imports)
    {:ok, _inst, _} = Wasm.instance_start(mod, "m", [], transpile: true)
    Process.get(:porffor_out, []) |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp host_call([op_ptr, op_len, req_ptr, req_len, res_ptr, res_cap]) do
    mem = Process.get(:washy_mem)
    op = Wasm.read_bytes(mem, trunc(op_ptr), trunc(op_len))
    req = Wasm.read_bytes(mem, trunc(req_ptr), trunc(req_len))

    result =
      case op do
        "echo_upper" -> String.upcase(req)
        "echo" -> req
        _ -> nil
      end

    cond do
      result == nil -> -1.0
      byte_size(result) > trunc(res_cap) -> -1.0
      true ->
        Wasm.write_bytes(Process.get(:washy_mem), trunc(res_ptr), result)
        byte_size(result) * 1.0
    end
  end

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
