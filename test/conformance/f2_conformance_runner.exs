alias TinyLasers.Gate.Js
pkg = System.get_env("PKG"); corpus = System.get_env("CORPUS")
conf = "test/conformance"
prelude = File.read!(Path.join(conf, "porffor_cjs/cjs_prelude.js"))
console = "var console = { log: function(){ var s=''; for(var i=0;i<arguments.length;i++){ if(i>0)s+=' '; s+=arguments[i]; } print(s); } };\n"
bundle = File.read!(Path.join(conf, pkg))
driver = File.read!(Path.join(conf, corpus))
src = prelude <> console <> bundle <> "\n" <> driver
res = try do Js.run(src) catch k,e -> {:crash, k, e} end
case res do
  %{output: out} ->
    got = out
    golden = File.read!(Path.join(conf, String.replace(corpus, ".js", ".golden.txt"))) |> String.split("\n", trim: true)
    pairs = Enum.zip(golden, got ++ List.duplicate("<none>", max(length(golden)-length(got),0)))
    {pass, _} = Enum.reduce(pairs, {0,0}, fn {g, o}, {p,i} ->
      if g == o, do: {p+1,i+1}, else: (IO.puts("  DIFF want=#{String.slice(g,0,50)} got=#{String.slice(o||"nil",0,50)}"); {p,i+1}) end)
    IO.puts("#{pkg}: #{pass}/#{length(golden)} byte-identical; got #{length(got)} lines")
  other -> IO.puts("#{pkg} CRASH: #{inspect(other)|>String.slice(0,120)}")
end
