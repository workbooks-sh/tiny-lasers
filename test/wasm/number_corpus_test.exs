defmodule TinyLasers.JsPorfforNumberCorpusTest do
  @moduledoc """
  G2 — exact Number/float formatting, byte-identical to node on the Porffor→Washy ASM (shipping) lane.

  `test/conformance/number_corpus.js` exercises `toString` (shortest round-trip + radix + magnitude),
  `toFixed`, `toPrecision`, `toExponential`, `parseFloat`/`parseInt` edges, and special values. The golden is
  native node's output. Each case runs isolated (try/catch in the corpus) so one failure never aborts the
  rest — every label is measurable in one pass.

  Like the regex corpus this test RISES: the genuinely-broken labels are listed in `@known_gaps` and asserted
  to STILL differ, so the moment a fix lands the guard fails and we promote the label. As of writing, 38/48
  are byte-identical; the 10 gaps are all in the digit-generation core — `toString` shortest round-trip
  (`ts-sum`/`ts-third`/`ts-smaller`), the large-magnitude buffer overflow (`ts-max`/`ts-1e100`), `toFixed`
  rounding into the integer part (`fx-round`), and the entirely-missing `toPrecision` (`pr-*`). The fix is a
  shared exact-bignum shortest-round-trip dtoa (x = m·2^e expanded to m·5^(−e), trimmed by round-trip).
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Js.Porffor

  @conf Path.join(__DIR__, "../conformance")
  @prelude Path.join(@conf, "porffor_cjs/cjs_prelude.js")

  # Labels not yet byte-identical (filed for the G2 dtoa). Drop a label here when its fix lands; the assertion
  # below then promotes it to a hard equality check.
  # Remaining after the shortest-round-trip dtoa landed: the magnitude EXTREMES (ts-max/1e100/smaller) where
  # the parse-based round-trip oracle (ecma262.StringToNumber) is itself imprecise at e±300 — needs a bignum
  # boundary test (Dragon4) instead of parse-trim; toFixed rounding into the integer part (fx-round); and the
  # still-missing toPrecision (pr-*).
  # All 48 byte-identical to node on the ASM lane: shortest round-trip toString (exact bignum expansion +
  # Dragon4 boundary test — correct across the full magnitude range), toFixed/toPrecision/toExponential
  # (exact-digit rounding, ties away), parseFloat/parseInt edges, and specials.
  @known_gaps ~w()

  setup_all do
    if File.regular?(Porffor.porf_entry()) and System.find_executable("node"),
      do: :ok,
      else: {:skip, "porffor/node absent"}
  end

  test "number formatting corpus is byte-identical to node on the ASM lane (modulo filed gaps)" do
    corpus = File.read!(Path.join(@conf, "number_corpus.js"))
    golden = File.read!(Path.join(@conf, "number_corpus.golden.txt"))

    src = File.read!(@prelude) <> "\n" <> corpus
    {:ok, r} = TinyLasers.Js.Debug.diagnose(src, fuel: 2_000_000_000, transpile: true)
    assert r.completed, "number corpus run did not complete: #{inspect(r.trap || r.error)}"

    want = golden |> String.trim_trailing("\n") |> String.split("\n") |> Map.new(&split_label/1)
    got = r.output |> String.trim_trailing("\n") |> String.split("\n") |> Map.new(&split_label/1)

    mismatches =
      for {label, want_v} <- want, not (label in @known_gaps), got[label] != want_v do
        "#{label}: want #{inspect(want_v)} got #{inspect(got[label])}"
      end

    assert mismatches == [], "number corpus mismatches (ASM lane):\n" <> Enum.join(mismatches, "\n")

    # Guard the gaps: each must STILL differ — when a fix lands, this fails and we promote the label.
    still_gaps = for label <- @known_gaps, got[label] == want[label], do: label
    assert still_gaps == [], "filed number gaps now PASS — remove from @known_gaps: #{inspect(still_gaps)}"
  end

  defp split_label(line) do
    case String.split(line, "=", parts: 2) do
      [l, v] -> {l, v}
      [l] -> {l, ""}
    end
  end
end
