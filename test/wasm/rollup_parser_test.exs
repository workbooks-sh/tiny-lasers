defmodule TinyLasers.WasmRollupParserTest do
  @moduledoc """
  **Rollup's Rust wasm parser runs on TinyLasers.Wasm — byte-identical to native @rollup/wasm-node.**

  Proves the keystone for running Rollup/Vite JavaScript on the Porffor lane: load the real wasm-bindgen
  Rust parser, satisfy its glue imports, drive `parse()`, and compare the AST buffer to the native golden.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Wasm

  @dir Path.join(__DIR__, "../conformance/rollup")

  setup_all do
    wasm = Path.join(@dir, "rollup_parser.wasm")

    if File.regular?(wasm),
      do: :ok,
      else: {:skip, "rollup_parser.wasm absent — copy from nexus/test/conformance/rollup/"}
  end

  test "Rollup Rust wasm parser AST byte-identical to native @rollup/wasm-node" do
    wasm = Path.join(@dir, "rollup_parser.wasm")
    {:ok, mod} = Wasm.decode(File.read!(wasm))

    rs = fn ptr, len -> Wasm.read_bytes(Process.get(:tl_mem), ptr, len) end

    imports =
      mod.imports
      |> Enum.map(fn {_m, n, _t} -> n end)
      |> Map.new(fn n ->
        fun =
          cond do
            String.contains?(n, "throw") -> fn [p, l] -> raise("guest __wbindgen_throw: " <> rs.(p, l)) end
            String.contains?(n, "length") -> fn [_a] -> 0 end
            String.contains?(n, "new_") -> fn [] -> 1 end
            String.contains?(n, "prototypesetcall") -> fn [_a, _b, _c] -> nil end
            true -> fn _ -> nil end
          end

        {n, fun}
      end)

    Process.put(:tl_imports, imports)

    code = File.read!(Path.join(@dir, "rollup_parse_input.js"))
    golden = File.read!(Path.join(@dir, "rollup_parser_golden.bin"))
    clen = byte_size(code)

    {:ok, inst, _} = Wasm.instance_start(mod, "__wbindgen_add_to_stack_pointer", [0])

    {:ok, retptr, _, inst} = Wasm.instance_invoke(inst, "__wbindgen_add_to_stack_pointer", [-16])
    {:ok, ptr, _, inst} = Wasm.instance_invoke(inst, "__wbindgen_export2", [clen, 1])
    Wasm.write_bytes(inst.mem, ptr, code)
    {:ok, _r, _o, inst} = Wasm.instance_invoke(inst, "parse", [retptr, ptr, clen, 0, 0])

    r0 = Wasm.read_bytes(inst.mem, retptr, 4) |> :binary.decode_unsigned(:little)
    r1 = Wasm.read_bytes(inst.mem, retptr + 4, 4) |> :binary.decode_unsigned(:little)
    assert r0 > 0 and r1 > 0, "parse must return a non-empty AST buffer, got {#{r0}, #{r1}}"

    ast = Wasm.read_bytes(inst.mem, r0, r1)

    assert ast == golden,
           "TinyLasers.Wasm Rollup-parser AST (#{byte_size(ast)}B) must be byte-identical to native node's (#{byte_size(golden)}B)"
  end
end
