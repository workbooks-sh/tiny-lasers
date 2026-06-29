defmodule TinyLasers.GateEvalRedteamTest do
  @moduledoc """
  Red-team for `eval` — the scariest confinement hole. Thesis: `eval` is not a hole
  if the only way to run code is through our gate, and the gate always confines.

  Here `eval` runs guest source through the CONFINED INTERPRETER (`Interp`), not the
  compiler — so (a) eval'd code is confined identically to compiled code, and (b) no
  atoms are minted per eval, closing the eval-driven atom-exhaustion DoS that
  compile-per-eval would open.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate

  defp lit(v), do: {:lit, v}
  defp var(n), do: {:var, n}
  defp call(c, args), do: {:call, c, args}

  # eval'd source that simply computes works
  test "eval of a pure expression runs" do
    ast = call(var("eval"), [lit("1 + 2 * 3")])
    c = Gate.compile(ast, ["eval"])
    out = Gate.run(c)
    assert out.result == {:ok, 7.0}
  end

  # THE hole: eval'd source cannot reach a host module
  test "eval cannot reach :os — eval'd code is confined identically to compiled code" do
    ast = call(var("eval"), [lit("os.cmd('echo pwned')")])
    c = Gate.compile(ast, ["eval"])
    out = Gate.run(c)

    assert out.result == {:guest_error, "not a function"}
    assert out.output == []
    # the compiled guest still references only the confined Runtime; eval added no escape
    assert Gate.dangerous_refs(c) == %{ext: [], bifs: []}
  end

  # eval inherits exactly the parent's grant — it can use a granted cap...
  test "eval'd code can use a capability the parent was granted" do
    ast = call(var("eval"), [lit("print(42)")])
    c = Gate.compile(ast, ["eval", "print"])
    out = Gate.run(c)
    assert out.output == ["42"]
  end

  # ...but eval CANNOT widen privilege to an ungranted capability
  test "eval cannot reach a capability the parent was not granted" do
    # parent granted eval (and print) but NOT fs_write
    ast = call(var("eval"), [lit("fs_write('/work/x.txt', 'pwn')")])
    c = Gate.compile(ast, ["eval", "print"])
    out = Gate.run(c, tenant_root: "/work")

    assert out.result == {:guest_error, "not a function"}
    assert out.fs_writes == []
  end

  # eval resolves granted caps to opaque handles, consistently with the compiler
  test "eval resolves a granted capability to an opaque handle, not a raw fun" do
    ast = call(var("eval"), [lit("print")])
    c = Gate.compile(ast, ["eval", "print"])
    out = Gate.run(c)
    # "print" is granted at cap id 1 (eval=0, print=1)
    assert out.result == {:ok, {:host, 1}}
  end

  # malformed eval source is a guest error, never a host crash
  test "malformed eval source is a contained guest error" do
    ast = call(var("eval"), [lit("os.cmd(")])
    c = Gate.compile(ast, ["eval"])
    out = Gate.run(c)
    assert out.result == {:guest_error, "eval parse error"}
  end

  # THE DoS the design avoids: running many distinct evals must NOT mint an atom per eval.
  # Compiling each eval (Code.compile_quoted) would intern a fresh module atom per source — 250
  # evals → ≥250 permanent atoms, an unbounded node-wide vector. Interpreting avoids it entirely.
  #
  # We assert the SHAPE of that vector rather than a global atom_count == 0: the count is a VM-wide
  # property the WASM transpile lane perturbs from concurrent (async) tests, so == 0 is inherently
  # flaky. The DoS is LINEAR in the eval count; ambient host-side churn is a small constant. Bounding
  # growth strictly below the eval count proves evals don't each mint an atom, robust to that churn.
  test "many distinct evals don't mint an atom per eval (eval atom-exhaustion DoS closed)" do
    evals = for i <- 0..249, do: call(var("eval"), [lit("#{i} + 1")])
    ast = {:seq, evals}

    c = Gate.compile(ast, ["eval"])

    before = :erlang.system_info(:atom_count)
    out = Gate.run(c)
    later = :erlang.system_info(:atom_count)

    assert out.result == {:ok, 250.0}

    # ≥1 atom/eval would add ≥250; the interpreter adds none of its own, so any growth here is
    # ambient (concurrent transpile-lane module names), which is « the eval count.
    assert later - before < length(evals),
           "eval minted #{later - before} atoms over #{length(evals)} evals — looks per-eval, not ambient"
  end
end
