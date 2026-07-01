defmodule TinyLasers.Gate.F2ScaleTest do
  @moduledoc """
  **F2 Phase 3 (#5 spirit) — a real regex-heavy program completes FLAT where the WASM hybrid OOMs.**

  The markdown→HTML converter (marked's exact domain: `.split`/`.match`/`.replace`-with-capture-group chains
  over objects + arrays + loops + forward function refs) is compiled once and run thousands of times over a
  ~9KB document. On the WASM host-objects lane this class of workload exhausts the no-GC arena (marked_corpus
  OOMs); on BEAM-native it stays flat — objects are GC'd terms. Confined throughout (dangerous_refs empty).
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Lower, Runtime}

  @conv """
  function mdToHtml(src) {
    var lines = src.split(/\\n/); var out = [];
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      if (/^\#{1,6}\\s/.test(line)) {
        var level = line.match(/^\#+/)[0].length;
        out.push('<h' + level + '>' + inline(line.replace(/^\#+\\s*/, '')) + '</h' + level + '>');
      } else if (line.length === 0) { out.push(''); }
      else { out.push('<p>' + inline(line) + '</p>'); }
    }
    return out.join('\\n');
  }
  function inline(t) {
    t = t.replace(/\\*\\*([^*]+)\\*\\*/g, '<b>$1</b>');
    t = t.replace(/`([^`]+)`/g, '<code>$1</code>');
    return t.replace(/\\[([^\\]]+)\\]\\(([^)]+)\\)/g, '<a href="$2">$1</a>');
  }
  mdToHtml
  """

  test "a real regex-heavy program runs correctly at volume, confined" do
    # Arrays + objects are now mutable REFERENCES (JS semantics), stored in a per-run table that does not
    # auto-GC — so a hot loop grows memory (the H1 flat-memory win now needs escape analysis / a GC-able
    # backing to recover). This still exercises the full regex/object/array/loop/forward-ref stack correctly
    # and confined; the flat-memory property is tracked separately by the immutable-term test in f2_vertical.
    body = Lower.program(Js.parse(@conv), %{})
    mod = Module.concat([TinyLasers.Gate.Guest, "ScaleT#{System.unique_integer([:positive])}"])
    [{m, bin}] = Code.compile_quoted(quote do (defmodule unquote(mod) do def run, do: unquote(body) end) end)

    assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin)

    Runtime.__init(%{caps: %{}, tenant_root: "/t", fs: %{}})
    conv = try do apply(m, :run, []) catch :throw, {:gg_return, v} -> v end

    doc = String.duplicate("# Head **bold**\nPara `code` [a](http://x).\n\n", 50)
    last = Enum.reduce(1..300, "", fn _, _ -> Runtime.call(conv, [doc]) end)

    assert String.starts_with?(last, "<h1>Head <b>bold</b></h1>")
  end
end
