defmodule TinyLasers.Gate.F2RollupMultiTest do
  @moduledoc """
  **F2 rung: rollup bundles a MULTI-MODULE graph byte-identical to node, BEAM-native, confined.**

  Four virtual ES modules with a 3-deep import chain (`entry → lib → util`, plus `meta`) drive the real
  bundle's cross-module machinery: import resolution through the plugin, per-module parse via the wasm
  bridge, module-graph linking, CROSS-MODULE treeshaking (every module carries dead exports that must
  vanish), scope hoisting into one chunk in execution order, and export generation. The driver
  (`multi_driver.js`) is appended after the bundle's own single-module driver — both run; this test asserts
  the MULTI_OK line against the golden captured from real rollup@4.62.2 under node.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Lower, Runtime}

  @conf "test/conformance"

  @tag timeout: 600_000
  test "rollup bundles a 4-module graph byte-identical to the golden, BEAM-native, confined" do
    prelude = File.read!(Path.join(@conf, "porffor_cjs/cjs_prelude.js")) <> "\n" <> File.read!(Path.join(@conf, "rollup/node_shims.js"))
    console = "var console = { log: function(){ print(arguments[0]); } };\n"
    bundle = File.read!(Path.join(@conf, "rollup/rollup_bundle.cjs"))
    driver = File.read!(Path.join(@conf, "rollup/multi_driver.js"))

    nmods = System.schedulers_online()

    %{main: mainq, siblings: sibqs} =
      Lower.modules_quoted(Js.parse(console <> prelude <> bundle <> "\n" <> driver), %{"print" => 0, "__host" => 1}, modules: nmods)

    uid = System.unique_integer([:positive])

    mods =
      [{:main, mainq} | Enum.with_index(sibqs) |> Enum.map(fn {q, i} -> {:"sib#{i}", q} end)]
      |> Task.async_stream(
        fn {tag, q} ->
          mod = Module.concat([TinyLasers.Gate.Guest, "RollupMulti#{uid}#{tag}"])
          [{m, bin} | _] = Code.compile_quoted(quote do (defmodule unquote(mod) do unquote(q) end) end)
          {tag, m, bin}
        end,
        timeout: 600_000, max_concurrency: nmods
      )
      |> Enum.map(fn {:ok, r} -> r end)

    for {tag, _, bin} <- mods do
      assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin), "module #{tag} not confined"
    end

    {:main, main, _} = List.keyfind(mods, :main, 0)
    Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}, 1 => %{fun: &Runtime.host_rollup_bridge/2}}, tenant_root: "/t", fs: %{}})
    for {tag, m, _} <- mods, tag != :main, do: apply(m, :__gg_register, [])
    try do apply(main, :run, []) catch :throw, _ -> :ok end
    out = Runtime.__output()

    ok_line = Enum.find(out, &String.starts_with?(&1, "MULTI_OK["))
    assert ok_line, "rollup did not produce MULTI_OK; output=#{inspect(Enum.take(out, 10))}"

    code = ok_line |> String.replace_prefix("MULTI_OK[", "") |> String.replace_suffix("]", "")
    golden = File.read!(Path.join(@conf, "rollup/rollup_multi_golden.js"))
    assert String.trim(code) == String.trim(golden), "multi bundle mismatch:\n  got=#{inspect(code)}\n  want=#{inspect(golden)}"

    # the bundle's own single-module driver also ran — its golden must still hold in the same process.
    single = Enum.find(out, &String.starts_with?(&1, "BUNDLE_OK["))
    assert single, "single-module driver silently broke; output=#{inspect(Enum.take(out, 10))}"
  end
end
