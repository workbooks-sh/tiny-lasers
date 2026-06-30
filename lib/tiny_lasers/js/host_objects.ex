defmodule TinyLasers.Js.HostObjects do
  @moduledoc """
  **Host-resident JS objects (externref ABI, handle realization).**

  A JS object is represented in the pair ABI as `[i32 handle, TYPES.object]` — the value slot holds an
  opaque i32 handle (high bit tagged) into a *host-side* table. Property access becomes a host import call
  (a native BEAM map read) instead of Porffor's linear-memory pointer-chase + 20-branch type dispatch
  (~3.26× on the production asm lane). The pair ABI is otherwise untouched.

  Per-handle entry: `%{e: %{hash => {value, type}}, order: [hash, …], keys: %{hash => key_string}}`.
  - `e` — fast hash-keyed value/type store (the hot read path; perf-critical, stays O(1)).
  - `order` + `keys` — insertion-ordered original key strings, captured by `ho_regkey` (reads the Porffor
    string out of guest memory), so enumeration (Object.keys/for-in/JSON/spread) can recover real keys.

  ## Import surface (single-value returns)
    ho_new()                              -> i32 tagged handle
    ho_set(handle, hash, value, type)     -> (void)         # value/type at hash (hot)
    ho_regkey(handle, hash, keyPtr, keyType) -> (void)      # register the original key for enumeration
    ho_get_value/get_type(handle, hash)   -> f64 / i32
    ho_has(handle, hash)                  -> i32
    ho_delete(handle, hash)               -> i32
    ho_count(handle)                      -> i32            # number of own keys (enumeration)
    ho_key_at(handle, idx, bufPtr)        -> i32 len        # write idx-th key as a Porffor bytestring @ bufPtr

  Install with `Process.put(:tl_imports, Map.merge(existing, TinyLasers.Js.HostObjects.imports()))`.
  """

  import Bitwise

  @tbl :tl_ho_tbl
  @next :tl_ho_next

  @t_undefined 0
  @t_bytestring 195

  # Handle tag bit (must match codegen HOST_OBJ_TAG): a TYPES.object value with bit 31 set is a host handle.
  @tag 0x80000000
  @mask 0x7FFFFFFF
  @doc "The handle tag bit (must match the codegen's HOST_OBJ_TAG)."
  def tag, do: @tag

  @doc "The `ho_*` host-import closures to merge into `:tl_imports`."
  def imports do
    %{
      "ho_new" => fn [] -> ho_new() end,
      "ho_set" => fn [h, hash, value, type] -> ho_set(h, hash, value, type) end,
      "ho_regkey" => fn [h, hash, key_ptr, key_type] -> ho_regkey(h, hash, key_ptr, key_type) end,
      "ho_get_value" => fn [h, hash] -> ho_get_value(h, hash) end,
      "ho_get_type" => fn [h, hash] -> ho_get_type(h, hash) end,
      "ho_has" => fn [h, hash] -> ho_has(h, hash) end,
      "ho_delete" => fn [h, hash] -> ho_delete(h, hash) end,
      "ho_count" => fn [h] -> ho_count(h) end,
      "ho_key_at" => fn [h, idx, buf_ptr] -> ho_key_at(h, idx, buf_ptr) end
    }
  end

  @doc "Reset the per-run object table."
  def reset do
    Process.delete(@tbl)
    Process.delete(@next)
    :ok
  end

  @doc "The ordered own-key strings of a handle (host-side introspection / tests)."
  def keys(h) do
    obj = get_obj(h)
    Enum.map(obj.order, &Map.get(obj.keys, &1))
  end

  # ── handle allocation ───────────────────────────────────────────────────────────────────────────
  defp ho_new do
    tbl = Process.get(@tbl, %{})
    h = Process.get(@next, 1)
    Process.put(@tbl, Map.put(tbl, h, %{e: %{}, order: [], keys: %{}}))
    Process.put(@next, h + 1)
    bor(h, @tag)
  end

  defp untag(h), do: band(trunc(h), @mask)
  defp get_obj(h), do: Process.get(@tbl, %{}) |> Map.get(untag(h), %{e: %{}, order: [], keys: %{}})
  defp put_obj(h, obj), do: Process.put(@tbl, Map.put(Process.get(@tbl, %{}), untag(h), obj))

  # ── value/type store (hot path) ─────────────────────────────────────────────────────────────────
  defp ho_set(h, hash, value, type) do
    hash = trunc(hash)
    obj = get_obj(h)
    order = if Map.has_key?(obj.e, hash), do: obj.order, else: obj.order ++ [hash]
    put_obj(h, %{obj | e: Map.put(obj.e, hash, {value / 1, trunc(type)}), order: order})
    nil
  end

  # ── key registration for enumeration (reads the Porffor string out of guest memory) ─────────────
  # store just the key STRING for hash; `order` is owned by ho_set (always called first, on the hot path),
  # so ho_regkey must not append or we'd double-count.
  defp ho_regkey(h, hash, key_ptr, key_type) do
    hash = trunc(hash)
    key = read_porffor_str(trunc(key_ptr), trunc(key_type))
    obj = get_obj(h)
    put_obj(h, %{obj | keys: Map.put(obj.keys, hash, key)})
    nil
  end

  defp ho_get_value(h, hash) do
    case Map.get(get_obj(h).e, trunc(hash)) do
      {value, _type} -> value
      nil -> 0.0
    end
  end

  defp ho_get_type(h, hash) do
    case Map.get(get_obj(h).e, trunc(hash)) do
      {_value, type} -> type
      nil -> @t_undefined
    end
  end

  defp ho_has(h, hash), do: if(Map.has_key?(get_obj(h).e, trunc(hash)), do: 1, else: 0)

  defp ho_delete(h, hash) do
    hash = trunc(hash)
    obj = get_obj(h)
    put_obj(h, %{
      obj
      | e: Map.delete(obj.e, hash),
        keys: Map.delete(obj.keys, hash),
        order: List.delete(obj.order, hash)
    })
    1
  end

  defp ho_count(h), do: length(get_obj(h).order)

  # write the idx-th own key as a Porffor bytestring (i32 length prefix + Latin1 bytes) at buf_ptr;
  # return the char count. The guest builtin pre-allocates buf_ptr with enough room.
  defp ho_key_at(h, idx, buf_ptr) do
    obj = get_obj(h)
    hash = Enum.at(obj.order, trunc(idx))
    key = Map.get(obj.keys, hash, "")
    mem = Process.get(:tl_mem)
    buf = trunc(buf_ptr)
    write_u32(mem, buf, byte_size(key))
    TinyLasers.Wasm.write_bytes(mem, buf + 4, key)
    byte_size(key)
  end

  # ── Porffor string reader (mirrors wrap.js porfToJSValue): u32 length @ ptr, chars @ ptr+4. ─────
  # bytestring (type parity bit set, e.g. 195) = 1 Latin1 byte/char; string (67) = 2 UTF-16LE bytes/char.
  defp read_porffor_str(ptr, type) do
    mem = Process.get(:tl_mem)
    len = read_u32(mem, ptr)

    if band(type, 0x80) != 0 or type == @t_bytestring do
      TinyLasers.Wasm.read_bytes(mem, ptr + 4, len)
    else
      bytes = TinyLasers.Wasm.read_bytes(mem, ptr + 4, len * 2)
      :unicode.characters_to_binary(bytes, {:utf16, :little})
    end
  end

  defp read_u32(mem, addr) do
    <<v::little-32>> = TinyLasers.Wasm.read_bytes(mem, addr, 4)
    v
  end

  defp write_u32(mem, addr, v), do: TinyLasers.Wasm.write_bytes(mem, addr, <<v::little-32>>)
end
