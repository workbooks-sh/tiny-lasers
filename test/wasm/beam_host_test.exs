defmodule TinyLasers.WasmBeamHostTest do
  @moduledoc """
  The `Beam.*` JS↔OTP interop HOST SEAM (`wasm.ex` `call_host` clauses) — the memory→Actor→memory
  round-trip the guest's `Beam` global rides on, and the same JSON-over-memory bridge the `host_call`
  fs path (what rollup/vite need) uses. Exercised directly via `invoke_host` with a real packed memory.
  Migrated from nexus's `washy_beam_host_test.exs`; uses the zero-dep `TinyLasers.Wasm.Json` codec on the
  wire (no Jason), proving the bridge works with no external JSON dependency.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Wasm
  alias TinyLasers.Wasm.Actor
  alias TinyLasers.Wasm.Json

  setup do
    {Registry, keys: :unique, name: TinyLasers.Wasm.Actor.Registry} |> maybe_start()
    {DynamicSupervisor, strategy: :one_for_one, name: TinyLasers.Wasm.Actor.Supervisor} |> maybe_start()
    # a 1-page packed memory, installed where the host clauses read it (`wmem/0` → :tl_mem).
    mem = :atomics.new(8192, signed: false)
    Process.put(:tl_mem, mem)
    Process.put(:tl_mem_pages, 1)
    {:ok, mem: mem}
  end

  defp maybe_start(child) do
    case start_supervised(child) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, {{:already_started, _}, _}} -> :ok
    end
  end

  test "beam_call routes name+args from guest memory to an Elixir handler and writes the JSON reply back", %{mem: mem} do
    {:ok, _} = Actor.beam_spawn(fn [a, b], _ -> {a + b, nil} end, name: "adder")

    # poke the call args into guest memory, as the JS `Beam.call` host import would have.
    name = "adder"
    args = Json.encode!([3, 4])
    name_ptr = 100
    args_ptr = 200
    out_ptr = 300
    Wasm.write_bytes(mem, name_ptr, name)
    Wasm.write_bytes(mem, args_ptr, args)

    reply_len =
      Wasm.invoke_host(
        {"beam", "beam_call", nil},
        [name_ptr, byte_size(name), args_ptr, byte_size(args), out_ptr]
      )

    assert reply_len > 0
    assert Wasm.read_bytes(mem, out_ptr, reply_len) == Json.encode!(7)
  end

  test "beam_self writes the guest's handle into memory", %{mem: mem} do
    Process.put(:tl_actor_self, self())
    out_ptr = 400
    len = Wasm.invoke_host({"beam", "beam_self", nil}, [out_ptr])
    assert len > 0
    handle = Wasm.read_bytes(mem, out_ptr, len)
    # the handle is an encoded pid that decodes back to self()
    assert :erlang.list_to_pid(to_charlist(handle)) == self()
  end

  test "beam_send to a malformed handle returns -1 (never raises)", %{mem: mem} do
    msg = Json.encode!(%{"x" => 1})
    Wasm.write_bytes(mem, 200, msg)

    # a malformed handle string must be safe (list_to_pid would raise — guarded → -1)
    bad = "not-a-pid"
    Wasm.write_bytes(mem, 100, bad)
    assert -1 == Wasm.invoke_host({"beam", "beam_send", nil}, [100, byte_size(bad), 200, byte_size(msg)])
  end

  test "beam_send to a live spawned actor delivers (returns 0)", %{mem: mem} do
    test = self()
    {:ok, pid} = Actor.beam_spawn(fn m, _ -> send(test, {:got, m}); {nil, nil} end, name: "sink")
    handle = pid |> :erlang.pid_to_list() |> to_string()
    msg = Json.encode!(%{"hi" => 1})
    Wasm.write_bytes(mem, 100, handle)
    Wasm.write_bytes(mem, 200, msg)
    assert 0 == Wasm.invoke_host({"beam", "beam_send", nil}, [100, byte_size(handle), 200, byte_size(msg)])
    assert_receive {:got, %{"hi" => 1}}, 1000
  end

  test "beam_recv writes the stashed inbox JSON (null when empty)", %{mem: mem} do
    out_ptr = 500
    len = Wasm.invoke_host({"beam", "beam_recv", nil}, [out_ptr])
    assert Wasm.read_bytes(mem, out_ptr, len) == "null"

    Process.put(:tl_beam_inbox, Json.encode!(%{"hello" => "world"}))
    len2 = Wasm.invoke_host({"beam", "beam_recv", nil}, [out_ptr])
    assert Json.decode!(Wasm.read_bytes(mem, out_ptr, len2)) == %{"hello" => "world"}
  end
end
