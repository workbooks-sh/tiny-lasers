defmodule TinyLasers.WasmAsmTest do
  @moduledoc """
  **BEAM-assembly emission lane (epic wb-wzdq / wb-9icg).** `TranspileAsm.try_emit/2` lowers a wasm
  function straight to BEAM assembly and compiles it via `:compile.forms(.., [:from_asm])` — skipping the
  Erlang frontend + the superlinear `beam_ssa_opt` by construction, BeamAsm JITs to native. The contract
  is the same as the abstract-forms lane: **bit-identical to the interpreter**. This A/Bs the SAME
  functions through interp, the forms-native lane, and the asm-native lane — all three must agree — and
  asserts unsupported shapes fall back cleanly.
  """
  use ExUnit.Case, async: true

  alias TinyLasers.Wasm
  alias TinyLasers.Wasm.{Transpile, TranspileAsm}

  defp build(nlocals, instrs) do
    %Wasm{
      types: [{[127, 127], [127]}],
      funcs: [0],
      code: [{nlocals, instrs}],
      exports: %{"f" => 0},
      mem: {1, nil},
      globals: [],
      data: [],
      imports: [],
      elements: [],
      id: :crypto.hash(:sha256, :erlang.term_to_binary({nlocals, instrs}))
    }
  end

  @argsets [[0, 0], [5, 3], [3, 1], [0xFFFFFFFF, 2], [100, 7], [0xFFFFFFFF, 0xFFFFFFFF]]

  @cases [
    {"a+b", 0, [{:local_get, 0}, {:local_get, 1}, {:op, 0x6A}]},
    {"a*b-a", 0, [{:local_get, 0}, {:local_get, 1}, {:op, 0x6C}, {:local_get, 0}, {:op, 0x6B}]},
    {"a+7", 0, [{:local_get, 0}, {:i32_const, 7}, {:op, 0x6A}]},
    {"(a&b)|(a^b)", 0,
     [{:local_get, 0}, {:local_get, 1}, {:op, 0x71}, {:local_get, 0}, {:local_get, 1}, {:op, 0x73}, {:op, 0x72}]},
    {"c=a+b;c*c", 1,
     [{:local_get, 0}, {:local_get, 1}, {:op, 0x6A}, {:local_set, 2}, {:local_get, 2}, {:local_get, 2}, {:op, 0x6C}]},
    {"tee: a+(a:=a*b)", 1,
     [{:local_get, 0}, {:local_get, 0}, {:local_get, 1}, {:op, 0x6C}, {:local_tee, 2}, {:op, 0x6A}]}
  ]

  test "asm-native == forms-native == interpreter, bit-identical, across the supported i32 subset" do
    for {name, nlocals, instrs} <- @cases do
      m = build(nlocals, instrs)
      assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0), "#{name}: should emit via from_asm"

      for args <- @argsets do
        {interp, _} = Wasm.call_io(m, "f", args, transpile: false)
        {forms, _} = Wasm.call_io(m, "f", args, transpile: true, tier_threshold: 1, tier_async: false)
        asm = apply(am, af, args)
        assert interp == forms and forms == asm,
               "#{name} @ #{inspect(args)}: interp=#{inspect(interp)} forms=#{inspect(forms)} asm=#{inspect(asm)}"
      end
    end
  end

  @cmp_args [[5, 3], [3, 5], [5, 5], [0, 0], [0xFFFFFFFF, 1], [1, 0xFFFFFFFF], [0x80000000, 1], [0x7FFFFFFF, 0x80000000]]
  @cmps [
    {"eq", 0x46}, {"ne", 0x47}, {"lt_s", 0x48}, {"lt_u", 0x49}, {"gt_s", 0x4A},
    {"gt_u", 0x4B}, {"le_s", 0x4C}, {"le_u", 0x4D}, {"ge_s", 0x4E}, {"ge_u", 0x4F}
  ]

  test "value-producing comparisons (signed+unsigned) == interp == forms, incl. sign boundaries" do
    for {name, op} <- @cmps do
      m = build(0, [{:local_get, 0}, {:local_get, 1}, {:op, op}])
      assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0), "#{name} should emit"

      for args <- @cmp_args do
        {interp, _} = Wasm.call_io(m, "f", args, transpile: false)
        {forms, _} = Wasm.call_io(m, "f", args, transpile: true, tier_threshold: 1, tier_async: false)
        asm = apply(am, af, args)
        assert interp == forms and forms == asm,
               "#{name} @ #{inspect(args)}: interp=#{inspect(interp)} forms=#{inspect(forms)} asm=#{inspect(asm)}"
      end
    end
  end

  test "eqz == interp" do
    m = build(0, [{:local_get, 0}, {:op, 0x45}])
    {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0)
    for args <- [[0, 0], [1, 0], [0xFFFFFFFF, 0]] do
      {interp, _} = Wasm.call_io(m, "f", args, transpile: false)
      assert interp == apply(am, af, args)
    end
  end

  # ── sign-extension (§0): i32/i64.extend8_s/16_s/32_s, asm-native == interp ──
  defp i64_mod(instrs) do
    %Wasm{
      types: [{[126], [126]}], funcs: [0], code: [{0, instrs}],
      exports: %{"f" => 0}, mem: {1, nil}, globals: [], data: [], imports: [], elements: [],
      id: :crypto.hash(:sha256, :erlang.term_to_binary(instrs))
    }
  end

  test "i32.extend8_s/extend16_s asm-emitted (no fallback) == interp, incl sign boundaries" do
    for {name, op, args} <- [
          {"extend8_s", 0xC0, [[0x7F, 0], [0x80, 0], [0xFF, 0], [0x100, 0], [0x1FF, 0]]},
          {"extend16_s", 0xC1, [[0x7FFF, 0], [0x8000, 0], [0xFFFF, 0], [0x10000, 0]]}
        ] do
      m = build(0, [{:local_get, 0}, {:op, op}])
      assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0), "#{name}: asm must emit"

      for a <- args do
        {interp, _} = Wasm.call_io(m, "f", a, transpile: false)
        assert interp == apply(am, af, a), "#{name} @ #{inspect(a)}: interp=#{inspect(interp)}"
      end
    end
  end

  test "i64.extend8_s/16_s/32_s asm-emitted (no fallback) == interp" do
    for {name, op, args} <- [
          {"i64.extend8_s", 0xC2, [0x7F, 0x80, 0xFF, 0x100]},
          {"i64.extend16_s", 0xC3, [0x7FFF, 0x8000, 0xFFFF]},
          {"i64.extend32_s", 0xC4, [0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0x100000000]}
        ] do
      m = i64_mod([{:local_get, 0}, {:op, op}])
      assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0), "#{name}: asm must emit"

      for a <- args do
        {interp, _} = Wasm.call_io(m, "f", [a], transpile: false)
        assert interp == apply(am, af, [a]), "#{name} @ #{a}: interp=#{inspect(interp)}"
      end
    end
  end

  @cf_cases [
    {"loop: sum 1..n", 1,
     [
       {:i32_const, 0}, {:local_set, 2},
       {:loop, 0,
        [
          {:local_get, 2}, {:local_get, 0}, {:op, 0x6A}, {:local_set, 2},
          {:local_get, 0}, {:i32_const, 1}, {:op, 0x6B}, {:local_tee, 0}, {:br_if, 0}
        ]},
       {:local_get, 2}
     ], [[5, 0], [10, 0], [1, 0], [100, 0]]},
    {"if/else: c = a ? b : 99", 1,
     [
       {:local_get, 0},
       {:if, 0, [{:local_get, 1}, {:local_set, 2}], [{:i32_const, 99}, {:local_set, 2}]},
       {:local_get, 2}
     ], [[0, 7], [1, 7], [5, 3]]},
    {"block + br (early exit)", 1,
     [
       {:i32_const, 42}, {:local_set, 2},
       {:block, 0, [{:local_get, 0}, {:br_if, 0}, {:i32_const, 7}, {:local_set, 2}]},
       {:local_get, 2}
     ], [[0, 0], [1, 0], [9, 0]]}
  ]

  test "structured control flow (loop/if/block + br/br_if) == interp == forms, bit-identical" do
    for {name, nlocals, instrs, argsets} <- @cf_cases do
      m = build(nlocals, instrs)
      assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0), "#{name} should emit via from_asm"

      for args <- argsets do
        {interp, _} = Wasm.call_io(m, "f", args, fuel: 50_000_000, transpile: false)
        {forms, _} = Wasm.call_io(m, "f", args, fuel: 50_000_000, transpile: true, tier_threshold: 1, tier_async: false)
        asm = apply(am, af, args)
        assert interp == forms and forms == asm,
               "#{name} @ #{inspect(args)}: interp=#{inspect(interp)} forms=#{inspect(forms)} asm=#{inspect(asm)}"
      end
    end
  end

  test "an asm-native loop charges fuel and traps :out_of_fuel exactly like the interpreter" do
    instrs = [
      {:i32_const, 0}, {:local_set, 2},
      {:loop, 0,
       [
         {:local_get, 2}, {:local_get, 0}, {:op, 0x6A}, {:local_set, 2},
         {:local_get, 0}, {:i32_const, 1}, {:op, 0x6B}, {:local_tee, 0}, {:br_if, 0}
       ]},
      {:local_get, 2}
    ]
    m = build(1, instrs)
    {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0)

    set_fuel = fn n ->
      ref = :atomics.new(1, signed: true)
      :atomics.put(ref, 1, n)
      Process.put(:tl_last_fuel, {n, ref})
    end

    # a 1000-iteration loop with only 100 fuel must trap out_of_fuel (the asm lane reuses charge_fuel/0)
    set_fuel.(100)
    assert_raise TinyLasers.Wasm.Trap, fn -> apply(am, af, [1000, 0]) end

    # with ample fuel it completes; result matches the interpreter
    set_fuel.(100_000_000)
    {interp, _} = Wasm.call_io(m, "f", [1000, 0], fuel: 100_000_000, transpile: false)
    assert apply(am, af, [1000, 0]) == interp
  end

  test "an asm-native loop runs far faster than the interpreter (the runtime payoff)" do
    instrs = [
      {:i32_const, 0}, {:local_set, 2},
      {:loop, 0,
       [
         {:local_get, 2}, {:local_get, 0}, {:op, 0x6A}, {:local_set, 2},
         {:local_get, 0}, {:i32_const, 1}, {:op, 0x6B}, {:local_tee, 0}, {:br_if, 0}
       ]},
      {:local_get, 2}
    ]
    m = build(1, instrs)
    {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0)
    n = 1_000_000
    {t_interp, _} = :timer.tc(fn -> Wasm.call_io(m, "f", [n, 0], fuel: 100_000_000_000, transpile: false) end)
    {t_asm, asm} = :timer.tc(fn -> apply(am, af, [n, 0]) end)
    {interp, _} = Wasm.call_io(m, "f", [n, 0], fuel: 100_000_000_000, transpile: false)
    assert interp == asm
    assert t_asm * 5 < t_interp, "asm should be much faster: interp=#{div(t_interp, 1000)}ms asm=#{div(t_asm, 1000)}ms"
  end

  test "the asm lane wraps i32 arithmetic mod 2^32 exactly like the interpreter" do
    m = build(0, [{:local_get, 0}, {:local_get, 1}, {:op, 0x6A}])
    {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0)
    # 0xFFFFFFFF + 2 wraps to 1
    assert apply(am, af, [0xFFFFFFFF, 2]) == 1
    {interp, _} = Wasm.call_io(m, "f", [0xFFFFFFFF, 2], transpile: false)
    assert interp == 1
  end

  test "direct calls work end-to-end through the tiering path, bit-identical to interp" do
    # f(a,b) = g(a) + g(b); g(x) = x*2 + 1. f (func0) calls g (func1) via the call_local trampoline.
    m = %Wasm{
      types: [{[127, 127], [127]}, {[127], [127]}],
      funcs: [0, 1],
      code: [
        {0, [{:local_get, 0}, {:call, 1}, {:local_get, 1}, {:call, 1}, {:op, 0x6A}]},
        {0, [{:local_get, 0}, {:i32_const, 2}, {:op, 0x6C}, {:i32_const, 1}, {:op, 0x6A}]}
      ],
      exports: %{"f" => 0},
      mem: {1, nil},
      globals: [],
      data: [],
      imports: [],
      elements: [],
      id: :crypto.hash(:sha256, "asm-call")
    }

    for args <- [[5, 3], [0, 0], [100, 200]] do
      {interp, _} = Wasm.call_io(m, "f", args, transpile: false)
      {tiered, _} = Wasm.call_io(m, "f", args, transpile: true, tier_threshold: 1, tier_async: false)
      assert interp == tiered, "call @ #{inspect(args)}: interp=#{inspect(interp)} tiered=#{inspect(tiered)}"
    end
  end

  test "out-of-subset shapes return :unsupported (clean fallback, never wrong code)" do
    # call with too few args on the stack; a MULTI-value block (delta 2, not 0/1). All deferred.
    # (f32/f64 memory access is NOW supported in asm — see asm_memory_test; the float ops group lowers it.)
    assert :unsupported = TranspileAsm.try_emit(build(0, [{:local_get, 0}, {:call, 0}]), 0)
    assert :unsupported = TranspileAsm.try_emit(build(0, [{:block, [{:local_get, 0}, {:local_get, 1}]}]), 0)
    # a SIMD v128 op is not covered by any asm op-group yet → clean fallback (interp oracle covers it)
    assert :unsupported = TranspileAsm.try_emit(build(0, [{:v128_const, 0}]), 0)
  end

  test "the asm lane compiles a large function cheaply (skips the SSA pipeline)" do
    # asm skips the Erlang frontend + the superlinear beam_ssa_opt by construction, so even a 400-op
    # function compiles in single-digit ms. (The asm-vs-forms margin was proven in wb-9icg before asm
    # became Tier-1a; now Transpile.compile_one prefers asm, so a direct comparison is circular.)
    big = [{:local_get, 0} | Enum.flat_map(1..400, fn k -> [{:i32_const, k}, {:op, 0x6A}] end)]
    m = build(0, big)
    {t_asm, {:ok, _}} = :timer.tc(fn -> TranspileAsm.try_emit(m, 0) end)
    # generous ceiling — this asserts it's NOT superlinear (forms would hang); absolute time is noisy
    # under load, so we only guard the order of magnitude (sub-second), not single-digit ms.
    assert t_asm < 500_000, "asm compile should be cheap, got #{div(t_asm, 1000)}ms"
  end

  # wb-bv4e: a wasm `loop` lowers to a header label whose ONLY reference is the back-edge `{jump,{f,L}}`
  # *below* it (the `br 0` continue). When such a loop sits in the fall-through path after a terminal
  # (early `return` / `br` / `unreachable` trap) and behind an if-join `{jump}`, `beam_jump`'s forward
  # unreachable-scan deletes the header (its back-ref isn't seen yet) but keeps the body + the surviving
  # back-edge — a dangling `{f,L}` → `beam_clean` crash `{undefined_label,L}`. This bit beam-asm chunk
  # compiles for ~4 QuickJS functions (188/235/433/770). The fix: the asm lane compiles with `:no_jopt`
  # (TranspileAsm.compile_opts/0), bypassing `beam_jump` — identical run-time semantics, no crash.
  #
  # This is the delta-reduced real asm for QuickJS fn 188: `{label,19}` is the loop header, referenced
  # only by `{jump,{f,19}}` below it. It MUST crash the default `beam_jump` pipeline and compile clean
  # under the lane's options.
  test "a back-edge-only loop header after a terminal compiles under the asm lane's :no_jopt opts" do
    body = [
      {:label, 1},
      {:func_info, {:atom, :wb_bv4e_m}, {:atom, :f}, 2},
      {:label, 2},
      {:allocate, 20, 2},
      {:test, :is_eq_exact, {:f, 3}, [{:x, 0}, {:integer, 0}]},
      {:deallocate, 20},
      :return,
      {:label, 3},
      {:move, {:x, 0}, {:y, 10}},
      {:move, {:y, 10}, {:x, 0}},
      {:test, :is_eq_exact, {:f, 9}, [{:x, 0}, {:integer, 0}]},
      # loop header — back-ref only (see {:jump, {:f, 19}} below)
      {:label, 19},
      {:move, {:integer, 1}, {:x, 0}},
      {:jump, {:f, 23}},
      {:label, 23},
      {:move, {:x, 0}, {:y, 10}},
      {:move, {:y, 10}, {:x, 0}},
      {:test, :is_eq_exact, {:f, 9}, [{:x, 0}, {:integer, 0}]},
      {:jump, {:f, 19}},
      {:deallocate, 20},
      :return,
      {:label, 9},
      {:deallocate, 20},
      :return
    ]

    asm = {:wb_bv4e_m, [{:f, 2}], [], [{:function, :f, 2, 2, body}], 77}

    # Sanity: the SHAPE genuinely defeats the default (beam_jump-on) pipeline — else this test is vacuous.
    # :compile.forms returns the bare atom `error` (after printing an internal-error) on the dangling label.
    assert :error == :compile.forms(asm, [:from_asm, :binary, :return_errors]) |> capture_compile()

    # The fix: the asm lane's options (with :no_jopt) compile it cleanly.
    assert {:ok, :wb_bv4e_m, bin} = :compile.forms(asm, TranspileAsm.compile_opts())
    assert is_binary(bin)
  end

  # :compile.forms prints "Internal compiler error" to stderr on the undefined_label crash; swallow that
  # noise and normalise the bare `error` atom / {error,_} to :error for the assertion above.
  defp capture_compile(res) do
    case res do
      {:ok, _, _} -> :ok
      {:ok, _, _, _} -> :ok
      :error -> :error
      {:error, _, _} -> :error
      other -> other
    end
  end
end
