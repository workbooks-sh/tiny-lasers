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

  test "thousands of markdown conversions stay flat + correct + confined" do
    body = Lower.program(Js.parse(@conv), %{})
    mod = Module.concat([TinyLasers.Gate.Guest, "ScaleT#{System.unique_integer([:positive])}"])
    [{m, bin}] = Code.compile_quoted(quote do (defmodule unquote(mod) do def run, do: unquote(body) end) end)

    assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin)

    Runtime.__init(%{caps: %{}, tenant_root: "/t", fs: %{}})
    conv = try do apply(m, :run, []) catch :throw, {:gg_return, v} -> v end

    doc = String.duplicate("# Head **bold**\nPara `code` [a](http://x).\n\n", 200)

    :erlang.garbage_collect()
    before = :erlang.memory(:total) |> div(1024 * 1024)
    last = Enum.reduce(1..3000, "", fn _, _ -> Runtime.call(conv, [doc]) end)
    :erlang.garbage_collect()
    delta = (:erlang.memory(:total) |> div(1024 * 1024)) - before

    assert String.starts_with?(last, "<h1>Head <b>bold</b></h1>")
    # ~27MB of markdown processed; memory stays flat (the wall is gone).
    assert delta < 50, "3000 markdown conversions should stay flat; grew #{delta} MB"
  end
end
