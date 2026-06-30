defmodule TinyLasers.PorfforBrtableTest do
  @moduledoc """
  **`--typeswitch-brtable` conformance on the real production lane.**

  Porffor's `--typeswitch-brtable` lowers type-tag dispatch (member access, `typeof`, …) to a `br_table`
  instead of a ~20-branch if-chain. The correct gate for this is NOT `wasm-tools validate` — clean upstream
  Porffor emits modules that the strict validator rejects (benign builtin type-tag-on-value-stack quirk) yet
  the BEAM asm lane executes correctly. So we gate where it counts: **brtable output must oracle-match the
  if-chain output through `call_io`**, byte-for-byte on the [type, value] pair.

  Strings are reduced to a NUMERIC fingerprint in-JS (`length*1e6 + rolling-hash`) so we compare CONTENT,
  never the heap pointer (which legitimately differs because brtable changes data-section layout).
  """
  use ExUnit.Case, async: true

  alias TinyLasers.Wasm

  @root "compilers"

  # Wrap a body expr so a string result collapses to a number (content hash), pointers never leak.
  def fp(body) do
    "function f(o){ var r = (#{body}); " <>
      "if (typeof r === 'string'){ var s = 0; for (var i = 0; i < r.length; i++) s = (s * 31 + r.charCodeAt(i)) | 0; " <>
      "return r.length * 1000000 + (s < 0 ? -s : s); } " <>
      "if (typeof r === 'boolean') return r ? 1 : 0; return r; }"
  end

  defp run(src, flags) do
    {:ok, wasm} = TinyLasers.Js.Porffor.compile(src, @root, [skip_invariants: true] ++ flags)
    {:ok, mod} = Wasm.decode(wasm)
    {r, _io} = Wasm.call_io(mod, "m", [], transpile: true, fuel: 500_000_000, max_pages: 16_384)
    r
  end

  # {name, body-expr, call-site}
  @cases [
    {"num prop", "o.x", "f({x: 42});"},
    {"str len", "o.s.length", "f({s:'hello'});"},
    {"arr idx", "o.a[1]", "f({a:[10,20,30]});"},
    {"nested prop", "o.a.b", "f({a:{b:7}});"},
    {"mixed add", "o.x + o.y", "f({x:3,y:4});"},
    {"typeof obj", "typeof o", "f({x:1});"},
    {"typeof num", "typeof o.x", "f({x:1});"},
    {"str concat", "o.name + '!'", "f({name:'hi'});"},
    {"bool cmp", "o.x > 5", "f({x:9});"}
  ]

  for {name, body, call} <- @cases do
    test "brtable oracle-matches if-chain: #{name}" do
      src = unquote(__MODULE__).fp(unquote(body)) <> " " <> unquote(call)
      ifchain = run(src, [])
      brtable = run(src, flags: ["--typeswitch-brtable"])
      assert ifchain == brtable
    end
  end
end
