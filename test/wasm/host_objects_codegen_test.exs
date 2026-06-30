defmodule TinyLasers.HostObjectsCodegenTest do
  @moduledoc """
  **Stage 3: `--host-objects` codegen, oracle-gated against the default in-memory object lane.**

  Compiles the same JS with and without `--host-objects` and asserts identical results through `call_io`.
  Under the flag, plain static-key object literals become `ho_new` + `ho_set` host calls and static-key
  reads off a statically-object-typed receiver become `ho_get_value`/`ho_get_type` (keyed by the
  compile-time property hash) — no linear-memory pointer-chase or 20-branch type dispatch. The host object
  table (`TinyLasers.Js.HostObjects`) backs it.

  Scope note: the member fast path requires the receiver's type to be STATICALLY known as object (e.g. a
  direct object literal). `var o = {...}; o.x` does not yet propagate object type to `o`, so it falls back
  to the in-memory lane — correct, just not accelerated. Widening that (runtime type-tag branch in the
  member typeSwitch) is a later sub-stage.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Wasm
  alias TinyLasers.Js.{Porffor, HostObjects}

  defp run(src, host?) do
    flags = if host?, do: [flags: ["--host-objects"]], else: []
    {:ok, wasm} = Porffor.compile(src, "compilers", [skip_invariants: true] ++ flags)
    {:ok, mod} = Wasm.decode(wasm)
    HostObjects.reset()
    if host?, do: Process.put(:tl_imports, HostObjects.imports())

    try do
      {r, _} = Wasm.call_io(mod, "m", [], transpile: false, fuel: 500_000_000, max_pages: 16_384)
      {r, mod.imports}
    after
      Process.delete(:tl_imports)
      HostObjects.reset()
    end
  end

  @cases [
    {"single prop read", "function f(){ return ({x: 42}).x; } f();"},
    {"two prop sum", "function f(){ var o = ({a: 3, b: 4}); return ({a: 3, b: 4}).a + ({a: 3, b: 4}).b; } f();"},
    # numeric reductions only — a string result would leak its heap pointer (legitimately different
    # between the two data-section layouts), so we compare CONTENT-derived numbers, never raw pointers.
    {"string-valued prop type len", "function f(){ return (typeof ({s: 'hi'}).s).length; } f();"},
    {"string prop char", "function f(){ return ({s: 'hi'}).s.charCodeAt(0); } f();"},
    {"bool prop", "function f(){ return ({ok: true}).ok; } f();"},
    {"nested literal read", "function f(){ return ({p: ({q: 9}).q}).p; } f();"},
    # Stage 4: runtime tag branch — dynamically-typed receivers (loop var, param) + property write
    {"loop reuse", "function f(){ var s=0; var o={x:3}; for(var i=0;i<5;i++){ s+=o.x; } return s; } f();"},
    {"function param obj", "function g(o){ return o.x; } function f(){ return g({x:8}); } f();"},
    {"property write", "function f(){ var o={x:1}; o.x = 9; return o.x; } f();"},
    {"write then read loop", "function f(){ var o={n:0}; for(var i=0;i<4;i++){ o.n = o.n + i; } return o.n; } f();"},
    {"two distinct objs", "function f(){ var a={x:1}; var b={x:2}; b.x = 5; return a.x + b.x; } f();"},
    # Phase A: computed keys o[k] read + write (runtime __Porffor_object_hash)
    {"computed key read", "function f(){ var o={x:5}; var k='x'; return o[k]; } f();"},
    {"computed key write", "function f(){ var o={x:1}; var k='x'; o[k]=9; return o.x; } f();"},
    {"computed read after static write", "function f(){ var o={a:1}; o.a=4; var k='a'; return o[k]; } f();"},
    {"computed write static read", "function f(){ var o={a:0}; var k='a'; o[k]=7; return o.a; } f();"},
    {"computed key in loop", "function f(){ var o={n:0}; var k='n'; for(var i=0;i<3;i++){ o[k]=o[k]+2; } return o.n; } f();"},
    # Phase A: compound assignment (read-modify-write host-side via performOp)
    {"compound add", "function f(){ var o={x:1}; o.x += 5; return o.x; } f();"},
    {"compound mul loop", "function f(){ var o={x:1}; for(var i=0;i<5;i++){ o.x *= 2; } return o.x; } f();"},
    {"compound sub", "function f(){ var o={n:100}; o.n -= 30; return o.n; } f();"},
    {"compound computed", "function f(){ var o={x:2}; var k='x'; o[k] += 8; return o.x; } f();"},
    {"compound chained", "function f(){ var o={a:1,b:10}; o.a += o.b; o.b += o.a; return o.a*1000 + o.b; } f();"},
    # Phase C (hash-only, no enumeration): in / delete via ho_has / ho_delete
    {"in present", "function f(){ var o={x:1}; return ('x' in o) ? 1 : 0; } f();"},
    {"in absent", "function f(){ var o={x:1}; return ('y' in o) ? 1 : 0; } f();"},
    {"delete then in", "function f(){ var o={x:1,y:2}; delete o.x; return ('x' in o)?1:0; } f();"},
    {"delete return + read", "function f(){ var o={x:5}; var r = delete o.x; return (r?100:0) + (('x' in o)?1:0); } f();"},
    {"computed in", "function f(){ var o={ab:1}; var k='ab'; return (k in o)?1:0; } f();"},
    # Phase A completeness: optional chaining, numeric keys, deep nested writes
    {"optional chain", "function f(){ var o={x:5}; return o?.x; } f();"},
    {"optional computed", "function f(){ var o={x:5}; var k='x'; return o?.[k]; } f();"},
    {"numeric key", "function f(){ var o={}; o[2]=7; return o[2]; } f();"},
    {"deep nested write", "function f(){ var o={a:{b:{c:1}}}; o.a.b.c = 9; return o.a.b.c; } f();"},
    {"nested read 3deep", "function f(){ var o={a:{b:{c:42}}}; return o.a.b.c; } f();"},
    # Phase C enumeration: for-in via ho_count + ho_key_at (host-side key marshalling)
    {"for-in count", "function f(){ var o={a:1,b:2,c:3}; var n=0; for(var k in o){ n++; } return n; } f();"},
    {"for-in sum values", "function f(){ var o={a:10,b:20,c:30}; var s=0; for(var k in o){ s += o[k]; } return s; } f();"},
    {"for-in after write", "function f(){ var o={a:1}; o.b=2; o.c=3; var n=0; for(var k in o){ n++; } return n; } f();"},
    {"for-in key charcodes", "function f(){ var o={x:1,y:2}; var s=0; for(var k in o){ s += k.charCodeAt(0); } return s; } f();"},
    # Phase C hostMaterialize: enumeration builtins rebuild the host object into memory then run unchanged
    {"Object.keys length", "function f(){ var o={a:1,b:2,c:3}; return Object.keys(o).length; } f();"},
    {"Object.values sum", "function f(){ var o={a:10,b:20,c:30}; var v=Object.values(o); return v[0]+v[1]+v[2]; } f();"},
    {"Object.entries first val", "function f(){ var o={a:7,b:8}; var e=Object.entries(o); return e[0][1]; } f();"},
    {"Object.keys charcodes", "function f(){ var o={x:1,y:2}; var ks=Object.keys(o); return ks[0].charCodeAt(0)+ks[1].charCodeAt(0); } f();"},
    {"spread merge", "function f(){ var o={x:1,y:2}; var p={...o, z:3}; return p.x+p.y+p.z; } f();"},
    {"spread override", "function f(){ var o={x:1,y:2}; var p={...o, x:9}; return p.x*10+p.y; } f();"},
    {"JSON.stringify length", "function f(){ var o={x:1,y:2}; return JSON.stringify(o).length; } f();"},
    {"Object.values after write", "function f(){ var o={a:1}; o.b=2; o.c=3; var v=Object.values(o); return v[0]+v[1]+v[2]; } f();"},
    # Phase C prototype/reflection: instanceof, getPrototypeOf, hasOwnProperty, assign, create
    {"instanceof Object", "function f(){ var o={x:1}; return (o instanceof Object)?1:0; } f();"},
    {"getPrototypeOf is Object.prototype", "function f(){ var o={x:1}; return (Object.getPrototypeOf(o)===Object.prototype)?1:0; } f();"},
    {"hasOwnProperty present", "function f(){ var o={x:1,y:2}; return o.hasOwnProperty('x')?1:0; } f();"},
    {"hasOwnProperty absent", "function f(){ var o={x:1}; return o.hasOwnProperty('z')?1:0; } f();"},
    {"hasOwnProperty after write", "function f(){ var o={x:1}; o.y=2; return (o.hasOwnProperty('y')?1:0) + (o.hasOwnProperty('q')?1:0); } f();"},
    {"Object.assign into fresh", "function f(){ var o={a:1,b:2}; var t=Object.assign({}, o); return t.a+t.b; } f();"},
    {"Object.assign merge", "function f(){ var a={x:1}; var b={y:2}; var t=Object.assign({}, a, b); return t.x*10+t.y; } f();"},
    {"Object.create proto read", "function f(){ var p={greet:7}; var o=Object.create(p); return o.greet; } f();"},
    {"getOwnPropertyNames length", "function f(){ var o={a:1,b:2,c:3}; return Object.getOwnPropertyNames(o).length; } f();"},
    # Phase C reflection: Reflect.* on host objects
    {"Reflect.has present", "function f(){ var o={x:1}; return Reflect.has(o,'x')?1:0; } f();"},
    {"Reflect.has absent", "function f(){ var o={x:1}; return Reflect.has(o,'y')?1:0; } f();"},
    {"Reflect.get value", "function f(){ var o={x:42}; return Reflect.get(o,'x'); } f();"},
    {"Reflect.ownKeys length", "function f(){ var o={a:1,b:2,c:3}; return Reflect.ownKeys(o).length; } f();"},
    {"JSON roundtrip", "function f(){ var o={a:1,b:2}; var p=JSON.parse(JSON.stringify(o)); return p.a+p.b; } f();"},
    # JSON.stringify on NON-object args: the materialize wrap must not force object-typing (primitives must
    # keep their real runtime type via ANY-mode, else they serialize as "{}"). Compare string lengths.
    {"JSON.stringify number len", "function f(){ return JSON.stringify(3).length; } f();"},
    {"JSON.stringify array len", "function f(){ return JSON.stringify([1,2,3]).length; } f();"},
    {"JSON.stringify bool len", "function f(){ return JSON.stringify(true).length; } f();"},
    {"JSON.stringify string len", "function f(){ return JSON.stringify('hi').length; } f();"},
    {"JSON.stringify call-result", "function g(){ return 7; } function f(){ return JSON.stringify(g()).length; } f();"},
    # Phase A exotic: symbol keys + accessor getters/setters (accessor literals stay in-memory by design)
    {"symbol key roundtrip", "function f(){ var s=Symbol('k'); var o={}; o[s]=7; return o[s]; } f();"},
    {"symbol key in", "function f(){ var s=Symbol('k'); var o={}; o[s]=1; return (s in o)?1:0; } f();"},
    {"well-known toStringTag", "function f(){ var o={}; o[Symbol.toStringTag]='X'; return o[Symbol.toStringTag].length; } f();"},
    {"symbol not enumerated", "function f(){ var s=Symbol('h'); var o={a:1}; o[s]=2; var n=0; for(var k in o){n++;} return n; } f();"},
    {"accessor getter", "function f(){ var o={ get x(){ return 9; } }; return o.x; } f();"},
    {"accessor setter", "function f(){ var hit=0; var o={ set x(v){ hit=v; } }; o.x=5; return hit; } f();"},
    {"accessor get+set", "function f(){ var o={ _v:0, get x(){return this._v;}, set x(v){this._v=v;} }; o.x=11; return o.x; } f();"},
    # Phase F coherence: defineProperty descriptor literals are data-bag host-objectable, but the builtin reads
    # them in-memory — the descriptor arg is materialized first (else OOB / wrong read). Empty `{}` targets stay
    # in-memory (excluded) so defineProperty mutates them in place.
    {"defineProperty accessor descriptor", "function f(){ var o={}; var base=100; Object.defineProperty(o,'a',{get:function(){return base+1;},configurable:true}); return o.a; } f();"},
    {"defineProperty data descriptor", "function f(){ var o={}; Object.defineProperty(o,'x',{value:42,enumerable:true}); return o.x; } f();"}
    # NOTE deeper gap (deferred): Object.defineProperties with a descriptor-map whose VALUES are themselves
    # host objects needs DEEP materialize (shallow only rebuilds the outer map; nested descriptors stay host).
  ]

  for {name, src} <- @cases do
    test "host-objects oracle-matches default: #{name}" do
      {default, _} = run(unquote(src), false)
      {host, imports} = run(unquote(src), true)
      assert default == host
      # the flag actually engaged the host object lane (ho_* imports emitted)
      assert Enum.any?(imports, fn {_m, n, _t} -> String.starts_with?(n, "ho_") end),
             "expected ho_* imports under --host-objects, got #{inspect(imports)}"
    end
  end
end
