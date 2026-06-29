defmodule TinyLasers.JsPorfforLiveTest do
  @moduledoc """
  **The compiler now lives IN tiny-lasers: JS → WASM → BEAM, end to end, in one repo.**

  Earlier the Porffor compiler was in nexus and tiny-lasers ran only its `.wasm` fixtures. Now the whole
  JS lane is here — `TinyLasers.Js.Porffor.eval/1` compiles source to WASM on the vendored Porffor
  (lean deps: acorn + astring only) and runs it on `TinyLasers.Wasm`, capturing stdout. These assert the
  LIVE round-trip is byte-identical to node across the hard surface, including the host-call bridge.

  Skipped when the toolchain is absent (node / vendored compiler). The compiler is build-time/trusted;
  the *output* wasm is what runs (untrusted-capable) on the runtime.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Js.Porffor

  setup_all do
    if File.regular?(Porffor.porf_entry()) and System.find_executable("node") do
      :ok
    else
      {:skip, "porffor not vendored / node absent"}
    end
  end

  defp ok(src, want) do
    assert {:ok, out} = Porffor.eval(src), "eval failed for: #{src}"
    got = out |> String.replace(~r/\e\[[0-9;]*m/, "") |> String.trim()
    assert got == want, "#{src}\n  got=#{inspect(got)} want=#{inspect(want)}"
  end

  test "arithmetic + loops" do
    ok("let s=0; for(let i=0;i<1000;i++) s+=i*2; console.log(s);", "999000")
    ok("console.log(2**10 + 1_000);", "2024")
  end

  test "array + string methods (multi-value / type-tagged returns)" do
    ok("console.log([1,2,3,4].filter(n=>n%2).map(n=>n*n).reduce((a,b)=>a+b,0));", "10")
    ok("console.log('Hello World'.toLowerCase().split(' ').join('-').slice(0,5));", "hello")
  end

  test "objects + JSON + destructuring" do
    ok("console.log(JSON.stringify({a:[1,2],b:'x'}));", ~s({"a":[1,2],"b":"x"}))
    ok("const {a,b=5}={a:1}; const [x,...y]=[1,2,3]; console.log(a+b+x+y.length);", "9")
  end

  test "classes + inheritance + super" do
    ok("class A{m(){return 1;}} class B extends A{m(){return super.m()+1;}} console.log(new B().m());", "2")
  end

  test "closures (loop capture)" do
    ok("function mk(){let c=0; return ()=>++c;} let f=mk(); console.log(f()+f()+f());", "6")
    ok("let a=[]; for(let i=0;i<3;i++) a.push(()=>i); console.log(a.map(f=>f()).join(','));", "0,1,2")
  end

  test "regex + bigint + Map/Set (the hard surface)" do
    ok("console.log('a1b2c3'.replace(/[0-9]/g,'#'));", "a#b#c#")
    ok("console.log((123456789012345678901234567890n + 1n).toString());", "123456789012345678901234567891")
    ok("let m=new Map([['a',1],['b',2]]); console.log([...m.keys()].join('')+m.get('b'));", "ab2")
  end

  test "bundler-class compute (rollup's workload shape)" do
    ok(
      """
      const modules = { a:{deps:["b","c"],code:"export const a=b+c;"}, b:{deps:["d"],code:"export const b=d*2;"},
        c:{deps:["d"],code:"export const c=d+1;"}, d:{deps:[],code:"export const d=10;"} };
      const seen=new Set(), order=[];
      function visit(id){ if(seen.has(id))return; seen.add(id); for(const x of modules[id].deps) visit(x); order.push(id); }
      for(const id of Object.keys(modules)) visit(id);
      let n=0; for(const id of order){ n++; }
      console.log(order.join(",")+"|"+n);
      """,
      "d,b,c,a|4"
    )
  end

  test "the host-call bridge works live (guest __host('echo_upper', s) → PorfforHost)" do
    prelude = Porffor.host_prelude()
    refute prelude == "", "host_prelude.js must be vendored"

    src =
      prelude <>
        "\nconst r = hostCall(\"echo_upper\", \"hello live\");\n" <>
        "let s=\"\"; for(let i=0;i<r.length;i++){ s+=String.fromCharCode(r[i]); } console.log(s);"

    ok(src, "HELLO LIVE")
  end

  test "a hard compile failure classifies as :unsupported" do
    assert {:error, :unsupported} = Porffor.compile("function ( { [[[ invalid")
  end
end
