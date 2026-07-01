defmodule TinyLasers.Gate.F2VerticalTest do
  @moduledoc """
  **F2 Phase 1 — the vertical: real parsed JS → native BEAM, GC'd, confined.**

  Ties the three de-risked hypotheses together on ONE path (`TinyLasers.Gate.Js`):
    * H3 — real acorn-parsed JS (functions, objects, members, arithmetic) runs BEAM-native.
    * H2 — the emitted guest binary references ONLY `TinyLasers.Gate.Runtime` (dangerous_refs empty).
    * H1 — objects are directly-held GC'd terms: a hard allocation loop stays flat where the WASM hybrid OOMs.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Runtime}

  test "real JS runs BEAM-native and computes correctly (H3)" do
    src = """
    function mk(x) { return { a: x, b: x + 1 }; }
    var o = mk(5);
    var p = { a: o.a, b: o.b, c: 9 };
    p.a + p.b + p.c
    """

    assert %{result: {:ok, 20.0}} = Js.run(src)
  end

  test "object spread + property mutation lower correctly" do
    src = """
    var o = { x: 1, y: 2 };
    var p = { x: o.x, y: o.y, z: 3 };
    p.x = 10;
    p.x + p.y + p.z
    """

    assert %{result: {:ok, 15.0}} = Js.run(src)
  end

  test "for/while loops thread mutable state (counter + accumulator + object rebuild)" do
    assert %{result: {:ok, 45.0}} = Js.run("var s = 0; for (var i = 0; i < 10; i = i + 1) { s = s + i; } s")
    assert %{result: {:ok, 10.0}} = Js.run("var s = 0; for (var i = 0; i < 5; i++) { s = s + i; } s")
    assert %{result: {:ok, 6.0}} = Js.run("var a = { n: 0 }; for (var i = 0; i < 4; i++) { a = { n: a.n + i }; } a.n")
    assert %{result: {:ok, 7.0}} = Js.run("var n = 1; var c = 0; while (n < 100) { n = n * 2; c = c + 1; } c")
  end

  test "arrays: literal, index, length, push-in-loop, map/join, string + object methods" do
    assert %{result: {:ok, 40.0}} = Js.run("var a = [10, 20, 30]; a[0] + a[2]")
    assert %{result: {:ok, 4.0}} = Js.run("var a = [1,2,3,4]; a.length")
    assert %{result: {:ok, 21.0}} = Js.run("var a = []; for (var i = 0; i < 5; i++) { a.push(i * i); } a[4] + a.length")
    assert %{result: {:ok, 30.0}} = Js.run("var a = [1,2,3]; var b = a.map(function(x){ return x * 10; }); b[2]")
    assert %{result: {:ok, "1-2-3"}} = Js.run("[1,2,3].join('-')")
    assert %{result: {:ok, "HELLO"}} = Js.run("'hello'.toUpperCase()")
    assert %{result: {:ok, 6.0}} = Js.run("var o = { v: 3, dbl: function(x){ return x * 2; } }; o.dbl(o.v)")
  end

  test "a non-trivial real program: recursive fib + recursive quicksort + objects, BEAM-native and confined" do
    prog = """
    function fib(n) { if (n < 2) { return n; } return fib(n - 1) + fib(n - 2); }
    function qsort(a) {
      if (a.length < 2) { return a; }
      var pivot = a[0]; var less = []; var more = [];
      for (var i = 1; i < a.length; i++) {
        if (a[i] < pivot) { less.push(a[i]); } else { more.push(a[i]); }
      }
      return qsort(less).concat([pivot]).concat(qsort(more));
    }
    var sorted = qsort([5, 3, 8, 1, 9, 2, 7]);
    var out = { fib10: fib(10), first: sorted[0], last: sorted[6], len: sorted.length };
    out.fib10 + out.first + out.last + out.len
    """

    %{result: res, binary: bin} = Js.run(prog)
    assert res == {:ok, 72.0}
    assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin)
  end

  test "try/catch/finally + throw + ternary + typeof" do
    assert %{result: {:ok, "caught:boom"}} = Js.run("var r; try { throw 'boom'; } catch (e) { r = 'caught:' + e; } r")
    assert %{result: {:ok, 11.0}} = Js.run("var r = 0; try { r = 1; } finally { r = r + 10; } r")
    assert %{result: {:ok, "big"}} = Js.run("var x = 5; x > 3 ? 'big' : 'small'")
    assert %{result: {:ok, "number"}} = Js.run("typeof 5")
    assert %{result: {:ok, "string"}} = Js.run("typeof 'x'")
    assert %{result: {:ok, "object"}} = Js.run("typeof {}")
    # a caught guest error (calling undefined) is catchable JS, still confined
    assert %{result: {:ok, "recovered"}, binary: bin} = Js.run("var r; try { nope(); } catch (e) { r = 'recovered'; } r")
    assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin)
  end

  test "this-binding in methods (read)" do
    assert %{result: {:ok, 7.0}} = Js.run("var o = { v: 7, get: function(){ return this.v; } }; o.get()")
    assert %{result: {:ok, 15.0}} = Js.run("var o = { n: 10, add: function(x){ return this.n + x; } }; o.add(5)")
    assert %{result: {:ok, 7.0}} = Js.run("var o = { a: 3, b: 4, sum: function(){ return this.a + this.b; } }; o.sum()")
  end

  test "the compiled guest references ONLY the Runtime — confinement holds (H2)" do
    src = """
    function merge(a, b) { return { x: a.x, y: b.y }; }
    merge({ x: 1 }, { y: 2 })
    """

    %{binary: bin, result: {:ok, result}} = Js.run(src)
    assert {["x", "y"], %{"x" => 1.0, "y" => 2.0}} = result

    # THE gate: no external module beyond Runtime, no dangerous BIFs. Escape is unexpressible.
    assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin)
  end

  test "an unknown identifier resolves to undefined — a host module can never be named (H2)" do
    # `os` / `File` / `Process` are not locals and not granted → :undefined; calling one is a guest error,
    # and the dangerous-ref check confirms none appears in the bytecode.
    src = "os.cmd('rm -rf /')"
    %{result: res, binary: bin} = Js.run(src)
    assert match?({:guest_error, _}, res)
    assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin)
  end

  test "allocation-heavy real-JS workload stays FLAT — the memory wall is gone (H1)" do
    # a guest merge fn (the marked Object.assign hot pattern), driven 1,000,000x; each result unreachable → GC.
    %{result: {:ok, mergefn}} = Js.run("function merge(a, b) { return { x: a.x, y: a.y, z: b.z }; } merge")

    Runtime.__init(%{caps: %{}})
    :erlang.garbage_collect()
    before = :erlang.memory(:total) |> div(1024 * 1024)

    last =
      Enum.reduce(1..1_000_000, nil, fn i, _ ->
        a = Runtime.oput(Runtime.oput(Runtime.olit(), "x", i * 1.0), "y", 2.0)
        b = Runtime.oput(Runtime.olit(), "z", 3.0)
        Runtime.call(mergefn, [a, b])
      end)

    :erlang.garbage_collect()
    delta = (:erlang.memory(:total) |> div(1024 * 1024)) - before

    assert {["x", "y", "z"], %{"z" => 3.0}} = last
    assert delta < 50, "guest allocation loop should stay flat; grew #{delta} MB"
  end
end
