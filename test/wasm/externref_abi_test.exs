defmodule TinyLasers.ExternrefAbiTest do
  @moduledoc """
  **Stage 1 of the externref value-ABI conversion: lock the RUNTIME contract.**

  The plan (docs/research/externref-abi-inventory.md) converts the Porffor JS-value representation from
  the dual-slot `[f64 value, i32 type-tag]` model to a single `externref` (wasm reftype `0x6f`) handle —
  a ~4× win on type-tag dispatch (`/tmp/externref_spike.exs`). Before touching Porffor codegen we pin the
  foundation the codegen will target: the tiny-lasers runtime already moves an opaque BEAM term through a
  wasm function as an `externref` value, and a host import can read a "property" off it (the `element/2`
  shape that replaces in-memory type-tag dispatch).

  This builds a module by hand — `f(ref: externref) -> f64` that calls an imported `e.prop(ref, key)` —
  and asserts a BEAM tuple flows in as externref and the property reads back. No assembler/codegen change
  is needed for Stage 1: `assemble.js` spreads raw valtype bytes (so `0x6f` passes through) and the
  decoder already accepts externref func signatures. This test is the regression guard for that contract.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Wasm

  @externref 111
  @i32 127
  @f64 124

  # f(ref, key) = e.prop(ref, key). import is func 0; local f is func 1.
  defp externref_mod do
    %Wasm{
      types: [
        {[@externref, @i32], [@f64]},
        {[@externref, @i32], [@f64]}
      ],
      imports: [{"e", "prop", 0}],
      funcs: [1],
      code: [{0, [{:local_get, 0}, {:local_get, 1}, {:call, 0}, {:return}]}],
      exports: %{"f" => 1},
      mem: nil,
      globals: [],
      data: [],
      elements: [],
      id: :crypto.hash(:sha256, "externref_abi_test")
    }
  end

  test "a BEAM term flows through a wasm function as externref and a host import reads a property" do
    m = externref_mod()
    # the object is a BEAM tuple; e.prop(ref, key) = element(key, ref) — the element/2 shape that replaces
    # linear-memory type-tag dispatch under the externref ABI.
    obj = {3.14, 42.0, 99.0}
    Process.put(:tl_imports, %{{"e", "prop"} => fn [ref, key] -> :erlang.element(round(key), ref) end})

    try do
      {r1, _} = Wasm.call_io(m, "f", [obj, 1], transpile: false)
      assert unwrap(r1) == 3.14

      {r2, _} = Wasm.call_io(m, "f", [obj, 2], transpile: false)
      assert unwrap(r2) == 42.0
    after
      Process.delete(:tl_imports)
    end
  end

  # call_io returns the stack top; a single f64 result may surface as a bare value or a 1-list.
  defp unwrap([v]), do: v
  defp unwrap(v), do: v
end
