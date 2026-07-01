defmodule TinyLasers.Gate.F2RegexTest do
  @moduledoc """
  **F2 Phase 3 — regex as a confined host capability (the marked unlock).**

  Regex is not ported to guest-JS; it is a CAPABILITY backed by Elixir's `Regex`, returning guest values. A
  regex is a guest-safe term `{:regex, compiled, source, flags}`; the guest can only pass it to the regex
  methods. The guest binary still references ONLY `TinyLasers.Gate.Runtime` (Regex lives inside the trusted
  Runtime), so confinement is unaffected — verified here.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.Js

  defp run(src), do: Js.run(src)

  test "regex literal + test / new RegExp" do
    assert %{result: {:ok, true}} = run("/ab+c/.test('xabbbcx')")
    assert %{result: {:ok, false}} = run("/^\\d+$/.test('12a')")
    assert %{result: {:ok, true}} = run("var re = new RegExp('foo', 'i'); re.test('FOO')")
  end

  test "replace: global string, capture groups, and a function replacer" do
    assert %{result: {:ok, "hell0 w0rld"}} = run("'hello world'.replace(/o/g, '0')")
    assert %{result: {:ok, "15/01/2024"}} = run("'2024-01-15'.replace(/(\\d+)-(\\d+)-(\\d+)/, '$3/$2/$1')")
    assert %{result: {:ok, "ABC"}} = run("'abc'.replace(/[a-c]/g, function(m){ return m.toUpperCase(); })")
  end

  test "match / split / search / exec" do
    assert %{result: {:ok, "1,2,3"}} = run("'a1b2c3'.match(/\\d/g).join(',')")
    assert %{result: {:ok, "a|b|c"}} = run("'a, b ,c'.split(/\\s*,\\s*/).join('|')")
    assert %{result: {:ok, 6.0}} = run("'hello world'.search(/world/)")
    assert %{result: {:ok, "2024"}} = run("var m = /(\\d{4})/.exec('year 2024 ok'); m[1]")
  end

  test "a regex program still references only the Runtime (confinement)" do
    %{binary: bin, result: {:ok, "heLLo"}} = run("'hello'.replace(/l/g, 'L')")
    assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin)
  end
end
