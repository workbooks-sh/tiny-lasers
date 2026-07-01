defmodule TinyLasers.Gate.F2AcornCorpusTest do
  @moduledoc """
  **F2 rollup-ladder — acorn-8.17.0 (the parser rollup depends on) runs BEAM-native, byte-identical.**

  The real (unmodified) acorn JavaScript parser is lowered ESTree→Elixir-quoted → a native `.beam` module (no
  WASM), loaded via the CommonJS prelude, and every case in `acorn_corpus.js` is parsed; the AST fingerprint
  (node type + child count) is compared to the golden captured from native node. Exercises the full parser —
  ES5 prototype classes with getter properties (inFunction/inGenerator via defineProperties), stateful
  tokenizer (regex lastIndex, `this.pos`), labeled loops + break/continue, switch fall-through, Infinity/NaN,
  `[^]` regex, `indexOf(sub, from)`, and code-point string semantics for unicode identifiers.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Lower, Runtime}

  @conf "test/conformance"

  test "acorn-8.17.0 parses the corpus byte-identical to the golden fingerprint, BEAM-native" do
    prelude = File.read!(Path.join(@conf, "porffor_cjs/cjs_prelude.js"))
    console = "var console = { log: function(){ print(arguments[0]); } };\n"
    bundle = console <> prelude <> File.read!(Path.join(@conf, "acorn-8.17.0.js"))
    driver = File.read!(Path.join(@conf, "acorn_corpus.js"))

    body = Lower.program(Js.parse(bundle <> "\n" <> driver), %{"print" => 0})
    mod = Module.concat([TinyLasers.Gate.Guest, "AcornCorpus#{System.unique_integer([:positive])}"])
    [{m, bin}] = Code.compile_quoted(quote do (defmodule unquote(mod) do def run, do: unquote(body) end) end)

    assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin)

    Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}})
    got = try do apply(m, :run, []); Runtime.__output() catch :throw, _ -> Runtime.__output() end

    golden = File.read!(Path.join(@conf, "acorn_corpus.golden.txt")) |> String.split("\n", trim: true)
    assert got == golden, "acorn corpus mismatch:\n  got=#{inspect(Enum.take(got, 3))}\n  want=#{inspect(Enum.take(golden, 3))}"
  end
end
