defmodule TinyLasers.WasmAsmExceptionsTest do
  @moduledoc """
  exnref throw/throw_ref in the ASM lane (WASIX §0, wb-ngzd). Both raise the same {:wasm_exc,tag,vals}
  Elixir-throw the interpreter does, so an UNCAUGHT throw unwinds out of the function identically — which
  is what we assert here (try_table, the catch side, is the remaining piece handled in TranspileAsm).
  Oracle: try_emit {:ok} (asm-emitted, no fallback) AND the propagated outcome is bit-identical interp==asm.
  """
  use ExUnit.Case, async: true

  alias TinyLasers.Wasm
  alias TinyLasers.Wasm.TranspileAsm

  # f() -> i32 that throws tag 0 (tag type (i32)->void, arity 1) with a constant.
  defp throw_mod do
    %Wasm{
      types: [{[], [127]}, {[127], []}],
      funcs: [0],
      tags: [1],
      code: [{0, [{:i32_const, 42}, {:throw, 0}]}],
      exports: %{"f" => 0},
      mem: {1, nil}, globals: [], data: [], imports: [], elements: [],
      id: :crypto.hash(:sha256, "throw_mod")
    }
  end

  # f(exnref) -> void: local.get 0; throw_ref.
  defp throwref_mod do
    %Wasm{
      types: [{[127], []}],
      funcs: [0],
      tags: [],
      code: [{0, [{:local_get, 0}, {:throw_ref}]}],
      exports: %{"f" => 0},
      mem: {1, nil}, globals: [], data: [], imports: [], elements: [],
      id: :crypto.hash(:sha256, "throwref_mod")
    }
  end

  defp outcome(f) do
    try do
      f.()
      :no_throw
    catch
      :throw, e -> {:throw, e}
    rescue
      e in TinyLasers.Wasm.Trap -> {:trap, e.reason}
    end
  end

  test "throw: asm-emitted (no fallback) AND propagated {:wasm_exc} == interp" do
    m = throw_mod()
    assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0), "throw must lower in the asm lane"

    interp = outcome(fn -> Wasm.call_io(m, "f", [], transpile: false) end)
    asm = outcome(fn -> apply(am, af, []) end)

    assert interp == asm
    assert interp == {:throw, {:wasm_exc, 0, [42]}}
  end

  test "throw_ref: re-raises an exnref's exception, and traps on null/non-exnref — asm == interp" do
    m = throwref_mod()
    assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0), "throw_ref must lower in the asm lane"

    for {input, expected} <- [
          {{:exnref, 3, [99]}, {:throw, {:wasm_exc, 3, [99]}}},
          {:null, {:trap, :null_exnref}},
          {12345, {:trap, :not_an_exnref}}
        ] do
      interp = outcome(fn -> Wasm.call_io(m, "f", [input], transpile: false) end)
      asm = outcome(fn -> apply(am, af, [input]) end)

      assert interp == asm, "input=#{inspect(input)}: interp=#{inspect(interp)} asm=#{inspect(asm)}"
      assert interp == expected, "input=#{inspect(input)}: got #{inspect(interp)}, want #{inspect(expected)}"
    end
  end
end
