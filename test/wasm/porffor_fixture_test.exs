defmodule TinyLasers.WasmPorfforFixtureTest do
  @moduledoc """
  **The goal proof: real Porffor-compiled JS runs byte-identical on TinyLasers.Wasm.**

  tiny-lasers owns the WASM→BEAM runtime; the Porffor JS→WASM compiler stays in nexus. These
  fixtures are `.wasm` modules Porffor emitted for representative JS programs (arithmetic,
  loops, array/string methods, JSON, destructuring, classes/super), checked in as bytes. We
  decode and run each on `TinyLasers.Wasm`'s transpile lane — the shipping path — providing
  the exact `print`/`printChar`/`time` host imports the nexus lane provides, and assert the
  captured stdout matches the node reference. A green run means the runtime executes real
  Porffor output identically to nexus ≡ node, with NO compiler dependency in tiny-lasers.

  Regenerate fixtures:  `cd nexus && mix run ../tiny-lasers/tools/gen_porffor_fixtures.exs`
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Wasm

  @fixtures_dir Path.expand(Path.join(__DIR__, "../fixtures/porffor"))

  # {fixture name, node-reference stdout}. Same node-verified pairs the nexus Porffor→Washy
  # lane asserts in washy_porffor_test.exs; the generator confirms each is node-identical on
  # the nexus lane before writing its .wasm, so tiny-lasers byte-match ⇒ runtime ≡ nexus ≡ node.
  @cases [
    # AOT-friendly subset
    {"arith_loops", "999000"},
    {"pow_underscore", "2024"},
    {"labeled_switch", "12"},
    {"array_methods", "10"},
    {"string_methods", "hello"},
    {"json_stringify", ~s|{"a":[1,2],"b":"x"}|},
    {"json_parse", "5"},
    {"destructuring", "9"},
    {"class_super", "2"},
    # The hard surface rollup/vite exercise
    {"closure_counter", "6"},
    {"closure_loop_capture", "0,1,2"},
    {"regex_replace_g", "a#b#c#"},
    {"regex_match_groups", "2026/06/29"},
    {"bigint", "123456789012345678901234567891"},
    {"number_float_repr", "0.30000000000000004"},
    {"number_toFixed", "1234.57"},
    {"map_keys", "ab2"},
    {"set_dedup", "1,2,3"},
    {"template_literal", "val=10!"},
    {"spread_rest", "10"},
    {"try_catch_type", "caught true"},
    {"typed_array", "13"},
    {"sort_numeric", "1,2,3,10"},
    {"optional_chain", "5/none"},
    {"string_pad", "005"},
    # Bundler-class compute (rollup's workload shape, self-contained)
    {"mini_bundler", "d,b,c,a|4|113"}
  ]

  setup_all do
    if File.dir?(@fixtures_dir) and File.ls!(@fixtures_dir) != [] do
      :ok
    else
      {:skip, "porffor fixtures absent — run tools/gen_porffor_fixtures.exs from nexus"}
    end
  end

  for {name, want} <- @cases do
    @name name
    @want want
    # A case whose fixture is absent is a *nexus-lane* gap (the generator only writes programs
    # proven node-identical on the nexus Porffor→Washy lane) — skip it, don't fail. A fixture
    # that's PRESENT but mismatches IS a real tiny-lasers runtime gap and must fail loudly.
    if File.regular?(Path.join(@fixtures_dir, name <> ".wasm")) do
      test "porffor JS→wasm byte-identical on TinyLasers.Wasm: #{name}" do
        got =
          Path.join(@fixtures_dir, @name <> ".wasm")
          |> File.read!()
          |> run_porffor()
          |> String.replace(~r/\e\[[0-9;]*m/, "")
          |> String.trim()

        assert got == @want, "#{@name}: got=#{inspect(got)} want=#{inspect(@want)}"
      end
    else
      @tag :skip
      test "porffor JS→wasm (no fixture — nexus-lane gap): #{name}" do
        :ok
      end
    end
  end

  # Mirror nexus's Porffor.run/2: provide print(a)/printChar(b)/time(c)/timeOrigin(d), capture
  # print/printChar into a stdout buffer, invoke the exported `m` on the transpile lane.
  defp run_porffor(wasm) do
    {:ok, mod} = Wasm.decode(wasm)
    Process.put(:porffor_out, [])
    emit = fn s -> Process.put(:porffor_out, [s | Process.get(:porffor_out, [])]) end

    imports = %{
      "a" => fn [v] -> emit.(num_to_string(v)); nil end,
      "b" => fn [v] -> emit.(<<trunc(v)::utf8>>); nil end,
      "c" => fn [] -> 0.0 end,
      "d" => fn [] -> 0.0 end
    }

    Process.put(:tl_imports, imports)
    {:ok, _inst, _} = Wasm.instance_start(mod, "m", [], transpile: true)
    Process.get(:porffor_out, []) |> Enum.reverse() |> IO.iodata_to_binary()
  end

  # JS Number#toString for the f64 handed to print. Non-finite is Washy's {:nonfinite, bits, size}.
  defp num_to_string({:nonfinite, bits, _size}) do
    cond do
      bits == 0x7FF0000000000000 -> "Infinity"
      bits == 0xFFF0000000000000 -> "-Infinity"
      true -> "NaN"
    end
  end

  defp num_to_string(v) when is_float(v) do
    if v == Float.round(v) and abs(v) < 9.007199254740992e15,
      do: Integer.to_string(trunc(v)),
      else: Float.to_string(v)
  end

  defp num_to_string(v), do: to_string(v)
end
