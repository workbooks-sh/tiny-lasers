defmodule TinyLasers.Gate.Parser do
  @moduledoc """
  Tiny string -> guest-AST parser for the `eval` red-team. A real frontend parses
  full JS; this covers exactly enough to express the attacks (numbers, strings,
  identifiers, member access `a.b`, calls `f(x, y)`, and `+ - *`).

  Crucially: guest identifiers become `{:var, binary}` (never atoms), and operators
  map to a FIXED atom set chosen by us (`:+`/`:-`/`:*`) — never `String.to_atom` on
  guest data. So parsing arbitrary guest source creates no new atoms.
  """

  @doc "Parse source to a guest AST. Raises on malformed input (caller turns it into a guest error)."
  def parse(src) when is_binary(src) do
    toks = tokenize(src, [])
    {ast, rest} = expr(toks)

    case rest do
      [] -> ast
      _ -> throw({:gg_parse, "trailing tokens"})
    end
  end

  # ── tokenizer ──
  defp tokenize("", acc), do: Enum.reverse(acc)
  defp tokenize(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\n, ?\r], do: tokenize(rest, acc)

  defp tokenize(<<c, _::binary>> = s, acc) when c in ?0..?9 do
    {num, rest} = take_while(s, fn ch -> ch in ?0..?9 or ch == ?. end)
    tokenize(rest, [{:num, String.to_float(ensure_float(num))} | acc])
  end

  defp tokenize(<<q, rest::binary>>, acc) when q in [?", ?'] do
    {str, rest2} = take_string(rest, q, "")
    tokenize(rest2, [{:str, str} | acc])
  end

  defp tokenize(<<c, _::binary>> = s, acc) when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {id, rest} = take_while(s, fn ch -> ch in ?a..?z or ch in ?A..?Z or ch in ?0..?9 or ch == ?_ end)
    tokenize(rest, [{:id, id} | acc])
  end

  defp tokenize(<<c, rest::binary>>, acc) when c in [?(, ?), ?., ?,, ?+, ?-, ?*] do
    tokenize(rest, [{:punct, <<c>>} | acc])
  end

  defp tokenize(<<c, _::binary>>, _acc), do: throw({:gg_parse, "bad char #{<<c>>}"})

  defp take_while(bin, pred), do: take_while(bin, pred, "")
  defp take_while(<<c, rest::binary>>, pred, acc) do
    if pred.(c), do: take_while(rest, pred, acc <> <<c>>), else: {acc, <<c, rest::binary>>}
  end
  defp take_while("", _pred, acc), do: {acc, ""}

  defp take_string(<<q, rest::binary>>, q, acc), do: {acc, rest}
  defp take_string(<<?\\, c, rest::binary>>, q, acc), do: take_string(rest, q, acc <> <<c>>)
  defp take_string(<<c, rest::binary>>, q, acc), do: take_string(rest, q, acc <> <<c>>)
  defp take_string("", _q, _acc), do: throw({:gg_parse, "unterminated string"})

  defp ensure_float(s), do: if(String.contains?(s, "."), do: s, else: s <> ".0")

  # ── recursive-descent parser (additive -> multiplicative -> postfix -> primary) ──
  defp expr(toks), do: additive(toks)

  defp additive(toks) do
    {left, rest} = multiplicative(toks)
    additive_loop(left, rest)
  end

  defp additive_loop(left, [{:punct, op} | rest]) when op in ["+", "-"] do
    {right, rest2} = multiplicative(rest)
    additive_loop({:binop, op_atom(op), left, right}, rest2)
  end

  defp additive_loop(left, rest), do: {left, rest}

  defp multiplicative(toks) do
    {left, rest} = postfix(toks)
    multiplicative_loop(left, rest)
  end

  defp multiplicative_loop(left, [{:punct, "*"} | rest]) do
    {right, rest2} = postfix(rest)
    multiplicative_loop({:binop, :*, left, right}, rest2)
  end

  defp multiplicative_loop(left, rest), do: {left, rest}

  defp postfix(toks) do
    {prim, rest} = primary(toks)
    postfix_loop(prim, rest)
  end

  defp postfix_loop(e, [{:punct, "."}, {:id, name} | rest]) do
    postfix_loop({:get, e, {:lit, name}}, rest)
  end

  defp postfix_loop(e, [{:punct, "("} | rest]) do
    {args, rest2} = call_args(rest, [])
    postfix_loop({:call, e, args}, rest2)
  end

  defp postfix_loop(e, rest), do: {e, rest}

  defp call_args([{:punct, ")"} | rest], acc), do: {Enum.reverse(acc), rest}

  defp call_args(toks, acc) do
    {arg, rest} = expr(toks)

    case rest do
      [{:punct, ","} | rest2] -> call_args(rest2, [arg | acc])
      [{:punct, ")"} | rest2] -> {Enum.reverse([arg | acc]), rest2}
      _ -> throw({:gg_parse, "bad call args"})
    end
  end

  defp primary([{:num, n} | rest]), do: {{:lit, n}, rest}
  defp primary([{:str, s} | rest]), do: {{:lit, s}, rest}
  defp primary([{:id, id} | rest]), do: {{:var, id}, rest}

  defp primary([{:punct, "("} | rest]) do
    {e, rest2} = expr(rest)

    case rest2 do
      [{:punct, ")"} | rest3] -> {e, rest3}
      _ -> throw({:gg_parse, "expected )"})
    end
  end

  defp primary(_), do: throw({:gg_parse, "unexpected token"})

  # fixed operator set — never String.to_atom on guest data
  defp op_atom("+"), do: :+
  defp op_atom("-"), do: :-
end
