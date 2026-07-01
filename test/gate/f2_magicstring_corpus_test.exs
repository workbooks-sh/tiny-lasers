defmodule TinyLasers.Gate.F2MagicStringCorpusTest do
  @moduledoc """
  **F2 rollup-ladder — magic-string-0.30.11 (source manipulation core rollup depends on) runs BEAM-native.**

  The real (unmodified) magic-string bundle is lowered ESTree→Elixir-quoted → a native `.beam` module (no
  WASM), loaded via the CommonJS prelude, and every case in `magicstring_corpus.js` is executed; the output is
  compared byte-for-byte to the golden captured from native node. Exercises ES6 `class` declarations with
  forward references, typed arrays (`new Uint8Array(n)` + indexed set + subarray), object spread over cell
  refs, getters, and the overwrite/update/append/prepend/remove/slice/trim/indent/clone/snip machinery — all
  confined to the Runtime.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Lower, Runtime}

  @conf "test/conformance"

  test "magic-string-0.30.11 runs the corpus byte-identical to the golden, BEAM-native" do
    prelude = File.read!(Path.join(@conf, "porffor_cjs/cjs_prelude.js"))
    console = "var console = { log: function(){ print(arguments[0]); } };\n"
    bundle = console <> prelude <> File.read!(Path.join(@conf, "magic-string-0.30.11.js"))
    driver = File.read!(Path.join(@conf, "magicstring_corpus.js"))

    body = Lower.program(Js.parse(bundle <> "\n" <> driver), %{"print" => 0})
    mod = Module.concat([TinyLasers.Gate.Guest, "MagicStringCorpus#{System.unique_integer([:positive])}"])
    [{m, bin}] = Code.compile_quoted(quote do (defmodule unquote(mod) do def run, do: unquote(body) end) end)

    assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin)

    Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}})
    got = try do apply(m, :run, []); Runtime.__output() catch :throw, _ -> Runtime.__output() end

    # join with newlines and compare to the raw golden — one case (`indent`) legitimately contains an embedded
    # newline, so line-splitting would falsely fragment it. The full text must match the golden byte-for-byte.
    got_text = Enum.join(got, "\n")
    golden = File.read!(Path.join(@conf, "magicstring_corpus.golden.txt")) |> String.trim_trailing("\n")
    assert got_text == golden, "magic-string corpus mismatch:\n  got=#{inspect(got_text)}\n  want=#{inspect(golden)}"
  end
end
