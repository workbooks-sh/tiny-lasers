defmodule TinyLasers.WasmAsmIntExtTest do
  @moduledoc """
  **IntExt op-group (`TinyLasers.Wasm.AsmOps.IntExt`) for the BEAM-assembly lane.** A/Bs globals, select,
  i32 shifts/rotates, div/rem (incl. traps), and clz/ctz/popcnt through the interpreter, the forms-native
  lane, and the asm-native lane — all three must agree bit-for-bit, including identical traps.
  """
  use ExUnit.Case, async: true

  alias TinyLasers.Wasm
  alias TinyLasers.Wasm.TranspileAsm

  # ── module builders ──────────────────────────────────────────────────────────────────────────────
  defp build(nlocals, instrs, opts \\ []) do
    %Wasm{
      types: [{[127, 127], [127]}],
      funcs: [0],
      code: [{nlocals, instrs}],
      exports: %{"f" => 0},
      mem: {1, nil},
      globals: Keyword.get(opts, :globals, []),
      data: [],
      imports: [],
      elements: [],
      id: :crypto.hash(:sha256, :erlang.term_to_binary({nlocals, instrs, opts}))
    }
  end

  # assert interp == forms == asm for every argset (value-returning, no trap)
  defp agree!(name, m, argsets) do
    assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0), "#{name}: should emit via from_asm"

    for args <- argsets do
      {interp, _} = Wasm.call_io(m, "f", args, transpile: false)
      {forms, _} = Wasm.call_io(m, "f", args, transpile: true, tier_threshold: 1, tier_async: false)
      asm = apply(am, af, args)

      assert interp == forms and forms == asm,
             "#{name} @ #{inspect(args)}: interp=#{inspect(interp)} forms=#{inspect(forms)} asm=#{inspect(asm)}"
    end
  end

  @edge [0, 1, 2, 31, 32, 33, 7, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 0x12345678]
  defp argsets, do: for(a <- @edge, b <- @edge, do: [a, b])

  # ── shifts / rotates ──────────────────────────────────────────────────────────────────────────────
  for {name, op} <- [{"shl", 0x74}, {"shr_s", 0x75}, {"shr_u", 0x76}, {"rotl", 0x77}, {"rotr", 0x78}] do
    test "i32 #{name} == interp == forms (incl shift 0/31/32/>32)" do
      m = build(0, [{:local_get, 0}, {:local_get, 1}, {:op, unquote(op)}])
      agree!(unquote(name), m, argsets())
    end
  end

  # ── bitcount ──────────────────────────────────────────────────────────────────────────────────────
  for {name, op} <- [{"clz", 0x67}, {"ctz", 0x68}, {"popcnt", 0x69}] do
    test "i32 #{name} == interp == forms (incl 0 and 0xFFFFFFFF)" do
      m = build(0, [{:local_get, 0}, {:op, unquote(op)}])
      args = for a <- [0, 0xFFFFFFFF, 1, 0x80000000, 0x7FFFFFFF, 0x10000, 0x12345678], do: [a, 0]
      agree!(unquote(name), m, args)
    end
  end

  # ── select (both branches) ─────────────────────────────────────────────────────────────────────────
  # NOTE: the abstract-FORMS lane has a PRE-EXISTING select bug (it returns `b` for the c≠0 branch — e.g.
  # interp=22 but forms=11 for [a=11,b=22,c=0]). Out of scope for this op-group. The asm-lane CONTRACT is
  # bit-identical to the INTERPRETER, so this asserts asm == interp (the ground truth) directly.
  test "select (0x1B) picks a when c≠0 else b, == interpreter (asm-lane contract)" do
    for c <- [0, 1, 7, 0xFFFFFFFF] do
      # push a (local0), b (local1), c (const) ; select
      m = build(0, [{:local_get, 0}, {:local_get, 1}, {:i32_const, c}, {:op, 0x1B}])
      {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0)

      for args <- [[11, 22], [0, 99], [0xFFFFFFFF, 5]] do
        {interp, _} = Wasm.call_io(m, "f", args, transpile: false)
        assert interp == apply(am, af, args), "select c=#{c} @ #{inspect(args)}: interp=#{interp} asm=#{apply(am, af, args)}"
      end
    end
  end

  # ── div / rem (non-trapping values) ────────────────────────────────────────────────────────────────
  for {name, op} <- [{"div_s", 0x6D}, {"div_u", 0x6E}, {"rem_s", 0x6F}, {"rem_u", 0x70}] do
    test "i32 #{name} == interp == forms (signed boundaries, no trap)" do
      m = build(0, [{:local_get, 0}, {:local_get, 1}, {:op, unquote(op)}])
      vals = [1, 2, 7, 100, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 0xFFFFFFFE, 3]
      # exclude pairs that trap (b==0 div-by-zero; INT32_MIN / -1 div_s overflow) — covered by trap tests.
      args = for a <- vals, b <- vals, b != 0, not (a == 0x80000000 and b == 0xFFFFFFFF), do: [a, b]
      agree!(unquote(name), m, args)
    end
  end

  # ── traps: divide-by-zero (all four) + INT32_MIN / -1 overflow (div_s) ──────────────────────────────
  defp traps?(m, args) do
    fn lane_opts ->
      try do
        Wasm.call_io(m, "f", args, lane_opts)
        false
      rescue
        TinyLasers.Wasm.Trap -> true
      end
    end
  end

  for {name, op} <- [{"div_s", 0x6D}, {"div_u", 0x6E}, {"rem_s", 0x6F}, {"rem_u", 0x70}] do
    test "i32 #{name} divide-by-zero traps on BOTH lanes" do
      m = build(0, [{:local_get, 0}, {:local_get, 1}, {:op, unquote(op)}])
      t = traps?(m, [5, 0])
      assert t.(transpile: false), "#{unquote(name)}/0: interp must trap"
      assert t.(transpile: true, tier_threshold: 1, tier_async: false), "#{unquote(name)}/0: transpiled must trap"
      # asm lane directly
      {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0)
      assert_raise TinyLasers.Wasm.Trap, fn -> apply(am, af, [5, 0]) end
    end
  end

  test "i32 div_s INT32_MIN / -1 overflow traps on BOTH lanes; rem_s does NOT" do
    mdiv = build(0, [{:local_get, 0}, {:local_get, 1}, {:op, 0x6D}])
    args = [0x80000000, 0xFFFFFFFF]
    t = traps?(mdiv, args)
    assert t.(transpile: false)
    assert t.(transpile: true, tier_threshold: 1, tier_async: false)
    {:ok, {am, af, _}} = TranspileAsm.try_emit(mdiv, 0)
    assert_raise TinyLasers.Wasm.Trap, fn -> apply(am, af, args) end

    # rem_s of INT32_MIN / -1 = 0, no trap — agree across lanes
    mrem = build(0, [{:local_get, 0}, {:local_get, 1}, {:op, 0x6F}])
    agree!("rem_s INT_MIN/-1", mrem, [args])
  end

  # ── globals round-trip ─────────────────────────────────────────────────────────────────────────────
  # The asm function reads `:washy_globals` from the process dict (the seam `call_io` installs for the
  # interp/forms lanes). The bare `apply` path here installs a fresh globals array per call so the asm
  # lane has the same ground-truth context, then asserts asm == interp == forms.
  defp agree_globals!(name, m, argsets) do
    assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0), "#{name}: should emit"

    for args <- argsets do
      {interp, _} = Wasm.call_io(m, "f", args, transpile: false)
      {forms, _} = Wasm.call_io(m, "f", args, transpile: true, tier_threshold: 1, tier_async: false)
      prev = Process.put(:washy_globals, Wasm.init_globals(m))
      asm = apply(am, af, args)
      if prev, do: Process.put(:washy_globals, prev), else: Process.delete(:washy_globals)

      assert interp == forms and forms == asm,
             "#{name} @ #{inspect(args)}: interp=#{inspect(interp)} forms=#{inspect(forms)} asm=#{inspect(asm)}"
    end
  end

  test "global.get / global.set round-trip == interp == forms (set masks 32 bits)" do
    # f(a,_) : global0 = a ; return global0  (init global0 = 42)
    m = build(0, [{:local_get, 0}, {:global_set, 0}, {:global_get, 0}], globals: [[{:i32_const, 42}]])
    agree_globals!("global rt", m, [[0, 0], [7, 0], [0xFFFFFFFF, 0], [0x80000000, 0], [0x12345678, 0]])
  end

  test "global.get reads the init value == interp == forms" do
    m = build(0, [{:global_get, 0}], globals: [[{:i32_const, 123}]])
    agree_globals!("global init", m, [[0, 0], [9, 9]])
  end
end
