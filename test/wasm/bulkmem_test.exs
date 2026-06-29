defmodule TinyLasers.WasmBulkMemTest do
  @moduledoc """
  WASIX §0 — the remaining "gaps": bulk memory (memory.init/fill/copy) and sign-extension. memory.init
  (copy from a passive data segment) had no execution clause; this closes it. fill/copy + extend8_s
  confirm the rest of the gap set runs. (multi-value is implicit in the stack interpreter; trunc_sat has
  its own coverage.)
  """
  use ExUnit.Case, async: true
  alias TinyLasers.Wasm

  defp build(instrs, data \\ []) do
    %Wasm{
      types: [{[127, 127], [127]}],
      funcs: [0],
      code: [{0, instrs}],
      exports: %{"f" => 0},
      mem: {1, nil}, globals: [], data: data, imports: [], elements: [], table_type: nil, tags: [],
      id: :crypto.hash(:sha256, :erlang.term_to_binary({instrs, data}))
    }
  end

  defp run(instrs, data \\ []), do: Wasm.call_io(build(instrs, data), "f", [0, 0], transpile: false) |> elem(0)

  test "memory.init copies from a passive data segment (the closed gap)" do
    # data seg 0 = "ABCD"; init 3 bytes from src 0 → dst 10; load mem[10] → 'A' (65)
    out =
      run(
        [{:i32_const, 10}, {:i32_const, 0}, {:i32_const, 3}, {:memory_init, 0}, {:i32_const, 10}, {:i32_load8u, 0}],
        [{:passive, <<65, 66, 67, 68>>}]
      )

    assert out == 65
  end

  test "memory.fill writes a byte range" do
    assert run([{:i32_const, 0}, {:i32_const, 7}, {:i32_const, 3}, {:memory_fill}, {:i32_const, 1}, {:i32_load8u, 0}]) == 7
  end

  test "memory.copy duplicates a byte" do
    assert run([
      {:i32_const, 0}, {:i32_const, 9}, {:i32_store8, 0},
      {:i32_const, 5}, {:i32_const, 0}, {:i32_const, 1}, {:memory_copy},
      {:i32_const, 5}, {:i32_load8u, 0}
    ]) == 9
  end

  test "i32.extend8_s sign-extends a byte" do
    # 0xFF as i8 = -1 → 0xFFFFFFFF
    assert run([{:i32_const, 0xFF}, {:op, 0xC0}]) == 0xFFFFFFFF
  end
end
