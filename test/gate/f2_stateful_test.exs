defmodule TinyLasers.Gate.F2StatefulTest do
  @moduledoc """
  **F2 Phase 3 — stateful `this` via mutable cells (marked's Lexer/Parser unlock).**

  Design that preserves H1: an object literal with a METHOD (function-valued property) is a stateful INSTANCE
  → a mutable `{:cell, id}` (few, long-lived, so the process-dict table is fine). A pure data bag stays an
  immutable `{keys, map}` (GC'd — the transient FLOOD the WASM hybrid OOMs on). Cells mutate IN PLACE, so
  `this.x = v`, shared-object aliasing, and `this.arr.push(x)` all work; data bags stay copy-on-write.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.Js

  test "this-mutation persists across method calls" do
    assert %{result: {:ok, 3.0}} = Js.run("var o = { n: 0, inc: function(){ this.n = this.n + 1; return this.n; } }; o.inc(); o.inc(); o.inc()")
    assert %{result: {:ok, 7.0}} = Js.run("var o = { pos: 0, adv: function(k){ this.pos = this.pos + k; } }; o.adv(3); o.adv(4); o.pos")
  end

  test "aliasing: two variables share one mutable instance" do
    assert %{result: {:ok, 99.0}} = Js.run("var a = { x: 1, set: function(v){ this.x = v; } }; var b = a; a.set(99); b.x")
  end

  test "a Lexer-like instance: this.arr.push + this.pos across calls" do
    src = """
    var lex = {
      s: 'abcabc', pos: 0, tokens: [],
      next: function(){ var c = this.s[this.pos]; this.pos = this.pos + 1; this.tokens.push(c); }
    };
    lex.next(); lex.next(); lex.next();
    lex.tokens.join('') + ':' + lex.pos
    """

    assert %{result: {:ok, "abc:3"}, binary: bin} = Js.run(src)
    assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin)
  end

  test "objects are REFERENCE types: aliasing shares mutation (correct JS semantics)" do
    # JS objects are references — `e = d` aliases, so `e.a = 5` is visible through `d`. (The earlier
    # immutable-data-bag model was abandoned for correctness; every object literal is now a mutable cell.)
    assert %{result: {:ok, 5.0}} = Js.run("var d = { a: 1 }; var e = d; e.a = 5; d.a")
  end
end
