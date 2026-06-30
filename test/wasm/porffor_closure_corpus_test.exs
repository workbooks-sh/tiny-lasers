defmodule TinyLasers.JsPorfforClosureCorpusTest do
  @moduledoc """
  Small-scope closure-conversion corpus — hard-fail ASM ≡ node regression gate.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Js.{Debug, Porffor}

  @moduletag :porffor
  @moduletag :closure_corpus

  @corpus [
    {"this_in_nested_then",
     """
     class G { constructor(){ this.a=[1,2,3]; this.b=10; }
       async build(){ await Promise.resolve(0); var x=await Promise.resolve(5);
         return { n: this.a.length, t: this.b + x }; } }
     new G().build().then(r => console.log(r.n + ":" + r.t));
     """, "3:15"},
    {"typeof_box_is_function",
     """
     function mk(){ var c=5; return function(){ return c; }; }
     var f=mk();
     function check(h){ if(typeof h!=="function") return "no"; return "yes:"+h(); }
     console.log(check(f) + " " + check(123));
     """, "yes:5 no"},
    {"set_forof_through_arg",
     """
     function sum(s){ var t=0; for(const x of s) t+=x; return t; }
     var a=new Set([3,4]); console.log("" + sum(a));
     """, "7"},
    {"promise_catch_recovers",
     """
     Promise.reject("x").catch(e => "rec:"+e).then(v => console.log(v));
     """, "rec:x"},
    {"await_in_try_catch",
     """
     async function f(){ try { var x=await Promise.resolve(5); return "ok:"+x; } catch(e){ return "err:"+e; } }
     f().then(v => console.log(v));
     """, "ok:5"},
    {"destructure_assign_in_method",
     """
     class K { run(av){ ({a: this.x, b: this.y} = av); return this.x + "," + this.y; } }
     console.log(new K().run({a:3, b:4}));
     """, "3,4"},
    {"loop_body_const_fresh_per_iter",
     """
     function cache(obj, props){ for(const p of props){ const orig=Object.getOwnPropertyDescriptor(obj,p).get;
       Object.defineProperty(obj,p,{ get(){ const v=orig.call(obj); Object.defineProperty(obj,p,{value:v}); return v; } }); } }
     var info={}; var base=100;
     Object.defineProperty(info,"a",{get:()=>base+1,configurable:true});
     Object.defineProperty(info,"b",{get:()=>base+2,configurable:true});
     cache(info,["a","b"]); console.log(info.a + "," + info.b);
     """, "101,102"},
    {"nested_destructure_captured_in_closure",
     """
     class C { constructor(){ this.exportMode="E"; this.inputOptions={onLog:"L"}; this.outputOptions={format:"cjs"}; }
       render(){ const { exportMode, inputOptions: { onLog }, outputOptions } = this; const { format } = outputOptions;
         var f = function(){ return exportMode+":"+onLog+":"+format+":"+outputOptions.format; }; return f(); } }
     console.log(new C().render());
     """, "E:L:cjs:cjs"},
    {"call_thisarg_on_boxed_method",
     """
     function build(){ const outer="OUT"; const proto={};
       proto.greet=function(who){ return this.label+":"+who+"-"+outer; };
       const inst={label:"L"}; const fn=proto.greet; return fn.call(inst,"world"); }
     console.log(build());
     """, "L:world-OUT"},
    {"apply_thisarg_on_boxed_method",
     """
     function build(){ const outer="OUT"; const proto={};
       proto.greet=function(who){ return this.label+":"+who+"-"+outer; };
       const inst={label:"L"}; const fn=proto.greet; return fn.apply(inst,["world"]); }
     console.log(build());
     """, "L:world-OUT"}
  ]

  setup_all do
    if File.regular?(Porffor.porf_entry()) and System.find_executable("node"),
      do: :ok,
      else: {:skip, "porffor/node absent"}
  end

  defp run_asm(src) do
    case Debug.diagnose(src, transpile: true, fuel: 50_000_000) do
      {:ok, %{completed: true, output: out}} ->
        {:ok, out |> String.replace(~r/\e\[[0-9;]*m/, "") |> String.trim()}

      {:ok, r} ->
        {:error, r.error || r.trap || :incomplete}

      err ->
        err
    end
  end

  for {name, src, want} <- @corpus do
    @tag :closure_corpus
    test "closure corpus: #{name} (ASM ≡ node)" do
      assert {:ok, unquote(want)} == run_asm(unquote(src)),
             "#{unquote(name)}: ASM lane != node golden #{inspect(unquote(want))}"
    end
  end
end
