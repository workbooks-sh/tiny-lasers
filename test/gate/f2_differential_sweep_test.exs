defmodule TinyLasers.Gate.F2DifferentialSweepTest do
  @moduledoc """
  **F2 lane lockstep — the differential conformance sweep.**

  Every case runs through BOTH frontends — `Walk` (tree-walk interpreter) and `Lower` (ESTree→Elixir-quoted→
  native BEAM) — and their printed output must be identical. The case list is the construct matrix extracted
  from the rollup-bundle AST audit (123 node-type variants), plus every regression found while making the real
  rollup bundle run compiled: eager generators, microtask drain, typed-array oput contract, for-of pattern
  heads, try/finally rethrow, postfix value, fn-declaration hoisting order, do-while break tags, implicit
  derived ctors, accessor properties, `delete`, optional calls, `>>>`/`**`, and Elixir sibling-argument
  binding isolation (expression-order boxing).

  All Lower bodies compile into ONE module (one `Code.compile_quoted`), so the whole sweep costs a single
  compile — this is also the shape of the function-splitting compile-speed work.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Lower, Runtime, Walk}

  @cases [
    {"delete-member", ~S'var o = { a: 1, b: 2 }; delete o.a; print(("a" in o) + "," + ("b" in o));'},
    {"delete-computed", ~S'var o = { x: 1 }; var k = "x"; delete o[k]; print("x" in o);'},
    {"objlit-getter", ~S'var o = { get x() { return 7; }, y: 1 }; print(o.x + "," + o.y);'},
    {"objlit-getter-this", ~S'var o = { n: 5, get double() { return this.n * 2; } }; print(o.double);'},
    {"optional-call", ~S'var o = { f: function() { return 1; } }; var n = null; print(o.f?.() + "," + n?.f?.() + "," + o.g?.());'},
    {"optional-computed", ~S'var o = { m: function() { return 2; } }; var n = null; var k = "m"; print(o?.[k]() + "," + n?.[k]);'},
    {"optional-long-chain", ~S'var n = null; print(n?.b.c + "," + (n?.b.c === undefined));'},
    {"logical-assign-and", ~S'var calls = 0; function v() { calls++; return 9; } var a = 0; a &&= v(); var b = 1; b &&= v(); print(a + "," + b + "," + calls);'},
    {"logical-assign-or", ~S'var calls = 0; function v() { calls++; return 9; } var a = 0; a ||= v(); var b = 1; b ||= v(); print(a + "," + b + "," + calls);'},
    {"logical-assign-nullish", ~S'var calls = 0; function v() { calls++; return 9; } var a; a ??= v(); var b = 0; b ??= v(); print(a + "," + b + "," + calls);'},
    {"logical-assign-member", ~S'var o = { a: null }; o.a ??= 5; o.b ||= 6; print(o.a + "," + o.b);'},
    {"compound-bit-assigns", ~S'var a = 5; a &= 3; var b = 5; b |= 2; var c = 1; c <<= 3; var d = 16; d >>>= 2; print(a + "," + b + "," + c + "," + d);'},
    {"exponent-xor", ~S'print((2 ** 10) + "," + (5 ^ 3));'},
    {"in-operator", ~S'var o = { a: 1 }; var arr = [9]; print(("a" in o) + "," + ("z" in o) + "," + (0 in arr));'},
    {"sequence-expr", ~S'var i = 0; var x = (i++, i++, i + 10); print(x + "," + i);'},
    {"sequence-in-for", ~S'var s = ""; for (var i = 0, j = 10; i < 3; i++, j--) s += i + ":" + j + ";"; print(s);'},
    {"empty-statements", ~S';;;print("ok");;'},
    {"template-literal", ~S'var n = 3; var s = `a${n}b${n * 2}c`; print(s + "|" + `${`in${n}er`}`);'},
    {"computed-key-objlit", ~S'var k = "dyn"; var o = { [k]: 1, ["s" + k]: 2 }; print(o.dyn + "," + o.sdyn);'},
    {"object-spread", ~S'var a = { x: 1, y: 2 }; var b = { ...a, y: 9, z: 3 }; print(b.x + "," + b.y + "," + b.z);'},
    {"static-accessor", ~S'class C { static get version() { return "v1"; } } print(C.version);'},
    {"instanceof-chain", ~S'class A {} class B extends A {} var b = new B(); print((b instanceof B) + "," + (b instanceof A) + "," + ({} instanceof A));'},
    {"catch-param-destructure", ~S'try { throw { message: "m", code: 7 }; } catch ({ message, code }) { print(message + "," + code); }'},
    {"new-member-callee", ~S'var ns = { C: class { constructor(x) { this.x = x; } } }; print(new ns.C(4).x);'},
    {"for-infinite-break", ~S'var i = 0; for (;;) { i++; if (i === 3) break; } print(i);'},
    {"labeled-continue-outer", ~S'var s = ""; outer: for (var i = 0; i < 3; i++) { for (var j = 0; j < 3; j++) { if (j === 1) continue outer; s += i + "" + j; } } print(s);'},
    {"getter-defineprop-instance", ~S'var o = {}; Object.defineProperty(o, "x", { get: function() { return 42; } }); print(o.x);'},
    {"typeof-undeclared", ~S'print(typeof totallyUndeclaredVar);'},
    {"conditional-assign-branches", ~S'var a = 0, b = 0; var r = true ? (a = 1, "t") : (b = 2, "f"); print(r + "," + a + "," + b);'},
    {"string-concat-num-order", ~S'var i = 0; print("" + i++ + i++ + i);'},
    {"nested-arrow-this", ~S'var obj = { n: 1, m: function() { return [1].map(() => this.n)[0]; } }; print(obj.m());'},
    {"proto-method-shadow", ~S'function F() {} F.prototype.m = function() { return "proto"; }; var f = new F(); f.m = function() { return "own"; }; print(f.m());'},
    {"arr-holes-length", ~S'var a = new Array(3); a[1] = "x"; var s = ""; for (var i = 0; i < a.length; i++) s += (a[i] === undefined ? "_" : a[i]); print(s);'},
    {"regexp-lastindex-loop", ~S'var re = /a/g; var s = "aaa"; var n = 0; while (re.exec(s) !== null) n++; print(n);'},

    # try/finally semantics
    {"finally-rethrow", ~S'function f() { try { throw new Error("boom"); } finally { print("fin"); } } try { f(); print("no-throw"); } catch (e) { print("caught " + e.message); }'},
    {"handler-rethrow-finally", ~S'function f() { try { throw new Error("a"); } catch (e) { throw new Error("b:" + e.message); } finally { print("fin"); } } try { f(); } catch (e) { print("caught " + e.message); }'},
    {"return-through-finally", ~S'function f() { try { return "ret"; } finally { print("fin"); } } print("v=" + f());'},
    {"break-through-finally", ~S'var s = ""; for (var i = 0; i < 3; i++) { try { if (i === 1) break; s += i; } finally { s += "f"; } } print(s);'},
    {"async-watchdog-race", ~S'async function w(cb) { const never = new Promise((_, reject) => {}); try { return await Promise.race([cb(), never]); } finally { print("fin"); } } async function build() { throw new Error("build failed"); } w(() => build()).then(v => print("ok " + v)).catch(e => print("err " + e.message));'},
    {"catch-mutation-threading", ~S'function f() { var a = 0, b = 0, c = 0; try { a = 1; throw new Error("x"); } catch (e) { b = 2; } finally { c = 3; } return a + "," + b + "," + c; } print(f());'},

    # promises / async
    {"then-chain", ~S'Promise.resolve(1).then(v => v + 1).then(v => print("v=" + v)).catch(e => print("err"));'},
    {"deferred-resolve", ~S'var resolve; var p = new Promise(r => { resolve = r; }); p.then(v => print("v=" + v)); resolve(42);'},
    {"promise-all-map", ~S'async function g(x) { return x * 2; } Promise.all([1,2,3].map(x => g(x))).then(vs => print("v=" + vs.join(",")));'},
    {"async-class-method", ~S'class C { async m(x) { return (await Promise.resolve(x)) + 20; } } new C().m(1).then(v => print("v=" + v));'},
    {"try-in-async", ~S'async function f() { try { await Promise.reject(new Error("x")); } catch (e) { return "caught"; } } f().then(v => print("v=" + v));'},

    # generators (eager-collect model)
    {"gen-forof", ~S'function* g() { yield 1; yield 2; yield 3; } var t = 0; for (var v of g()) t += v; print("t=" + t);'},
    {"gen-yield-star", ~S'function* inner() { yield "a"; yield "b"; } function* outer() { yield* inner(); yield "c"; } var s = ""; for (var v of outer()) s += v; print("s=" + s);'},
    {"gen-early-return", ~S'function* g(n) { yield 1; if (n) return; yield 2; } var s = ""; for (var v of g(true)) s += v; for (var v2 of g(false)) s += v2; print("s=" + s);'},
    {"gen-spread", ~S'function* g() { yield 10; yield 20; } print("j=" + [...g()].join("|"));'},

    # update expressions
    {"postfix-prefix-values", ~S'var i = 5; var a = i++; var b = ++i; var c = i--; var d = --i; print(a + "," + b + "," + c + "," + d + "," + i);'},
    {"buffer-walk-postfix", ~S'var buf = [10, 20, 30, 40]; var pos = 0; var len = buf[pos++]; var x = buf[pos++]; print(len + "," + x + "," + pos);'},
    {"member-postfix", ~S'var o = { n: 7 }; var a = o.n++; var b = ++o.n; print(a + "," + b + "," + o.n);'},
    {"boxed-postfix", ~S'function counter() { var n = 0; return { take: function() { return n++; }, get: function() { return n; } }; } var c = counter(); print(c.take() + "," + c.take() + "," + c.get());'},
    {"this-member-postfix", ~S'function T() { this.pos = 0; } T.prototype.next = function(arr) { return arr[this.pos++]; }; var t = new T(); print(t.next([9, 8, 7]) + "," + t.next([9, 8, 7]) + "," + t.pos);'},

    # classes
    {"virtual-dispatch-in-ctor", ~S'class Base { constructor(x) { this.createScope(x); } createScope(x) { this.scope = "base:" + x; } } class Sub extends Base { createScope(x) { this.scope = "sub:" + x; } } print(new Sub(1).scope + "|" + new Base(2).scope);'},
    {"class-getter-setter", ~S'class C { get flag() { return this._f === 2; } set flag(v) { this._f = v ? 2 : 0; } constructor() { this._f = 0; } } var c = new C(); var a = c.flag; c.flag = true; print(a + "," + c.flag);'},
    {"extends-builtin-set", ~S'var EMPTY_SET = Object.freeze(new class extends Set { add() { throw new Error("no"); } }()); print("has=" + EMPTY_SET.has("x") + " sz=" + EMPTY_SET.size); try { EMPTY_SET.add("y"); } catch (e) { print("err=" + e.message); }'},
    {"extends-error", ~S'class MyError extends Error { constructor(msg) { super(msg); this.name = "MyError"; } } try { throw new MyError("boom"); } catch (e) { print(e.name + ":" + e.message); }'},
    {"extends-map-implicit-ctor", ~S'class M extends Map {} var m = new M(); m.set("a", 1); print("g=" + m.get("a") + " sz=" + m.size);'},

    # hoisting / forward refs
    {"fwd-fn-in-obj-table", ~S'var TABLE = { a: fwd, b: fwd2 }; function fwd(x) { return "f" + x; } function fwd2(x) { return "g" + x; } var format = "a"; print(TABLE[format](1) + "," + TABLE.b(2));'},
    {"fwd-in-iife", ~S'var mod = (function(exports) { var T = { cjs: other, es: esm }; function run(f) { return T[f]("u"); } function esm(u) { return "esm:" + u; } function other(u) { return "other:" + u; } exports.run = run; return exports; })({}); print(mod.run("cjs"));'},

    # do-while
    {"dowhile-break", ~S'var i = 0, s = ""; do { if (i === 2) break; s += i; i++; } while (i < 10); print(s + "|" + i);'},
    {"dowhile-continue", ~S'var i = 0, s = ""; do { i++; if (i % 2 === 0) continue; s += i; } while (i < 6); print(s + "|" + i);'},

    # for-of pattern heads
    {"forof-entries-pattern", ~S'var ems = [{ id: "a" }, { id: "b" }]; var s = ""; for (const [i, em] of ems.entries()) s += i + ":" + em.id + ";"; print("s=" + s);'},
    {"forof-objpattern", ~S'var xs = [{ alias: "x", modules: [1] }, { alias: "y", modules: [1, 2] }]; var s = ""; for (const { alias, modules } of xs) s += alias + modules.length; print(s);'},

    # typed arrays
    {"u8-loop-write", ~S'var t = new Uint8Array(4); for (var i = 0; i < 4; i++) t[i] = i + 1; print("len=" + t.length + " t=" + t[0] + "," + t[1] + "," + t[2] + "," + t[3]);'},

    # LIVE iteration + iterable constructors (rollup's chunk-graph closure: grow-while-iterate, Set-from-Set)
    {"live-set-grow", ~S'var seen = new Set(["a"]); var deps = { a: ["b", "c"], b: ["d"], c: [], d: [] }; var order = []; for (var m of seen) { order.push(m); for (var d of deps[m]) seen.add(d); } print(order.join(","));'},
    {"live-array-grow", ~S'var xs = [1]; var out = ""; for (var x of xs) { out += x; if (x < 4) xs.push(x + 1); } print(out);'},
    {"live-set-break", ~S'var s = new Set([1]); var n = 0; for (var v of s) { n++; if (v < 5) s.add(v + 1); if (v === 3) break; } print(n + "," + s.size);'},
    {"set-from-set", ~S'var a = new Set([1, 2, 2, 3]); var b = new Set(a); b.add(4); print(a.size + "," + b.size);'},
    {"map-from-map", ~S'var m = new Map([["k", 1]]); var m2 = new Map(m); m2.set("j", 2); print(m.size + "," + m2.size + "," + m2.get("k"));'},
    {"array-from-map-mapper", ~S'var m = new Map([["a", 1], ["b", 2]]); print(Array.from(m, function(kv) { return kv[0] + "=" + kv[1]; }).join(","));'},

    # named function expressions (self-recursion), class fields, and cross-scope var isolation (svelte's
    # minified compiler: recursive walkers, $state fields, and acorn's `for (var t = true)` loop-locals that
    # must NOT alias a same-named helper in another function).
    {"nfe-recursion", ~S'var f = function fact(n) { return n <= 1 ? 1 : n * fact(n - 1); }; print(f(5));'},
    {"nfe-iife", ~S'var r = (function rec(n) { return n.c ? n.v + rec(n.c) : n.v; })({ v: 1, c: { v: 2, c: { v: 3 } } }); print(r);'},
    {"class-fields", ~S'class C { has = false; count = 0; constructor(n) { this.count = n; } bump() { this.count += 1; return this.count; } } var c = new C(5); print(c.has + "," + c.bump());'},
    {"static-field", ~S'class C { static kind = "widget"; } print(C.kind);'},
    {"private-field", ~S'class C { #x = 7; get() { return this.#x; } set(v) { this.#x = v; } } var c = new C(); c.set(9); print(c.get());'},
    {"cross-scope-var-shadow", ~S'function a() { var pick = { g: function() { return t; } }; function t() { return "A"; } b(); return pick.g()(); } function b() { for (var t = true, s = ""; false; ) {} t = false; return t; } print(a());'},
    {"forvar-postloop-read", ~S'function rw() { for (var w = "", t = true, n = 0; n < 3; n++) { t = false; w += n; } return w + "|" + t; } print(rw());'},
    {"flatMap", ~S'print([1, 2, 3].flatMap(function(x) { return [x, x * 10]; }).join(","));'},
    {"startsWith-pos", ~S'var s = "        each"; print(s.startsWith("each", 8) + "," + s.startsWith("each", 0));'},
    {"matchAll", ~S'var out = []; for (var m of "a1b2c3".matchAll(/([a-z])(\d)/g)) out.push(m[1] + m[2]); print(out.join(","));'},
    {"div-by-zero", ~S'print((1 / 0) + "," + (-1 / 0) + "," + (0 / 0) + "," + (6 / 2));'}
  ]

  test "every construct case prints identically through Walk and Lower" do
    # ALL Lower bodies in one module: one Code.compile_quoted for the entire sweep.
    parsed = Enum.map(@cases, fn {label, src} -> {label, Js.parse(src)} end)

    defs =
      parsed
      |> Enum.with_index()
      |> Enum.map(fn {{_label, ast}, i} ->
        body = Lower.program(ast, %{"print" => 0})
        name = String.to_atom("case_#{i}")
        quote do
          def unquote(name)(), do: unquote(body)
        end
      end)

    mod = Module.concat([TinyLasers.Gate.Guest, "Sweep#{System.unique_integer([:positive])}"])
    [{m, _} | _] = Code.compile_quoted(quote do (defmodule unquote(mod) do unquote_splicing(defs) end) end)

    failures =
      parsed
      |> Enum.with_index()
      |> Enum.flat_map(fn {{label, ast}, i} ->
        Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}})
        w = try do Walk.run(ast, %{"print" => 0}); Runtime.__output() catch :throw, e -> ["THROW #{inspect(e, limit: 5)}"] ++ Runtime.__output() end
        Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}})
        l = try do apply(m, String.to_atom("case_#{i}"), []); Runtime.__output() catch :throw, e -> ["THROW #{inspect(e, limit: 5)}"] ++ Runtime.__output() end
        if w == l, do: [], else: ["#{label}: walk=#{inspect(w)} lower=#{inspect(l)}"]
      end)

    assert failures == [], "lane divergence:\n  " <> Enum.join(failures, "\n  ")
  end
end
