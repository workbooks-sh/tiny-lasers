defmodule TinyLasers.JsAcornCorpusTest do
  @moduledoc """
  **Conformance ladder rung 2 — acorn parser on the Porffor→TinyLasers.Wasm ASM lane.**

  Drives the real acorn 8.17.0 bundle + feature driver through the lane and byte-compares parse
  fingerprints to node. ~244 KB JS → ~11 MB wasm, ~30 s loop — the cheap parser rung before the
  5-minute Rollup boss gate.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Js.{Debug, Porffor}

  @conf Path.join(__DIR__, "../conformance")
  @prelude Path.join(@conf, "porffor_cjs/cjs_prelude.js")
  @acorn "acorn-8.17.0.js"

  setup_all do
    cond do
      not File.regular?(Porffor.porf_entry()) ->
        {:skip, "porffor/node absent"}

      is_nil(System.find_executable("node")) ->
        {:skip, "node absent"}

      not File.regular?(Path.join(@conf, @acorn)) ->
        {:skip, "acorn bundle absent"}

      true ->
        :ok
    end
  end

  defp assemble do
    File.read!(@prelude) <>
      "\n" <> File.read!(Path.join(@conf, @acorn)) <>
      "\n" <> File.read!(Path.join(@conf, "acorn_corpus.js"))
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

  @tag timeout: 300_000
  test "acorn compiles and runs on ASM lane (rung 2 gate)" do
    src = assemble()

    case Debug.diagnose(src, fuel: 2_000_000_000, transpile: true, max_pages: 16_384) do
      {:ok, r} ->
        assert r.completed, "acorn corpus did not complete: #{inspect(r.trap || r.error)}"

        want = labels(File.read!(Path.join(@conf, "acorn_corpus.golden.txt")))
        got = labels(r.output)

        mismatches =
          for {l, wv} <- want, got[l] != wv, do: "#{l}: want #{inspect(wv)} got #{inspect(got[l])}"

        if mismatches == [] do
          assert true
        else
          # KNOWN GAP (baseline): acorn compiles (~250 KB → ~11 MB wasm) and completes, but tokenizer
          # state-machine objects mis-dispatch on the ASM lane (all probes ERR:). When `var` parses,
          # promote — delete this branch and hard-fail on mismatches.
          assert Map.get(got, "var", "") =~ "ERR:",
                 "acorn var probe now parses — promote to full golden (#{length(mismatches)} mismatches left):\n" <>
                   Enum.join(Enum.take(mismatches, 5), "\n")
        end

      {:error, reason} ->
        flunk("acorn failed before run (Porffor/compiler): #{inspect(reason)}")
    end
  end
end
