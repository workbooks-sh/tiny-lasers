defmodule TinyLasers.WasmJsonTest do
  @moduledoc """
  The zero-dep JSON codec that carries the JS↔BEAM bridge payloads. Proves encode/decode round-trip
  the restricted bridge shape exactly — integers stay exact, floats round-trip, strings survive full
  escaping incl. `\\uXXXX` and surrogate pairs, and it parses what `JSON.stringify` emits.
  """
  use ExUnit.Case, async: true

  alias TinyLasers.Wasm.Json

  defp rt(v), do: v |> Json.encode!() |> Json.decode!()

  test "scalars round-trip with exact types" do
    assert rt(nil) == nil
    assert rt(true) == true
    assert rt(false) == false
    assert rt(0) == 0
    assert rt(42) == 42
    assert rt(-7) == -7
    # integers stay integers (never coerced to float)
    assert Json.encode!(5) == "5"
    assert Json.decode!("5") === 5
  end

  test "floats round-trip and parse JS-style forms" do
    assert rt(1.5) == 1.5
    assert rt(0.30000000000000004) == 0.30000000000000004
    assert rt(-2.5) == -2.5
    assert Json.decode!("1e3") == 1000.0
    assert Json.decode!("1.5e2") == 150.0
    assert Json.decode!("-0.5") == -0.5
  end

  test "strings: escaping round-trips" do
    assert rt("hello") == "hello"
    assert rt(~s(quote " and \\ backslash)) == ~s(quote " and \\ backslash)
    assert rt("tab\tnewline\nreturn\r") == "tab\tnewline\nreturn\r"
    assert rt("") == ""
    # control char encodes as \uXXXX
    assert Json.encode!(<<1>>) == "\"\\u0001\""
    assert Json.decode!("\"\\u0001\"") == <<1>>
  end

  test "unicode: \\uXXXX and surrogate pairs decode to UTF-8" do
    # BMP: é = U+00E9
    assert Json.decode!(~s("\\u00e9")) == "é"
    # astral via surrogate pair: 😀 = U+1F600 → 😀
    assert Json.decode!(~s("\\ud83d\\ude00")) == "😀"
    # raw UTF-8 passes through encode untouched and round-trips
    assert rt("café 😀") == "café 😀"
  end

  test "arrays and objects nest and round-trip" do
    assert rt([1, 2, 3]) == [1, 2, 3]
    assert rt([]) == []
    assert rt(%{"a" => 1, "b" => [2, 3]}) == %{"a" => 1, "b" => [2, 3]}
    assert rt(%{}) == %{}
    assert rt(%{"nested" => %{"x" => [true, nil, "s"]}}) == %{"nested" => %{"x" => [true, nil, "s"]}}
  end

  test "parses real JSON.stringify output shapes (whitespace tolerant)" do
    assert Json.decode!(~s({"a": [1, 2], "b": "x"})) == %{"a" => [1, 2], "b" => "x"}
    assert Json.decode!(~s(  [ 1 , 2 , 3 ] )) == [1, 2, 3]
    assert Json.decode!(~s({"k":{"deep":true}})) == %{"k" => %{"deep" => true}}
  end

  test "malformed input raises (loud, not silently wrong)" do
    assert_raise ArgumentError, fn -> Json.decode!("{bad}") end
    assert_raise ArgumentError, fn -> Json.decode!("[1,2") end
    assert_raise ArgumentError, fn -> Json.decode!(~s("unterminated)) end
    assert_raise ArgumentError, fn -> Json.decode!("1 2") end
  end
end
