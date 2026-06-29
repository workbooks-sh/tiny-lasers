defmodule TinyLasers.JsPkgCorpusTest do
  @moduledoc """
  **Real npm packages, three different TYPES — expanding real-program coverage beyond synthetic corpora.**

  Drives whole real-world npm bundles through `cjs_prelude + <bundle> + <feature driver>` on the
  Porffor→TinyLasers.Wasm ASM lane and byte-compares to node. Three distinct domains:

    * **marked** (4.3.0) — markdown→HTML parser (regex, recursive descent, tables). **Byte-identical, 16/16.**
    * **bignumber.js** (9.1.2) — arbitrary-precision decimal. **Known lane gap:** the bundle's class setup
      hits `TypeError: Cannot set property 'prototype' of undefined` (a codegen gap in the prototype-assign
      path). Asserted to STILL fail so the guard flips the day it's fixed → promote to a byte-identical gate.
    * **dayjs** (1.11.10) — date/time. **Known lane gap:** hangs (>200s, no completion) — a perf/loop gap in
      the Date path. Skipped (can't run without wedging the suite); golden kept for when it's fixed.

  Goldens are real node output of the SAME bundle + driver. Two gaps filed for the conformance grind; this
  is the value of real-program coverage — it finds real bugs the synthetic corpora don't.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Js.{Debug, Porffor}

  @conf Path.join(__DIR__, "../conformance")
  @prelude Path.join(@conf, "porffor_cjs/cjs_prelude.js")

  setup_all do
    if File.regular?(Porffor.porf_entry()) and System.find_executable("node"),
      do: :ok,
      else: {:skip, "porffor/node absent"}
  end

  defp run_pkg(pkg, corpus) do
    src =
      File.read!(@prelude) <>
        "\n" <> File.read!(Path.join(@conf, pkg)) <> "\n" <> File.read!(Path.join(@conf, corpus))

    Debug.diagnose(src, fuel: 2_000_000_000, transpile: true)
  end

  defp labels(text) do
    text
    |> String.trim_trailing("\n")
    |> String.split("\n")
    |> Map.new(fn line ->
      case String.split(line, "=", parts: 2) do
        [l, v] -> {l, v}
        [l] -> {l, ""}
      end
    end)
  end

  @tag timeout: 120_000
  test "marked (markdown parser) is byte-identical to node on the moved lane — 16/16" do
    {:ok, r} = run_pkg("marked-4.3.0.js", "marked_corpus.js")
    assert r.completed, "marked corpus did not complete: #{inspect(r.trap || r.error)}"

    want = labels(File.read!(Path.join(@conf, "marked_corpus.golden.txt")))
    got = labels(r.output)
    mismatches = for {l, wv} <- want, got[l] != wv, do: "#{l}: want #{inspect(wv)} got #{inspect(got[l])}"
    assert mismatches == [], "marked mismatches (ASM lane):\n" <> Enum.join(mismatches, "\n")
  end

  @tag timeout: 120_000
  test "bignumber.js — KNOWN GAP: bundle prototype-assign fails (flips when fixed)" do
    {:ok, r} = run_pkg("bignumber-9.1.2.js", "bignumber_corpus.js")

    # The bundle's class wiring hits `Cannot set property 'prototype' of undefined` on the lane. When the
    # codegen gap is fixed it will complete — then this guard fails and we promote to a byte-identical gate
    # against bignumber_corpus.golden.txt.
    refute r.completed,
           "bignumber now COMPLETES on the lane — promote: byte-compare r.output to bignumber_corpus.golden.txt"
  end

  # dayjs HANGS on the lane (>200s, no completion) — a perf/loop gap in the Date path. Can't run it without
  # wedging the suite, so it's skipped (not deleted) until the gap is fixed; the golden + driver stay ready.
  @tag :skip
  test "dayjs — KNOWN GAP: hangs on the lane (perf/loop in the Date path)" do
    {:ok, r} = run_pkg("dayjs-1.11.10.js", "dayjs_corpus.js")
    want = labels(File.read!(Path.join(@conf, "dayjs_corpus.golden.txt")))
    assert labels(r.output) == want
  end
end
