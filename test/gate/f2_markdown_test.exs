defmodule TinyLasers.Gate.F2MarkdownTest do
  @moduledoc """
  **F2 Phase 3 — a real regex-heavy program (markdown → HTML) runs BEAM-native, confined.**

  marked's actual domain: a converter built from `.split`/`.match`/`.replace`-with-capture-groups chains,
  objects, arrays, loops, forward function references (`mdToHtml` calls `inline`, declared later), and string
  ops. The whole stack runs on native GC'd terms and the guest references only the Runtime. This is the
  end-to-end "it works on real code" proof for the F2 endgame — the thing the WASM hybrid OOMs on.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.Js

  @src """
  function mdToHtml(src) {
    var lines = src.split(/\\n/);
    var out = [];
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      if (/^#\{1,6}\\s/.test(line)) {
        var level = line.match(/^#+/)[0].length;
        var text = line.replace(/^#+\\s*/, '');
        out.push('<h' + level + '>' + inline(text) + '</h' + level + '>');
      } else if (line.length === 0) {
        out.push('');
      } else {
        out.push('<p>' + inline(line) + '</p>');
      }
    }
    return out.join('\\n');
  }
  function inline(t) {
    t = t.replace(/\\*\\*([^*]+)\\*\\*/g, '<b>$1</b>');
    t = t.replace(/`([^`]+)`/g, '<code>$1</code>');
    t = t.replace(/\\[([^\\]]+)\\]\\(([^)]+)\\)/g, '<a href="$2">$1</a>');
    return t;
  }
  mdToHtml('# Hello **world**\\nSome `code` and a [link](http://x.com).\\n## Sub')
  """

  test "markdown → HTML end-to-end, correct output, references only the Runtime" do
    %{result: res, binary: bin} = Js.run(@src)

    expected =
      "<h1>Hello <b>world</b></h1>\n" <>
        "<p>Some <code>code</code> and a <a href=\"http://x.com\">link</a>.</p>\n" <>
        "<h2>Sub</h2>"

    assert res == {:ok, expected}
    assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin)
  end
end
