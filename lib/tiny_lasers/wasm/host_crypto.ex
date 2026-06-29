defmodule TinyLasers.Wasm.HostCrypto do
  @moduledoc """
  The `crypto` concern (Node Wave-1, wb-5i2i) — a whole Node core module added as pure Elixir (`call/2`) +
  pure JS (`node/56_crypto.js`), touching NO shared file (no `harness_run.c`, no `wasm.ex`). Mirrors the
  shape of the reference `TinyLasers.Wasm.HostFs`. Backed by Erlang's `:crypto` (BoringSSL/OpenSSL), so there is
  no hand-rolled hashing. Binary data crosses the bridge base64-encoded (JSON-safe), exactly like host_fs.ex.

  Routed here by `TinyLasers.Wasm.HostIO` because the import name is `crypto_*` (prefix `crypto` → this module).
  All ops are synchronous CPU work, so `crypto` rides the SYNC bridge (`__host`); the JS shim defers any
  callback form to a microtask.
  """

  @algos %{"sha256" => :sha256, "sha1" => :sha1, "sha512" => :sha512, "md5" => :md5}
  @max_random 65_536

  @doc "Handle one `crypto_*` host call. `args` is the decoded JSON list; returns a JSON-able result map."
  def call("crypto_hash", [algo, data_b64]) do
    with {:ok, a} <- algo(algo) do
      %{"digest" => Base.encode64(:crypto.hash(a, Base.decode64!(data_b64)))}
    end
  end

  def call("crypto_hmac", [algo, key_b64, data_b64]) do
    with {:ok, a} <- algo(algo) do
      mac = :crypto.mac(:hmac, a, Base.decode64!(key_b64), Base.decode64!(data_b64))
      %{"digest" => Base.encode64(mac)}
    end
  end

  def call("crypto_random", [n]) do
    bytes = :crypto.strong_rand_bytes(clamp(n))
    %{"b64" => Base.encode64(bytes)}
  end

  def call("crypto_uuid", []) do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    # set version (4) and variant (RFC 4122) bits
    <<u::128>> = <<a::48, 4::4, b::12, 2::2, c::62>>
    hex = u |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(32, "0")
    <<t1::binary-8, t2::binary-4, t3::binary-4, t4::binary-4, t5::binary-12>> = hex
    %{"uuid" => "#{t1}-#{t2}-#{t3}-#{t4}-#{t5}"}
  end

  defp algo(name) do
    case Map.fetch(@algos, to_string(name)) do
      {:ok, a} -> {:ok, a}
      :error -> %{"err" => "unknown algo"}
    end
  end

  defp clamp(n) when is_integer(n) and n > 0, do: min(n, @max_random)
  defp clamp(_), do: 0
end
