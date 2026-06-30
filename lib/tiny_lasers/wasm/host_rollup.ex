defmodule TinyLasers.Wasm.HostRollup do
  @moduledoc """
  **The Porffor/QuickJS↔Rollup-parser bridge — Rust `@rollup/wasm-node` as a sibling TinyLasers.Wasm module.**

  Rollup 4's parser is a Rust→wasm module (`bindings_wasm_bg.wasm`). Guest JavaScript routes native
  `parse()` / `xxhash*()` here via `TinyLasers.Js.PorfforHost` (byte ABI) or `HostIO` (JSON ABI).

  The parser instance is created lazily on first call and cached in `:tl_rollup_parser`;
  `instance_invoke` snapshots/restores the caller's run context so invoking the parser mid-guest-run is safe.
  """
  import Bitwise
  alias TinyLasers.Wasm

  @parser_wasm Path.expand(
                 "test/conformance/rollup/rollup_parser.wasm",
                 Path.join([__DIR__, "..", "..", ".."])
               )

  @doc "sync `__host('rollup_parse', [code, allowReturn, jsx])` → %{\"ok\", \"b64\": base64(AST buffer)}."
  def call("rollup_parse", [code | rest]) do
    allow = Enum.at(rest, 0, false)
    jsx = Enum.at(rest, 1, false)
    inst = ensure_parser()
    {buf, inst} = do_parse(inst, to_string(code), bool(allow), bool(jsx))
    Process.put(:tl_rollup_parser, inst)
    %{"ok" => true, "b64" => Base.encode64(buf)}
  end

  def call("rollup_xxhash", [b64, kind]) do
    bytes = Base.decode64!(b64)
    h = :erlang.crc32(bytes) ||| (:erlang.phash2(bytes, 0xFFFFFFFF) <<< 32)
    %{"h" => render_hash(h, kind)}
  end

  defp bool(v), do: v == true or v == 1

  defp render_hash(h, "b16"),
    do:
      Integer.to_string(h, 16)
      |> String.downcase()
      |> String.pad_leading(16, "0")
      |> binary_part(0, 16)

  defp render_hash(h, "b36"),
    do:
      Integer.to_string(h, 36)
      |> String.downcase()
      |> String.pad_leading(12, "0")
      |> binary_part(0, 12)

  defp render_hash(h, _b64url) do
    <<h::64>> |> Base.url_encode64(padding: false) |> binary_part(0, 11)
  end

  defp ensure_parser do
    case Process.get(:tl_rollup_parser) do
      nil ->
        {:ok, mod} = Wasm.decode_cached(File.read!(@parser_wasm))
        Process.put(:tl_imports, Map.merge(Process.get(:tl_imports, %{}), parser_shims(mod)))
        {:ok, inst, _} = Wasm.instance_start(mod, "__wbindgen_add_to_stack_pointer", [0], transpile: true)
        inst

      inst ->
        inst
    end
  end

  defp parser_shims(mod) do
    rs = fn ptr, len -> Wasm.read_bytes(Process.get(:tl_mem), ptr, len) end

    mod.imports
    |> Enum.map(fn {_m, n, _t} -> n end)
    |> Map.new(fn n ->
      fun =
        cond do
          String.contains?(n, "throw") -> fn [p, l] -> raise("rollup parser __wbindgen_throw: " <> rs.(p, l)) end
          String.contains?(n, "length") -> fn [_a] -> 0 end
          String.contains?(n, "new_") -> fn [] -> 1 end
          String.contains?(n, "prototypesetcall") -> fn [_a, _b, _c] -> nil end
          true -> fn _ -> nil end
        end

      {n, fun}
    end)
  end

  defp do_parse(inst, code, allow, jsx) do
    clen = byte_size(code)
    {:ok, retptr, _, inst} = Wasm.instance_invoke(inst, "__wbindgen_add_to_stack_pointer", [-16])
    {:ok, ptr, _, inst} = Wasm.instance_invoke(inst, "__wbindgen_export2", [clen, 1])
    Wasm.write_bytes(inst.mem, ptr, code)
    a = if(allow, do: 1, else: 0)
    j = if(jsx, do: 1, else: 0)
    {:ok, _, _, inst} = Wasm.instance_invoke(inst, "parse", [retptr, ptr, clen, a, j])

    r0 = Wasm.read_bytes(inst.mem, retptr, 4) |> :binary.decode_unsigned(:little)
    r1 = Wasm.read_bytes(inst.mem, retptr + 4, 4) |> :binary.decode_unsigned(:little)
    buf = Wasm.read_bytes(inst.mem, r0, r1)
    {:ok, _, _, inst} = Wasm.instance_invoke(inst, "__wbindgen_add_to_stack_pointer", [16])
    {buf, inst}
  end
end
