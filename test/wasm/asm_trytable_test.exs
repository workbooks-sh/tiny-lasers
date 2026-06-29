defmodule TinyLasers.WasmAsmTryTableTest do
  @moduledoc """
  try_table (the exception CATCH side, WASIX §0, wb-ngzd) in the BEAM-asm lane. A try_table is a BLOCK
  (its own ctrl frame; `br 0` in body exits it) wrapped in a BEAM try/try_case; catch clauses dispatch on
  the caught tag, push the tag's vals (+ an exnref for the _ref variants), and branch to label 0 (the
  try_table join) or an enclosing frame. Oracle: try_emit {:ok} (no fallback) AND interp == asm bit-identical.
  """
  use ExUnit.Case, async: true

  alias TinyLasers.Wasm
  alias TinyLasers.Wasm.TranspileAsm

  # tag 0 : (i32)->void  (arity 1). Common type table for every module below.
  # types: t0 = ()->i32 (the exported func), t1 = (i32)->void (tag 0's type).
  defp base, do: %{
    funcs: [0], tags: [1, 1], exports: %{"f" => 0},
    mem: {1, nil}, globals: [], data: [], imports: [], elements: []
  }

  defp mk(name, types, code) do
    struct(Wasm, Map.merge(base(), %{
      types: types, code: code, id: :crypto.hash(:sha256, name)
    }))
  end

  defp outcome(f) do
    try do
      {:ok, f.()}
    catch
      :throw, e -> {:throw, e}
    rescue
      e in TinyLasers.Wasm.Trap -> {:trap, e.reason}
    end
  end

  defp assert_oracle(m, args) do
    assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0), "must lower in the asm lane (no fallback)"
    interp = outcome(fn -> Wasm.call(m, "f", args, transpile: false) end)
    asm = outcome(fn -> apply(am, af, args) end)
    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)}"
    interp
  end

  # (a) catch clause that pushes vals: f() = try_table [catch 0 -> 0] { i32_const 7; throw 0 } end → 7.
  test "(a) catch with vals: thrown val is pushed and becomes the try_table result" do
    m = mk("a", [{[], [127]}, {[127], []}],
      [{0, [{:try_table, [{:catch, 0, 0}], [{:i32_const, 7}, {:throw, 0}]}]}])
    assert assert_oracle(m, []) == {:ok, 7}
  end

  # (b) catch_all with no vals: tag 0 arity 1 but catch_all pushes nothing; try_table is void, then const 9.
  test "(b) catch_all matches and pushes nothing" do
    m = mk("b", [{[], [127]}, {[127], []}],
      [{0, [
        {:try_table, [{:catch_all, 0}], [{:i32_const, 5}, {:throw, 0}]},
        {:i32_const, 9}
      ]}])
    assert assert_oracle(m, []) == {:ok, 9}
  end

  # (c) catch_ref pushes vals then exnref on top; throw_ref re-raises it PAST the try_table → propagates.
  test "(c) catch_ref pushes vals+exnref; throw_ref re-raises past the try_table" do
    m = mk("c", [{[], [127]}, {[127], []}],
      [{0, [
        # catch_ref pushes [v0, exnref]; drop the val, throw_ref the exnref → unwinds out of f.
        {:try_table, [{:catch_ref, 0, 0}], [{:i32_const, 3}, {:throw, 0}]},
        {:throw_ref},
        {:drop}
      ]}])
    # vals=[3]; exnref={:exnref,0,[3]} re-raised → {:wasm_exc,0,[3]} propagates.
    assert assert_oracle(m, []) == {:throw, {:wasm_exc, 0, [3]}}
  end

  # (c2) catch_all_ref pushes ONLY the exnref on top; throw_ref re-raises it.
  test "(c2) catch_all_ref pushes only exnref; throw_ref re-raises" do
    m = mk("c2", [{[], [127]}, {[127], []}],
      [{0, [
        {:try_table, [{:catch_all_ref, 0}], [{:i32_const, 8}, {:throw, 0}]},
        {:throw_ref}
      ]}])
    assert assert_oracle(m, []) == {:throw, {:wasm_exc, 0, [8]}}
  end

  # (d) uncaught: no matching clause (catch tag 1, but tag 0 is thrown) → propagates out identically.
  test "(d) no matching clause: exception propagates out of the function" do
    m = mk("d", [{[], [127]}, {[127], []}],
      [{0, [{:try_table, [{:catch, 1, 0}], [{:i32_const, 4}, {:throw, 0}]}]}])
    assert assert_oracle(m, []) == {:throw, {:wasm_exc, 0, [4]}}
  end

  # (e) catch clause with label>0 branches to an ENCLOSING block. Outer block result type i32.
  #   block { try_table [catch 0 -> 1] { i32_const 11; throw 0 } end ; i32_const 0 }  → catch br's to
  #   the outer block carrying the val 11, skipping the const 0; block result 11.
  test "(e) catch label>0 branches to an enclosing block" do
    m = mk("e", [{[], [127]}, {[127], []}],
      [{0, [
        {:block, 1, [
          {:try_table, [{:catch, 0, 1}], [{:i32_const, 11}, {:throw, 0}]},
          {:i32_const, 0}
        ]}
      ]}])
    assert assert_oracle(m, []) == {:ok, 11}
  end
end
