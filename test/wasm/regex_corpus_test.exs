defmodule TinyLasers.JsPorfforRegexCorpusTest do
  @moduledoc """
  G1's "regex corpus byte-identical to node" clause, on the ASM transpiler (shipping) lane.

  `test/conformance/regex_corpus.js` exercises the full named feature set — {n,m} quantifiers (exact/
  range/min/lazy/zero), group types (capturing / non-capturing / named / backrefs), alternation, character
  classes (ranges / negation / predefined / mixed / unicode), anchors (^ $ \\b \\B multiline), look-around
  (look-ahead + look-behind), flags gimsuy, Unicode (\\u escapes / \\u{} / \\p{}), replace (function +
  $-templates), and split (with + without capture groups). The golden is native node's output.

  Run on the Porffor→Washy ASM lane and asserted line-by-line. KNOWN GAPS (filed in bd, asserted here so the
  test RISES — flagging the moment one is fixed) are the genuinely hard items: named-group `.groups` object,
  `\\k<name>` backref, lookbehind `(?<=)`/`(?<!)`, astral `\\u{>FFFF}` matching, and `\\p{}` Unicode property
  tables. Everything else (36/42 at time of writing) must stay byte-identical.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Js.Porffor

  @conf Path.join(__DIR__, "../conformance")
  @prelude Path.join(@conf, "porffor_cjs/cjs_prelude.js")

  # The genuinely-hard regex features not yet implemented (filed in bd). When one is fixed, drop its label
  # here and the assertion below promotes it to a hard equality check.
  # All 42 features byte-identical to node on the ASM lane. (Astral `\u{>FFFF}` is matched via a
  # code-unit-aware matcher: sp stays in UTF-16 code units, reads widen for wide string inputs, and an astral
  # escape compiles to its surrogate pair — see __Porffor_regex_cu / op 0x0f in regexp.ts.)
  @known_gaps ~w()

  setup_all do
    if File.regular?(Porffor.porf_entry()) and System.find_executable("node"),
      do: :ok,
      else: {:skip, "porffor/node absent"}
  end

  test "regex feature corpus is byte-identical to node on the ASM lane (modulo filed gaps)" do
    corpus = File.read!(Path.join(@conf, "regex_corpus.js"))
    golden = File.read!(Path.join(@conf, "regex_corpus.golden.txt"))

    src = File.read!(@prelude) <> "\n" <> corpus
    {:ok, r} = TinyLasers.Js.Debug.diagnose(src, fuel: 2_000_000_000, transpile: true)
    assert r.completed, "corpus run did not complete: #{inspect(r.trap || r.error)}"

    want = golden |> String.trim_trailing("\n") |> String.split("\n") |> Map.new(&split_label/1)
    got = r.output |> String.trim_trailing("\n") |> String.split("\n") |> Map.new(&split_label/1)

    mismatches =
      for {label, want_v} <- want, not (label in @known_gaps), got[label] != want_v do
        "#{label}: want #{inspect(want_v)} got #{inspect(got[label])}"
      end

    assert mismatches == [], "regex corpus mismatches (ASM lane):\n" <> Enum.join(mismatches, "\n")

    # Guard the gaps: each must STILL differ — when a fix lands, this fails and we promote the label.
    still_gaps = for label <- @known_gaps, got[label] == want[label], do: label
    assert still_gaps == [], "filed regex gaps now PASS — remove from @known_gaps: #{inspect(still_gaps)}"
  end

  defp split_label(line) do
    case String.split(line, "=", parts: 2) do
      [l, v] -> {l, v}
      [l] -> {l, ""}
    end
  end
end
