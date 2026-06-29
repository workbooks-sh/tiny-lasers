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
   "class A{m(){return 1;}} class B extends A{m(){return super.m()+1;}} console.log(new B().m());", "2"}
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
