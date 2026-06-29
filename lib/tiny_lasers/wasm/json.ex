defmodule TinyLasers.Wasm.Json do
  @moduledoc """
  A tiny, self-contained JSON codec — zero external dependencies.

  tiny-lasers is a supply-chain-isolation substrate; pulling in a JSON library would add the exact
  dependency surface the whole project exists to confine. The JS↔BEAM bridge (`TinyLasers.Wasm.Actor.Term`)
  and the `host_call` seam exchange JSON text across the wasm memory boundary — the guest produces it with
  `JSON.stringify`, the host parses it here. The payloads are the restricted bridge shape:

      nil | boolean | number (int/float) | binary (string) | [value] | %{optional(binary) => value}

  so a focused recursive-descent parser + a straight encoder cover it completely, with **no dep**.

  Integers stay exact (never coerced to float). Strings round-trip as UTF-8 with full JSON escaping,
  including `\\uXXXX` and surrogate-pair recombination on decode. `decode!/1` raises on malformed input —
  callers sit on the host-call path, which is already wrapped at the run boundary, so a bad guest payload
  surfaces as a trapped run, not a silent wrong value.
  """

  # ── Encode ────────────────────────────────────────────────────────────────────────────────────

  @doc "Encode a value in the bridge shape to JSON text. Assumes the input is already normalized."
  @spec encode!(term()) :: binary()
  def encode!(value), do: value |> enc() |> IO.iodata_to_binary()

  defp enc(nil), do: "null"
  defp enc(true), do: "true"
  defp enc(false), do: "false"
  defp enc(n) when is_integer(n), do: Integer.to_string(n)
  defp enc(n) when is_float(n), do: :erlang.float_to_binary(n, [:short])
  defp enc(s) when is_binary(s), do: [?", esc(s, []), ?"]
  defp enc(l) when is_list(l), do: [?[, l |> Enum.map(&enc/1) |> join_commas(), ?]]

  defp enc(m) when is_map(m) do
    [?{, m |> Enum.map(fn {k, v} -> [enc(to_string(k)), ?:, enc(v)] end) |> join_commas(), ?}]
  end

  defp join_commas([]), do: []
  defp join_commas([h | t]), do: [h | Enum.map(t, &[?,, &1])]

  # Escape only what JSON requires; pass valid UTF-8 through raw.
  defp esc(<<>>, acc), do: Enum.reverse(acc)
  defp esc(<<?", rest::binary>>, acc), do: esc(rest, ["\\\"" | acc])
  defp esc(<<?\\, rest::binary>>, acc), do: esc(rest, ["\\\\" | acc])
  defp esc(<<?\n, rest::binary>>, acc), do: esc(rest, ["\\n" | acc])
  defp esc(<<?\t, rest::binary>>, acc), do: esc(rest, ["\\t" | acc])
  defp esc(<<?\r, rest::binary>>, acc), do: esc(rest, ["\\r" | acc])
  defp esc(<<?\b, rest::binary>>, acc), do: esc(rest, ["\\b" | acc])
  defp esc(<<?\f, rest::binary>>, acc), do: esc(rest, ["\\f" | acc])

  defp esc(<<c, rest::binary>>, acc) when c < 0x20 do
    esc(rest, [("\\u" <> (c |> Integer.to_string(16) |> String.pad_leading(4, "0"))) | acc])
  end

  defp esc(<<c, rest::binary>>, acc), do: esc(rest, [<<c>> | acc])

  # ── Decode ────────────────────────────────────────────────────────────────────────────────────

  @doc "Parse JSON text into the bridge shape. Raises `ArgumentError` on malformed input."
  @spec decode!(binary()) :: term()
  def decode!(bin) when is_binary(bin) do
    {value, rest} = parse_value(ws(bin))

    case ws(rest) do
      <<>> -> value
      junk -> raise ArgumentError, "trailing JSON after value: #{inspect(binary_part(junk, 0, min(16, byte_size(junk))))}"
    end
  end

  defp ws(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: ws(rest)
  defp ws(bin), do: bin

  defp parse_value(<<"null", rest::binary>>), do: {nil, rest}
  defp parse_value(<<"true", rest::binary>>), do: {true, rest}
  defp parse_value(<<"false", rest::binary>>), do: {false, rest}
  defp parse_value(<<?", rest::binary>>), do: parse_string(rest, [])
  defp parse_value(<<?[, rest::binary>>), do: parse_array(ws(rest), [])
  defp parse_value(<<?{, rest::binary>>), do: parse_object(ws(rest), [])
  defp parse_value(<<c, _::binary>> = bin) when c == ?- or (c >= ?0 and c <= ?9), do: parse_number(bin)
  defp parse_value(bin), do: raise(ArgumentError, "unexpected JSON: #{inspect(binary_part(bin, 0, min(16, byte_size(bin))))}")

  # strings
  defp parse_string(<<?", rest::binary>>, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
  defp parse_string(<<?\\, ?", rest::binary>>, acc), do: parse_string(rest, [?" | acc])
  defp parse_string(<<?\\, ?\\, rest::binary>>, acc), do: parse_string(rest, [?\\ | acc])
  defp parse_string(<<?\\, ?/, rest::binary>>, acc), do: parse_string(rest, [?/ | acc])
  defp parse_string(<<?\\, ?n, rest::binary>>, acc), do: parse_string(rest, [?\n | acc])
  defp parse_string(<<?\\, ?t, rest::binary>>, acc), do: parse_string(rest, [?\t | acc])
  defp parse_string(<<?\\, ?r, rest::binary>>, acc), do: parse_string(rest, [?\r | acc])
  defp parse_string(<<?\\, ?b, rest::binary>>, acc), do: parse_string(rest, [?\b | acc])
  defp parse_string(<<?\\, ?f, rest::binary>>, acc), do: parse_string(rest, [?\f | acc])

  # \uXXXX — recombine a high+low surrogate pair into one codepoint, else emit the BMP char.
  defp parse_string(<<?\\, ?u, h::binary-size(4), ?\\, ?u, l::binary-size(4), rest::binary>>, acc) do
    hi = String.to_integer(h, 16)
    lo = String.to_integer(l, 16)

    if hi in 0xD800..0xDBFF and lo in 0xDC00..0xDFFF do
      cp = 0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00)
      parse_string(rest, [<<cp::utf8>> | acc])
    else
      parse_string(<<?\\, ?u, l::binary, rest::binary>>, [<<hi::utf8>> | acc])
    end
  end

  defp parse_string(<<?\\, ?u, x::binary-size(4), rest::binary>>, acc) do
    parse_string(rest, [<<String.to_integer(x, 16)::utf8>> | acc])
  end

  defp parse_string(<<c, rest::binary>>, acc), do: parse_string(rest, [c | acc])
  defp parse_string(<<>>, _acc), do: raise(ArgumentError, "unterminated JSON string")

  # numbers: int unless a fraction/exponent is present (keeps integers exact)
  defp parse_number(bin) do
    {tok, rest} = take_number(bin, [])

    num =
      if String.contains?(tok, [".", "e", "E"]),
        do: String.to_float(normalize_float(tok)),
        else: String.to_integer(tok)

    {num, rest}
  end

  defp take_number(<<c, rest::binary>>, acc) when c in [?-, ?+, ?., ?e, ?E] or (c >= ?0 and c <= ?9),
    do: take_number(rest, [c | acc])

  defp take_number(bin, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), bin}

  # Elixir's String.to_float needs a digit on both sides of the dot and after 'e'.
  defp normalize_float(tok) do
    tok
    |> ensure_leading_digit()
    |> String.replace(~r/\.([eE])/, ".0\\1")
    |> ensure_decimal_for_exp()
  end

  defp ensure_leading_digit("." <> _ = t), do: "0" <> t
  defp ensure_leading_digit("-." <> rest), do: "-0." <> rest
  defp ensure_leading_digit(t), do: t

  defp ensure_decimal_for_exp(t) do
    if String.contains?(t, ".") or not String.contains?(t, ["e", "E"]) do
      t
    else
      String.replace(t, ~r/([eE])/, ".0\\1", global: false)
    end
  end

  # arrays
  defp parse_array(<<?], rest::binary>>, []), do: {[], rest}

  defp parse_array(bin, acc) do
    {v, rest} = parse_value(bin)

    case ws(rest) do
      <<?,, more::binary>> -> parse_array(ws(more), [v | acc])
      <<?], more::binary>> -> {Enum.reverse([v | acc]), more}
      other -> raise ArgumentError, "expected ',' or ']' in JSON array, got #{inspect(binary_part(other, 0, min(8, byte_size(other))))}"
    end
  end

  # objects (string-keyed)
  defp parse_object(<<?}, rest::binary>>, []), do: {%{}, rest}

  defp parse_object(<<?", rest::binary>>, acc) do
    {key, rest} = parse_string(rest, [])

    case ws(rest) do
      <<?:, vrest::binary>> ->
        {v, rest2} = parse_value(ws(vrest))

        case ws(rest2) do
          <<?,, more::binary>> -> parse_object(ws(more), [{key, v} | acc])
          <<?}, more::binary>> -> {Map.new([{key, v} | acc]), more}
          other -> raise ArgumentError, "expected ',' or '}' in JSON object, got #{inspect(binary_part(other, 0, min(8, byte_size(other))))}"
        end

      other ->
        raise ArgumentError, "expected ':' in JSON object, got #{inspect(binary_part(other, 0, min(8, byte_size(other))))}"
    end
  end

  defp parse_object(bin, _acc), do: raise(ArgumentError, "expected string key in JSON object, got #{inspect(binary_part(bin, 0, min(8, byte_size(bin))))}")
end
