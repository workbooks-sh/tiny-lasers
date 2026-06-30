defmodule TinyLasers.Js.Census do
  @moduledoc """
  **Porffor conformance census** — cheap feature-probe matrix vs node oracle.

  For each probe: compile + run on TinyLasers.Wasm → `got`; run same source on node → `want`; classify.
  `report/0` prints ranked summary. `compare_baseline/1` diffs against
  [`test/conformance/census_baseline.work`](../../../test/conformance/census_baseline.work).
  """

  alias TinyLasers.Js.Porffor

  @baseline_file "test/conformance/census_baseline.work"

  @corpus [
    {:arith, "pow_sep", "console.log(2**10 + 1_000);"},
    {:arith, "float", "console.log((3.5 * 2 + 1) / 2);"},
    {:control, "for_loop", "let s=0; for(let i=0;i<100;i++) s+=i; console.log(s);"},
    {:control, "while", "let i=0,s=0; while(i<10){s+=i;i++;} console.log(s);"},
    {:control, "switch_label", "let r=0; o: for(let i=0;i<3;i++){switch(i){case 1:r+=10;break;default:r+=1;}} console.log(r);"},
    {:control, "ternary_chain", "const f=n=>n<0?'neg':n===0?'zero':'pos'; console.log(f(-1)+f(0)+f(1));"},
    {:closure, "counter", "function c(){let n=0; return ()=>++n;} const f=c(); f(); console.log(f());"},
    {:closure, "curry", "const add=a=>b=>a+b; console.log(add(3)(4));"},
    {:closure, "map_capture", "const k=10; console.log([1,2,3].map(x=>x*k).join(','));"},
    {:closure, "higher_order", "const compose=(f,g)=>x=>f(g(x)); console.log(compose(a=>a+1,a=>a*2)(5));"},
    {:closure, "closure_loop", "const fns=[]; for(let i=0;i<3;i++) fns.push(()=>i); console.log(fns.map(f=>f()).join(','));"},
    {:closure, "iife", "const x=(function(){let p=5; return p*2;})(); console.log(x);"},
    {:func, "default_param", "function f(a,b=10){return a+b;} console.log(f(5));"},
    {:func, "rest_param", "function f(...xs){return xs.reduce((a,b)=>a+b,0);} console.log(f(1,2,3,4));"},
    {:func, "spread_call", "const a=[1,2,3]; console.log(Math.max(...a));"},
    {:array, "filter_map_reduce", "console.log([1,2,3,4].filter(n=>n%2).map(n=>n*n).reduce((a,b)=>a+b,0));"},
    {:array, "sort", "console.log([3,1,2].sort().join(','));"},
    {:array, "sort_cmp", "console.log([3,1,2].sort((a,b)=>b-a).join(','));"},
    {:array, "includes", "console.log([1,2,3].includes(2));"},
    {:array, "find", "console.log([1,2,3,4].find(n=>n>2));"},
    {:array, "from", "console.log(Array.from({length:3},(_, i)=>i).join(''));"},
    {:array, "flat", "console.log([[1],[2,3]].flat().join(','));"},
    {:array, "indexOf", "console.log(['a','b','c'].indexOf('b'));"},
    {:array, "slice_concat", "console.log([1,2,3,4].slice(1,3).concat([9]).join(','));"},
    {:string, "case_split_join", "console.log('Hello World'.toLowerCase().split(' ').join('-'));"},
    {:string, "slice_pad", "console.log('abc'.slice(1).padStart(4,'*'));"},
    {:string, "replace_str", "console.log('a-b-c'.replace('-','+'));"},
    {:string, "includes_starts", "console.log('hello'.includes('ell') && 'hello'.startsWith('he'));"},
    {:string, "repeat", "console.log('ab'.repeat(3));"},
    {:string, "char_codes", "console.log('A'.charCodeAt(0) + String.fromCharCode(66));"},
    {:string, "trim", "console.log('  hi  '.trim() + '!');"},
    {:template, "interp", "const n=42; console.log(`v=${n} sq=${n*n}`);"},
    {:object, "keys_values", "const o={a:1,b:2}; console.log(Object.keys(o).join(',')+Object.values(o).join(','));"},
    {:object, "entries", "const o={a:1,b:2}; console.log(Object.entries(o).map(([k,v])=>k+v).join(','));"},
    {:object, "spread", "const o={...{x:1},y:2}; console.log(o.x+o.y);"},
    {:object, "destructure", "const {a,b=5}={a:1}; console.log(a+b);"},
    {:object, "computed_key", "const k='x'; const o={[k]:7}; console.log(o.x);"},
    {:object, "optional_chain", "const o={a:{b:null}}; console.log((o?.a?.b?.c ?? 'none'));"},
    {:class, "basic", "class A{constructor(v){this.v=v;} get(){return this.v*2;}} console.log(new A(21).get());"},
    {:class, "inherit_super", "class A{m(){return 1;}} class B extends A{m(){return super.m()+1;}} console.log(new B().m());"},
    {:class, "static", "class A{static s(){return 7;}} console.log(A.s());"},
    {:class, "getter", "class A{get x(){return 42;}} console.log(new A().x);"},
    {:json, "stringify", "console.log(JSON.stringify({a:[1,2],b:'x'}));"},
    {:json, "parse", "console.log(JSON.parse('{\"a\":5,\"b\":[1,2]}').b[1]);"},
    {:collection, "map", "const m=new Map([['a',1]]); m.set('b',2); console.log(m.get('a')+m.size);"},
    {:collection, "set", "const s=new Set([1,2,2,3]); console.log(s.size);"},
    {:number, "toFixed", "console.log((3.14159).toFixed(2));"},
    {:number, "parseInt", "console.log(parseInt('42px') + parseFloat('3.5x'));"},
    {:number, "math", "console.log(Math.max(1,5,3) + Math.floor(3.7) + Math.abs(-2));"},
    {:regex, "match", "console.log(('foo123bar'.match(/\\d+/)||['?'])[0]);"},
    {:regex, "replace", "console.log('a1b2c3'.replace(/[0-9]/g,'#'));"},
    {:regex, "test", "console.log(/^[a-z]+$/.test('hello'));"},
    {:generator, "yield", "function* g(){yield 1; yield 2; yield 3;} console.log([...g()].join(','));"},
    {:generator, "yield_delegate", "function* g(){yield 1; yield* [2,3];} console.log([...g()].join(','));"},
    {:async, "basic", "async function f(){return 42;} f().then(v=>console.log(v));"},
    {:async, "await", "async function f(){const x=await Promise.resolve(10); return x*2;} f().then(v=>console.log(v));"},
    {:error, "try_catch", "try{throw new Error('x');}catch(e){console.log('caught '+e.message);}"}
  ]

  @doc false
  def corpus, do: @corpus

  @doc "Run census; returns `[{category, name, status, got, want}]`."
  def run do
    Enum.map(@corpus, fn {cat, name, js} ->
      {status, got, want} = classify(js)
      {cat, name, status, got, want}
    end)
  end

  defp classify(js) do
    case node_oracle(js) do
      :error -> {:oracle_skip, nil, nil}
      {:ok, want} ->
        case Porffor.eval(js) do
          {:ok, got} -> {if(strip(got) == want, do: :pass, else: :miscompile), strip(got), want}
          _ -> {:crash, nil, want}
        end
    end
  end

  defp node_oracle(js) do
    case System.cmd("node", ["-e", js], stderr_to_stdout: true) do
      {out, 0} -> {:ok, strip(out)}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp strip(s), do: s |> String.replace(~r/\e\[[0-9;]*m/, "") |> String.trim()

  @doc "Read baseline pass/total from census_baseline.work."
  def baseline do
    path = Path.join(File.cwd!(), @baseline_file)

    if File.regular?(path) do
      text = File.read!(path)

      pass =
        case Regex.run(~r/pass:\s*(\d+)/, text) do
          [_, n] -> String.to_integer(n)
          _ -> nil
        end

      total =
        case Regex.run(~r/total:\s*(\d+)/, text) do
          [_, n] -> String.to_integer(n)
          _ -> nil
        end

      asm_pct =
        case Regex.run(~r/asm_native_pct:\s*([\d.]+)/, text) do
          [_, n] -> String.to_float(n)
          _ -> nil
        end

      %{pass: pass, total: total, asm_native_pct: asm_pct}
    else
      %{pass: nil, total: nil, asm_native_pct: nil}
    end
  end

  @doc "Compare current run to baseline; returns `%{pass, total, pass_pct, delta_pass, baseline}`."
  def compare_baseline(results \\ run()) do
    pass = Enum.count(results, fn {_, _, s, _, _} -> s == :pass end)
    total = Enum.count(results, fn {_, _, s, _, _} -> s != :oracle_skip end)
    base = baseline()
    delta = if base.pass, do: pass - base.pass, else: nil
    %{pass: pass, total: total, pass_pct: if(total > 0, do: Float.round(pass * 100 / total, 1), else: 0.0), delta_pass: delta, baseline: base}
  end

  @doc "Print ranked report; returns raw results."
  def report(opts \\ []) do
    results = run()
    by_cat = Enum.group_by(results, fn {cat, _, _, _, _} -> cat end)

    rows =
      Enum.map(by_cat, fn {cat, rs} ->
        pass = Enum.count(rs, fn {_, _, s, _, _} -> s == :pass end)
        total = Enum.count(rs, fn {_, _, s, _, _} -> s != :oracle_skip end)
        {cat, pass, total, rs}
      end)
      |> Enum.sort_by(fn {_cat, pass, total, _} -> if total == 0, do: 1.0, else: pass / total end)

    IO.puts("\n══ PORFFOR CONFORMANCE CENSUS (tiny-lasers) ══\n")

    for {cat, pass, total, rs} <- rows do
      pct = if total == 0, do: "—", else: "#{round(pass * 100 / total)}%"
      IO.puts("#{String.pad_trailing("#{cat}", 12)} #{pass}/#{total} (#{pct})")

      for {_, name, status, got, want} <- rs, status in [:miscompile, :crash] do
        detail = if status == :crash, do: "CRASH (want=#{inspect(want)})", else: "got=#{inspect(got)} want=#{inspect(want)}"
        IO.puts("    #{name}: #{detail}")
      end
    end

    total_pass = Enum.count(results, fn {_, _, s, _, _} -> s == :pass end)
    total_run = Enum.count(results, fn {_, _, s, _, _} -> s != :oracle_skip end)
    IO.puts("\nTOTAL: #{total_pass}/#{total_run} pass (#{round(total_pass * 100 / max(total_run, 1))}%)\n")

    if opts[:compare] do
      cmp = compare_baseline(results)
      base = cmp.baseline

      IO.puts(
        "BASELINE: #{base.pass || "?"}/#{base.total || "?"}  delta=#{inspect(cmp.delta_pass)}  (#{cmp.pass_pct}% now)\n"
      )
    end

    results
  end

  @doc "Run report and raise on regression when baseline regresses (for mix --enforce)."
  def report!(opts \\ []) do
    results = report(Keyword.put(opts, :compare, true))
    cmp = compare_baseline(results)
    base = cmp.baseline

    if base.pass && cmp.pass < base.pass do
      raise "census regressed: #{cmp.pass}/#{cmp.total} vs baseline #{base.pass}/#{base.total}"
    end

    results
  end
end
