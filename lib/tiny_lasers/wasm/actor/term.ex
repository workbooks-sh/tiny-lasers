defmodule TinyLasers.Wasm.Actor.Term do
  @moduledoc """
  **The JS ⇄ Erlang term bridge for `Beam.*` messages.** Messages crossing the JS↔OTP boundary live in a
  restricted, JSON-equivalent term shape so a value is faithfully representable on BOTH sides:

      nil | boolean | number (int/float) | binary (string) | [term] | %{optional(binary) => term}

  `normalize/1` projects any Elixir term into this shape (the canonical wire form): atoms → strings
  (`true`/`false`/`nil` kept as themselves), tuples → lists, map keys → strings, charlists left as lists
  of ints. This is the EXACT shape the QuickJS side produces when it serializes a JS value (number ⇄
  number, string ⇄ string, array ⇄ list, plain object ⇄ string-keyed map) and reconstructs on the way
  in — so `normalize` is idempotent and a round-trip is bit-stable for any in-shape value.

  Why a structural mapping over raw JSON text: it keeps integers exact (no float coercion), avoids a
  parse/encode on every message, and the guest harness already has TextEncoder/Decoder to turn the
  reconstructed value into/out of JS. JSON-on-the-wire remains a drop-in alt (`to_json/1`) for a debug
  or a cross-host hop, but the in-VM path stays as terms.
  """

  @typedoc "A value in the shared JS⇄Erlang shape."
  @type t :: nil | boolean() | number() | binary() | [t] | %{optional(binary()) => t}

  @doc """
  Project an Elixir term into the shared JS-bridgeable shape. Idempotent: `normalize(normalize(x)) ==
  normalize(x)`. Raises on a genuinely un-bridgeable term (pid/ref/fun) so a bug surfaces loudly rather
  than silently shipping an opaque handle into a JS guest.
  """
  @spec normalize(term()) :: t
  def normalize(nil), do: nil
  def normalize(b) when is_boolean(b), do: b
  def normalize(n) when is_integer(n) or is_float(n), do: n
  def normalize(b) when is_binary(b), do: b
  def normalize(a) when is_atom(a), do: Atom.to_string(a)
  def normalize(l) when is_list(l), do: Enum.map(l, &normalize/1)
  def normalize(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.map(&normalize/1)

  def normalize(m) when is_map(m) do
    Map.new(m, fn {k, v} -> {key(k), normalize(v)} end)
  end

  def normalize(other) do
    raise ArgumentError, "Beam term not bridgeable to JS: #{inspect(other)}"
  end

  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k) when is_integer(k), do: Integer.to_string(k)
  defp key(k), do: raise(ArgumentError, "Beam map key not bridgeable: #{inspect(k)}")

  @doc "Encode a normalized term as JSON text (the cross-host / debug wire form)."
  @spec to_json(term()) :: binary()
  def to_json(term), do: term |> normalize() |> Jason.encode!()

  @doc "Decode JSON text from a guest into the shared term shape (string-keyed maps, lists, scalars)."
  @spec from_json(binary()) :: t
  def from_json(json), do: json |> Jason.decode!() |> normalize()
end
