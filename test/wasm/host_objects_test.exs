defmodule TinyLasers.HostObjectsTest do
  @moduledoc """
  **Stage 2: the host object model end-to-end through the real lane.**

  Hand-built module exercises the `ho.*` import surface (`TinyLasers.Js.HostObjects`) the same way the
  Stage-3 codegen will: `ho.new()` to make an object handle, `ho.set(handle, hash, value, type)` per
  property, `ho.get_value`/`ho.get_type` for member access. Proves a JS object can live host-side as an
  i32-handle-keyed table and round-trip through `call_io` — independent of any Porffor codegen change.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Wasm
  alias TinyLasers.Js.HostObjects

  @i32 127
  @f64 124

  # types: 0 = ho.new ()->i32, 1 = ho.set (i32,i32,f64,i32)->(), 2 = ho.get_value (i32,i32)->f64,
  #        3 = ho.get_type (i32,i32)->i32, 4 = local func ()->f64 / ()->i32
  # imports occupy func idx 0..3; local funcs follow at idx 4, 5.
  defp mod(local_returns, instrs) do
    %Wasm{
      types: [
        {[], [@i32]},
        {[@i32, @i32, @f64, @i32], []},
        {[@i32, @i32], [@f64]},
        {[@i32, @i32], [@i32]},
        {[], local_returns}
      ],
      imports: [
        {"", "ho_new", 0},
        {"", "ho_set", 1},
        {"", "ho_get_value", 2},
        {"", "ho_get_type", 3}
      ],
      funcs: [4],
      code: [{1, instrs}],
      exports: %{"f" => 4},
      mem: nil,
      globals: [],
      data: [],
      elements: [],
      id: :crypto.hash(:sha256, :erlang.term_to_binary({local_returns, instrs}))
    }
  end

  setup do
    HostObjects.reset()
    Process.put(:tl_imports, HostObjects.imports())
    on_exit(fn ->
      Process.delete(:tl_imports)
      HostObjects.reset()
    end)
    :ok
  end

  defp unwrap([v]), do: v
  defp unwrap(v), do: v

  test "ho.new + ho.set + ho.get_value round-trips a property value" do
    # h = ho.new(); ho.set(h, 1234, 3.14, 1); return ho.get_value(h, 1234)
    instrs = [
      {:call, 0}, {:local_set, 0},
      {:local_get, 0}, {:i32_const, 1234}, {:fconst, 3.14}, {:i32_const, 1}, {:call, 1},
      {:local_get, 0}, {:i32_const, 1234}, {:call, 2},
      {:return}
    ]

    {r, _} = Wasm.call_io(mod([@f64], instrs), "f", [], transpile: false)
    assert unwrap(r) == 3.14
  end

  test "ho.get_type returns the stored type tag" do
    # h = ho.new(); ho.set(h, 7, 42.0, 195); return ho.get_type(h, 7)  -- 195 = string tag
    instrs = [
      {:call, 0}, {:local_set, 0},
      {:local_get, 0}, {:i32_const, 7}, {:fconst, 42.0}, {:i32_const, 195}, {:call, 1},
      {:local_get, 0}, {:i32_const, 7}, {:call, 3},
      {:return}
    ]

    {r, _} = Wasm.call_io(mod([@i32], instrs), "f", [], transpile: false)
    assert unwrap(r) == 195
  end

  test "absent property reads as 0.0 / undefined" do
    instrs = [
      {:call, 0}, {:local_set, 0},
      {:local_get, 0}, {:i32_const, 999}, {:call, 2},
      {:return}
    ]

    {r, _} = Wasm.call_io(mod([@f64], instrs), "f", [], transpile: false)
    assert unwrap(r) == 0.0
  end

  test "two distinct handles are independent objects" do
    # h1 = new(); set(h1, 1, 10.0, 1); h2 = new(); set(h2, 1, 20.0, 1); return get_value(h1, 1)
    # local 0 = h1, but we only have 1 declared local — reuse: store h1, set, make h2 via a second local.
    # Simpler: declare 2 locals via the {nlocals} count.
    instrs = [
      {:call, 0}, {:local_set, 0},
      {:local_get, 0}, {:i32_const, 1}, {:fconst, 10.0}, {:i32_const, 1}, {:call, 1},
      {:call, 0}, {:local_set, 1},
      {:local_get, 1}, {:i32_const, 1}, {:fconst, 20.0}, {:i32_const, 1}, {:call, 1},
      {:local_get, 0}, {:i32_const, 1}, {:call, 2},
      {:return}
    ]

    m = %{mod([@f64], instrs) | code: [{2, instrs}]}
    {r, _} = Wasm.call_io(m, "f", [], transpile: false)
    assert unwrap(r) == 10.0
  end
end
