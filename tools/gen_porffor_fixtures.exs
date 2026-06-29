# Porffor → WASM fixture generator for tiny-lasers.
#
# tiny-lasers is the WASM→BEAM *runtime*; the Porffor JS→WASM *compiler* lives in nexus.
# To prove real JS runs byte-identical on TinyLasers.Wasm WITHOUT dragging the compiler into
# tiny-lasers, we compile a set of representative JS programs to `.wasm` here (in the nexus
# context, which has Porffor) and check the bytes in as fixtures. The tiny-lasers test then
# runs them on its own runtime and asserts node-identical stdout.
#
# Regenerate:  cd nexus && mix run ../tiny-lasers/tools/gen_porffor_fixtures.exs
#
# Each entry is {name, js, want} where `want` is the node reference output (the same pairs
# proven node-identical on the nexus Porffor→Washy lane in washy_porffor_test.exs). The
# generator validates each program is byte-identical on the nexus lane BEFORE writing its
# fixture, so a green tiny-lasers run means: TinyLasers.Wasm ≡ nexus lane ≡ node.

alias Nexus.Compilers.Js.Porffor

out_dir =
  Path.expand(Path.join(Path.dirname(__ENV__.file), "../test/fixtures/porffor"))

File.mkdir_p!(out_dir)

fixtures = [
  # --- AOT-friendly subset (the easy floor) ---
  {"arith_loops", "let s=0; for(let i=0;i<1000;i++) s+=i*2; console.log(s);", "999000"},
  {"pow_underscore", "console.log(2**10 + 1_000);", "2024"},
  {"labeled_switch",
   "let r=0; outer: for(let i=0;i<3;i++){switch(i){case 1: r+=10; break; default: r+=1;}} console.log(r);",
   "12"},
  {"array_methods", "console.log([1,2,3,4].filter(n=>n%2).map(n=>n*n).reduce((a,b)=>a+b,0));", "10"},
  {"string_methods", "console.log('Hello World'.toLowerCase().split(' ').join('-').slice(0,5));", "hello"},
  {"json_stringify", ~s|console.log(JSON.stringify({a:[1,2],b:'x'}));|, ~s|{"a":[1,2],"b":"x"}|},
  {"json_parse", ~s|console.log(JSON.parse('{"a":5}').a);|, "5"},
  {"destructuring", "const {a,b=5}={a:1}; const [x,...y]=[1,2,3]; console.log(a+b+x+y.length);", "9"},
  {"class_super",
   "class A{m(){return 1;}} class B extends A{m(){return super.m()+1;}} console.log(new B().m());", "2"},

  # --- The hard surface rollup/vite actually exercise (proven node-identical in the nexus corpora) ---
  {"closure_counter", "function mk(){let c=0; return ()=>++c;} let f=mk(); console.log(f()+f()+f());", "6"},
  {"closure_loop_capture",
   "let a=[]; for(let i=0;i<3;i++) a.push(()=>i); console.log(a.map(f=>f()).join(','));", "0,1,2"},
  {"regex_replace_g", "console.log('a1b2c3'.replace(/[0-9]/g,'#'));", "a#b#c#"},
  {"regex_match_groups",
   "console.log('2026-06-29'.match(/(\\d+)-(\\d+)-(\\d+)/).slice(1).join('/'));", "2026/06/29"},
  # NB: `**` on bigint traps on the nexus lane today (heap-pow gap); use add + digit-exact toString.
  {"bigint", "console.log((123456789012345678901234567890n + 1n).toString());",
   "123456789012345678901234567891"},
  {"number_float_repr", "console.log((0.1+0.2).toString());", "0.30000000000000004"},
  {"number_toFixed", "console.log((1234.5678).toFixed(2));", "1234.57"},
  {"map_keys", "let m=new Map([['a',1],['b',2]]); console.log([...m.keys()].join('')+m.get('b'));", "ab2"},
  {"set_dedup", "console.log([...new Set([1,1,2,3,3])].join(','));", "1,2,3"},
  {"template_literal", "let x=5; console.log(`val=${x*2}!`);", "val=10!"},
  {"spread_rest", "function sum(...xs){return xs.reduce((a,b)=>a+b,0);} console.log(sum(...[1,2,3],4));", "10"},
  {"try_catch_type",
   "try{ null.x; }catch(e){ console.log('caught '+(e instanceof TypeError)); }", "caught true"},
  {"typed_array", "let a=new Uint8Array([1,2,3]); a[1]=9; console.log(a.reduce((x,y)=>x+y,0));", "13"},
  {"sort_numeric", "console.log([3,1,2,10].sort((a,b)=>a-b).join(','));", "1,2,3,10"},
  {"optional_chain", "let o={a:{b:5}}; console.log((o?.a?.b ?? 'none')+'/'+(o?.x?.y ?? 'none'));", "5/none"},
  {"string_pad", "console.log('5'.padStart(3,'0'));", "005"}
]

unless File.regular?(Porffor.porf_entry()) and System.find_executable("node") do
  IO.puts(:stderr, "ABORT: Porffor not vendored / node absent — cannot generate fixtures")
  System.halt(1)
end

results =
  for {name, js, want} <- fixtures do
    # validate-the-instrument: confirm the program is byte-identical on the nexus lane first.
    nexus_ok =
      case Porffor.eval(js) do
        {:ok, out} ->
          got = out |> String.replace(~r/\e\[[0-9;]*m/, "") |> String.trim()
          got == want or {:mismatch, got}

        err ->
          {:eval_err, err}
      end

    case {nexus_ok, Porffor.compile(js)} do
      {true, {:ok, wasm}} ->
        File.write!(Path.join(out_dir, name <> ".wasm"), wasm)
        IO.puts("  ✓ #{name}  (#{byte_size(wasm)} bytes)  → #{inspect(want)}")
        :ok

      {true, err} ->
        IO.puts(:stderr, "  ✗ #{name}: compile failed: #{inspect(err)}")
        {:fail, name}

      {bad, _} ->
        IO.puts(:stderr, "  ✗ #{name}: nexus lane not node-identical: #{inspect(bad)}")
        {:fail, name}
    end
  end

fails = Enum.reject(results, &(&1 == :ok))
IO.puts("\n#{Enum.count(results, &(&1 == :ok))}/#{length(results)} fixtures written → #{out_dir}")

if fails != [], do: System.halt(1)
