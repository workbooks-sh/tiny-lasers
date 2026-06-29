defmodule TinyLasers.Wasm.Sexp do
  @moduledoc """
  A reader for the **S-expression** surface that WebAssembly's text format (`.wat`) and spec test
  scripts (`.wast`) are written in. Tokenizes and parses into a nested term tree — the foundation the
  WAT assembler (`TinyLasers.Wasm.Wat`) and the spec-test runner build on.

  A parsed atom is a `String.t()`; a list is an Elixir list. Strings (`"..."`, with escapes) become
  `{:string, binary}` so they're distinguishable from bare atoms. Line (`;; …`) and block (`(; … ;)`)
  comments are stripped. `parse_all/1` returns the sequence of top-level forms in a file.
  """

  @doc "Parse all top-level forms from `text`. → `[form]`."
  def parse_all(text) when is_binary(text) do
    text |> tokenize() |> parse_forms([])
  end

  # ── tokenizer ─────────────────────────────────────────────────────────────────────────────────
  defp tokenize(text), do: tok(text, [])

  defp tok(<<>>, acc), do: Enum.reverse(acc)
  defp tok(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\n, ?\r], do: tok(rest, acc)
  defp tok(<<"(;", rest::binary>>, acc), do: tok(skip_block(rest), acc)
  defp tok(<<";;", rest::binary>>, acc), do: tok(skip_line(rest), acc)
  defp tok(<<"(", rest::binary>>, acc), do: tok(rest, [:open | acc])
  defp tok(<<")", rest::binary>>, acc), do: tok(rest, [:close | acc])
  defp tok(<<"\"", rest::binary>>, acc), do: (
    {str, rest} = read_string(rest, [])
    tok(rest, [{:string, str} | acc])
  )
  defp tok(bin, acc) do
    {atom, rest} = read_atom(bin, [])
    tok(rest, [{:atom, atom} | acc])
  end

  defp skip_block(<<";)", rest::binary>>), do: rest
  defp skip_block(<<_, rest::binary>>), do: skip_block(rest)
  defp skip_block(<<>>), do: <<>>

  defp skip_line(<<"\n", rest::binary>>), do: rest
  defp skip_line(<<_, rest::binary>>), do: skip_line(rest)
  defp skip_line(<<>>), do: <<>>

  defp read_string(<<"\\", h1, h2, rest::binary>>, acc) when ?0 <= h1 and h1 <= ?f,
    do: (if hex?(h1) and hex?(h2), do: read_string(rest, [hexval(h1) * 16 + hexval(h2) | acc]), else: read_string(<<h2, rest::binary>>, [unescape(h1) | acc]))

  defp read_string(<<"\\", c, rest::binary>>, acc), do: read_string(rest, [unescape(c) | acc])
  defp read_string(<<"\"", rest::binary>>, acc), do: {acc |> Enum.reverse() |> :erlang.list_to_binary(), rest}
  defp read_string(<<c, rest::binary>>, acc), do: read_string(rest, [c | acc])
  defp read_string(<<>>, acc), do: {acc |> Enum.reverse() |> :erlang.list_to_binary(), <<>>}

  # \n \t \r \" \\ and \HH hex byte escapes (the wat string escapes the spec tests use)
  defp unescape(?n), do: ?\n
  defp unescape(?t), do: ?\t
  defp unescape(?r), do: ?\r
  defp unescape(?"), do: ?"
  defp unescape(?\\), do: ?\\
  defp unescape(c), do: c

  defp hex?(c), do: (c >= ?0 and c <= ?9) or (c >= ?a and c <= ?f) or (c >= ?A and c <= ?F)
  defp hexval(c) when c >= ?0 and c <= ?9, do: c - ?0
  defp hexval(c) when c >= ?a and c <= ?f, do: c - ?a + 10
  defp hexval(c) when c >= ?A and c <= ?F, do: c - ?A + 10

  defp read_atom(<<c, _::binary>> = bin, acc) when c in [?\s, ?\t, ?\n, ?\r, ?(, ?), ?"] or bin == <<>>,
    do: {acc |> Enum.reverse() |> :erlang.list_to_binary(), bin}

  defp read_atom(<<c, rest::binary>>, acc), do: read_atom(rest, [c | acc])
  defp read_atom(<<>>, acc), do: {acc |> Enum.reverse() |> :erlang.list_to_binary(), <<>>}

  # ── parser ────────────────────────────────────────────────────────────────────────────────────
  defp parse_forms([], acc), do: Enum.reverse(acc)

  defp parse_forms([:open | rest], acc) do
    {list, rest} = parse_list(rest, [])
    parse_forms(rest, [list | acc])
  end

  defp parse_forms([tok | rest], acc), do: parse_forms(rest, [leaf(tok) | acc])

  defp parse_list([:close | rest], acc), do: {Enum.reverse(acc), rest}

  defp parse_list([:open | rest], acc) do
    {inner, rest} = parse_list(rest, [])
    parse_list(rest, [inner | acc])
  end

  defp parse_list([tok | rest], acc), do: parse_list(rest, [leaf(tok) | acc])
  defp parse_list([], acc), do: {Enum.reverse(acc), []}

  defp leaf({:atom, a}), do: a
  defp leaf({:string, s}), do: {:string, s}
end
