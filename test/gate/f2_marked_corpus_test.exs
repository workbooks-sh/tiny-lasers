defmodule TinyLasers.Gate.F2MarkedCorpusTest do
  @moduledoc """
  **F2 Phase 3 — THE definitive milestone: the real marked-4.3.0 bundle runs BEAM-native, byte-identical.**

  The actual (unmodified) marked-4.3.0 markdown engine is lowered ESTree→Elixir-quoted and compiled to a real
  .beam module (no WASM), then every case in `marked_corpus.js` is parsed and compared to the golden output
  captured from real marked. This exercises the full engine — ES5 prototype classes, stateful Lexer/Parser
  (`this.tokens`, regex `lastIndex`), the UMD wrapper, closures, conditional/short-circuit assignment, arrays
  as references, and the long tail of String/Array/Object/Math/JSON builtins — all confined to the Runtime.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Lower, Runtime}

  @conf "test/conformance"

  test "marked-4.3.0 renders the full corpus byte-identical to the golden, BEAM-native" do
    body = Lower.program(Js.parse(File.read!(Path.join(@conf, "marked-4.3.0.js"))), %{"print" => 0})
    mod = Module.concat([TinyLasers.Gate.Guest, "Corpus#{System.unique_integer([:positive])}"])
    [{m, bin}] = Code.compile_quoted(quote do (defmodule unquote(mod) do def run, do: unquote(body) end) end)

    # confinement: the compiled marked engine references ONLY the Runtime (no host module, no dangerous BIF).
    assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin)

    Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}})
    try do apply(m, :run, []) catch :throw, _ -> :ok end
    parse = Runtime.oget(Runtime.oget({:globalobj}, "marked"), "parse")
    assert match?({:fn, _}, parse), "marked.parse must be a function"

    cases =
      Regex.scan(~r/show\("([^"]+)",\s*"((?:[^"\\]|\\.)*)"\)/, File.read!(Path.join(@conf, "marked_corpus.js")))
      |> Enum.map(fn [_, l, md] -> {l, md} end)

    golden =
      File.read!(Path.join(@conf, "marked_corpus.golden.txt"))
      |> String.split("\n", trim: true)
      |> Map.new(fn line -> line |> String.split("=", parts: 2) |> List.to_tuple() end)

    for {label, md_raw} <- cases do
      md = md_raw |> String.replace("\\n", "\n") |> String.replace("\\\"", "\"") |> String.replace("\\\\", "\\")
      html = Runtime.call(parse, [md])
      assert is_binary(html), "#{label}: parse returned #{inspect(html)}"
      assert json(html) == golden[label], "#{label} mismatch"
    end
  end

  # JSON-string-encode to compare against the golden (captured via JSON.stringify).
  defp json(s) do
    "\"" <>
      (s
       |> String.replace("\\", "\\\\")
       |> String.replace("\"", "\\\"")
       |> String.replace("\n", "\\n")
       |> String.replace("\t", "\\t")) <> "\""
  end
end
