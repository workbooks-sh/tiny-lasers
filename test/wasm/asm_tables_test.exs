defmodule TinyLasers.WasmAsmTablesTest do
  @moduledoc """
  **Table-driven ops on the BEAM-assembly lane (`TinyLasers.Wasm.AsmOps.Tables`).** `br_table` (multi-way
  branch on a popped index, incl. out-of-range → default) and `call_indirect` (resolve a table index at
  runtime → call on the shared state, incl. the bad-index trap). The contract is the lane's invariant:
  **asm-native == forms-native == interpreter, bit-identical.** We A/B `call_io(transpile: true,
  tier_threshold: 1, tier_async: false)` against `call_io(transpile: false)` so the SAME function runs
  through both the asm-native lane and the interpreter.
  """
  use ExUnit.Case, async: true

  alias TinyLasers.Wasm
  alias TinyLasers.Wasm.TranspileAsm

  # ── br_table ──────────────────────────────────────────────────────────────────────────────────────
  # f(sel) — a block-nest where br_table dispatches on `sel` to one of 3 blocks (each sets a local to a
  # distinct value), with an out-of-range index clamping to `default`.
  #
  #   (local r=0)
  #   block $a            ; depth 2 from inner br_table -> r := 10, exit all
  #     block $b          ; depth 1 -> r := 20
  #       block $c        ; depth 0 -> r := 30
  #         local.get sel
  #         br_table 0 1 2 (default 2)   ; sel=0->$c, 1->$b, _->$a
  #       end ; $c        (fallthrough after br to $c lands here)
  #       r := 30 ; br $a-equiv... — instead we keep it simple: each block's tail sets r then br to outer
  #     ...
  #
  # Simpler, well-defined shape: dispatch sets r via the block each target lands in.
  defp br_table_mod do
    instrs = [
      # r (local 1) default 99
      {:i32_const, 99}, {:local_set, 1},
      {:block, 0,
       [
         {:block, 0,
          [
            {:block, 0,
             [
               {:local_get, 0},
               # sel=0 -> br 0 (innermost, falls through to "r:=30"); sel=1 -> br 1; else -> br 2
               {:br_table, [0, 1], 2}
             ]},
            # landed from br 0 (sel == 0): r := 30, then br to outer-most end
            {:i32_const, 30}, {:local_set, 1},
            {:br, 1}
          ]},
         # landed from br 1 (sel == 1): r := 20, then br to outer-most end
         {:i32_const, 20}, {:local_set, 1},
         {:br, 0}
       ]},
      # landed from br 2 (default / sel >= 2): falls through to here with r still 99 UNLESS set above.
      # For default we set r := 10 here only if it wasn't a 0/1 hit — but both 0/1 br'd to the outer end,
      # so reaching here means default. Set r := 10.
      {:i32_const, 10}, {:local_set, 1},
      {:local_get, 1}
    ]

    %Wasm{
      types: [{[127], [127]}],
      funcs: [0],
      code: [{1, instrs}],
      exports: %{"f" => 0},
      mem: {1, nil},
      globals: [],
      data: [],
      imports: [],
      elements: [],
      id: :crypto.hash(:sha256, "br_table-mod")
    }
  end

  test "br_table dispatches incl. out-of-range→default, asm == interp == forms" do
    m = br_table_mod()
    # prove the ASM lane (not the forms fallback) actually lowers this br_table.
    assert {:ok, _} = TranspileAsm.try_emit(m, 0)

    for sel <- [0, 1, 2, 3, 7, 0xFFFFFFFF] do
      {interp, _} = Wasm.call_io(m, "f", [sel], transpile: false)
      {forms, _} = Wasm.call_io(m, "f", [sel], transpile: true, tier_threshold: 1, tier_async: false)

      assert interp == forms,
             "br_table @ sel=#{sel}: interp=#{inspect(interp)} forms=#{inspect(forms)}"
    end
  end

  # ── call_indirect ─────────────────────────────────────────────────────────────────────────────────
  # table[0] -> func1 (g: x -> x*2+1), table[1] -> func2 (h: x -> x*x). f(slot, x) = call_indirect(slot)(x).
  # An out-of-range slot (e.g. 5) traps :undefined_element in BOTH lanes.
  defp call_indirect_mod do
    %Wasm{
      types: [
        {[127, 127], [127]},  # type 0: f(slot, x)
        {[127], [127]}        # type 1: g/h (x) -> i32
      ],
      funcs: [0, 1, 1],
      code: [
        # func0 f(slot, x): push x, push slot, call_indirect type 1
        {0, [{:local_get, 1}, {:local_get, 0}, {:call_indirect, 1}]},
        # func1 g(x) = x*2 + 1
        {0, [{:local_get, 0}, {:i32_const, 2}, {:op, 0x6C}, {:i32_const, 1}, {:op, 0x6A}]},
        # func2 h(x) = x*x
        {0, [{:local_get, 0}, {:local_get, 0}, {:op, 0x6C}]}
      ],
      exports: %{"f" => 0},
      mem: {1, nil},
      globals: [],
      data: [],
      imports: [],
      # active element segment at offset 0: [func1, func2] -> table slots 0,1
      elements: [{[{:i32_const, 0}], [1, 2]}],
      id: :crypto.hash(:sha256, "call_indirect-mod")
    }
  end

  test "call_indirect hits 2+ table entries, asm == interp == forms" do
    m = call_indirect_mod()
    # prove func0 (the call_indirect) lowers through the ASM lane.
    assert {:ok, _} = TranspileAsm.try_emit(m, 0)

    # slot 0 -> g(x)=2x+1 ; slot 1 -> h(x)=x*x
    for {slot, x} <- [{0, 5}, {0, 0}, {1, 5}, {1, 7}, {0, 0xFFFF}, {1, 0xFFFF}] do
      {interp, _} = Wasm.call_io(m, "f", [slot, x], transpile: false)
      {forms, _} = Wasm.call_io(m, "f", [slot, x], transpile: true, tier_threshold: 1, tier_async: false)

      assert interp == forms,
             "call_indirect @ slot=#{slot} x=#{x}: interp=#{inspect(interp)} forms=#{inspect(forms)}"
    end
  end

  test "call_indirect bad index traps :undefined_element in both lanes" do
    m = call_indirect_mod()

    assert_raise TinyLasers.Wasm.Trap, fn -> Wasm.call_io(m, "f", [5, 1], transpile: false) end

    assert_raise TinyLasers.Wasm.Trap, fn ->
      Wasm.call_io(m, "f", [5, 1], transpile: true, tier_threshold: 1, tier_async: false)
    end
  end

  # ── reftypes + table.get/set/grow/size/fill (WASIX §0, asm lane) ─────────────────────────────────────
  # () -> i32 module with a table (min 2, max 10) so the table ops have something to act on.
  defp reftable_mod(instrs) do
    %Wasm{
      types: [{[], [127]}],
      funcs: [0],
      code: [{0, instrs}],
      exports: %{"f" => 0},
      mem: {1, nil},
      globals: [],
      data: [],
      imports: [],
      elements: [],
      table_type: {2, 10},
      id: :crypto.hash(:sha256, :erlang.term_to_binary(instrs))
    }
  end

  @reftable_cases [
    {"ref.null;is_null", [{:ref_null}, {:ref_is_null}]},
    {"ref.func;is_null", [{:ref_func, 0}, {:ref_is_null}]},
    {"table.size", [{:table_size}]},
    {"table.grow→old", [{:ref_null}, {:i32_const, 3}, {:table_grow}]},
    {"set;get;is_null", [{:i32_const, 1}, {:ref_func, 0}, {:table_set}, {:i32_const, 1}, {:table_get}, {:ref_is_null}]},
    {"fill;get;is_null", [{:i32_const, 0}, {:ref_func, 0}, {:i32_const, 2}, {:table_fill}, {:i32_const, 0}, {:table_get}, {:ref_is_null}]},
    {"get-empty;is_null", [{:i32_const, 0}, {:table_get}, {:ref_is_null}]}
  ]

  test "ref/table ops are ASM-emitted (no interp fallback) AND asm == interp" do
    for {name, instrs} <- @reftable_cases do
      m = reftable_mod(instrs)

      # try_emit {:ok} ⇒ the asm lane lowered EVERY op (no interp fallback). transpile:true then runs the
      # function through that asm lane WITH the run context (:washy_rt/:washy_table) — vs the interpreter.
      assert {:ok, _} = TranspileAsm.try_emit(m, 0),
             "#{name}: the asm lane must lower every op (no interp fallback)"

      {interp, _} = Wasm.call_io(m, "f", [], transpile: false)
      {asm, _} = Wasm.call_io(m, "f", [], transpile: true, tier_threshold: 1, tier_async: false)

      assert interp == asm, "#{name}: interp=#{inspect(interp)} asm=#{inspect(asm)}"
    end
  end
end
