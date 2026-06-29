defmodule TinyLasers.Js.PorfforHost do
  @moduledoc """
  **The Porffor↔host call bridge** — the missing memory-exchange seam that lets a Porffor-compiled JS
  program call back into the Elixir host (and, through it, into sibling TinyLasers.Wasm modules like the Rollup
  parser). This is the Porffor analogue of `TinyLasers.Wasm.HostRollup` for QuickJS.

  ## The ABI (raw linear-memory exchange, all params f64)
  Porffor registers ONE host import, `__host_call`, assigned the next single-char wasm import name by
  `createImport` order (after a/b/c/d → **`e`**). Its wasm shape is:

      __host_call(opPtr, opLen, reqPtr, reqLen, resPtr, resCap) -> resLen

    * `opPtr,opLen`   — bytes of the operation name (e.g. "echo_upper", "rollup_parse") in guest memory.
    * `reqPtr,reqLen` — bytes of the request payload in guest memory (for rollup: the JS source).
    * `resPtr,resCap` — a CALLER-allocated result region (the guest `Porffor.malloc`s it) the host writes
      into; `resCap` bounds the write.
    * returns `resLen` — number of bytes written to `resPtr`, or `-1` on overflow / unknown op.

  The guest-side marshalling helper (`hostCall(op, req)` in the program prelude, written in Porffor's
  annotated-JS `Porffor.wasm` dialect) extracts bytestring base pointers (`+4`, past the i32 length
  prefix), mallocs the result region, calls the import, then reads the `resLen` result bytes back out of
  ITS OWN linear memory. No values cross the wasm boundary except integers — strings/buffers stay in
  memory and are exchanged by region, exactly like wasm-bindgen.

  ## Memory access from a TinyLasers.Wasm import (the crux)
  A `:tl_imports` handler runs SYNCHRONOUSLY inside the guest's run process while `m` is executing, so
  the live linear memory is reachable as `Process.get(:tl_mem)` (an `:atomics` ref set up by
  `TinyLasers.Wasm.call_io` before the invoke). `TinyLasers.Wasm.read_bytes/3` and `write_bytes/3` operate on it
  — the very same pattern `HostRollup` uses inside QuickJS. So the host CAN read the request region and
  write the result region of the running module directly.
  """

  alias TinyLasers.Wasm

  @doc """
  The `e` import handler. Receives the 6 f64 args (pointers/lengths as floats), reads the op + request
  out of guest memory, dispatches, writes the result back into the caller's region, returns the byte
  count written (as a float, the Porffor valtype) — or `-1.0` on overflow / unknown op.
  """
  def host_call([op_ptr, op_len, req_ptr, req_len, res_ptr, res_cap]) do
    mem = Process.get(:tl_mem)
    op = TinyLasers.Wasm.read_bytes(mem, t(op_ptr), t(op_len))
    req = TinyLasers.Wasm.read_bytes(mem, t(req_ptr), t(req_len))

    case dispatch(op, req) do
      {:ok, result} when is_binary(result) ->
        if byte_size(result) > t(res_cap) do
          -1.0
        else
          TinyLasers.Wasm.write_bytes(Process.get(:tl_mem), t(res_ptr), result)
          byte_size(result) * 1.0
        end

      :error ->
        -1.0
    end
  end

  # ── operations ───────────────────────────────────────────────────────────────────────────────────

  # Prototype op: prove string-out + buffer-back through real linear memory. Uppercase the request bytes.
  defp dispatch("echo_upper", req), do: {:ok, String.upcase(req)}

  # Raw byte echo (the request bytes straight back) — proves the buffer-back path with no transform.
  defp dispatch("echo", req), do: {:ok, req}

  # The rollup ops (rollup_parse / rollup_parse_b64 / rollup_xxhash_*) route to a Rust-parser WASM module
  # via the (not-yet-migrated) HostRollup bridge. Stubbed to :error for now — the live-compile lane needs
  # only echo, and a guest that needs rollup_parse fails loudly rather than crashing the host. Un-stub by
  # bringing HostRollup over (the rollup conformance chunk).
  defp dispatch(_unknown, _req), do: :error

  # Porffor passes pointers/lengths as f64; truncate to integer addresses.
  defp t(v) when is_float(v), do: trunc(v)
  defp t(v) when is_integer(v), do: v
end
