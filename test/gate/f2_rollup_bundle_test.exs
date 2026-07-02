defmodule TinyLasers.Gate.F2RollupBundleTest do
  @moduledoc """
  **F2 conformance summit — the real rollup bundles a tiny input BEAM-native, byte-identical to node.**

  The unmodified `rollup_bundle.cjs` (rollup 4 + its Node host surface, ~1.27MB) is lowered ESTree→Elixir-quoted
  → a native `.beam` module (no WASM for the JS), loaded via the CJS prelude + Node shims. Its self-driver runs
  `rollup.rollup({input:"entry", plugins:[virt], treeshake:true}).then(b => b.generate({format:"cjs"}))` over a
  virtual module and prints `BUNDLE_OK[<code>]`. The generated code is compared to the golden captured from real
  node rollup.

  On-thesis convergence: rollup's JS orchestrates on BEAM; its Rust→wasm parser (`rollup_parser.wasm`) runs in
  the WASM sandbox (`TinyLasers.Wasm`) behind the confined `__host` capability (guest holds only the integer
  handle). Everything else — classes/super, async/await + Promises, arrow `this`, Map/Set, Symbol, typed arrays,
  destructuring, nullish, Buffer — is the confined Runtime. dangerous_refs stays empty.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Lower, Runtime}

  @conf "test/conformance"

  @tag timeout: 600_000
  test "rollup bundles the virtual entry byte-identical to the golden, BEAM-native, confined" do
    prelude = File.read!(Path.join(@conf, "porffor_cjs/cjs_prelude.js")) <> "\n" <> File.read!(Path.join(@conf, "rollup/node_shims.js"))
    console = "var console = { log: function(){ print(arguments[0]); } };\n"
    bundle = File.read!(Path.join(@conf, "rollup/rollup_bundle.cjs"))

    # PARALLEL compiled lane: exploded defs partitioned across scheduler-count sibling modules, compiled
    # concurrently (the compile-time wall was 157s in one module; ~7s across 10 — the Erlang compiler is
    # superlinear per function and parallel only across modules). Chunk calls dispatch by NAME via Runtime.cf,
    # so no guest module references another.
    nmods = System.schedulers_online()

    %{main: mainq, siblings: sibqs} =
      Lower.modules_quoted(Js.parse(console <> prelude <> bundle), %{"print" => 0, "__host" => 1}, modules: nmods)

    uid = System.unique_integer([:positive])

    mods =
      [{:main, mainq} | Enum.with_index(sibqs) |> Enum.map(fn {q, i} -> {:"sib#{i}", q} end)]
      |> Task.async_stream(
        fn {tag, q} ->
          mod = Module.concat([TinyLasers.Gate.Guest, "RollupBundle#{uid}#{tag}"])
          [{m, bin} | _] = Code.compile_quoted(quote do (defmodule unquote(mod) do unquote(q) end) end)
          {tag, m, bin}
        end,
        timeout: 600_000, max_concurrency: nmods
      )
      |> Enum.map(fn {:ok, r} -> r end)

    # confinement: EVERY module of the compiled rollup engine references ONLY the Runtime (host work — the
    # wasm parser — is a granted capability handle; sibling chunk fns are reached by name via the cf registry,
    # never by module reference).
    for {tag, _, bin} <- mods do
      assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin), "module #{tag} not confined"
    end

    {:main, main, _} = List.keyfind(mods, :main, 0)
    Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}, 1 => %{fun: &Runtime.host_rollup_bridge/2}}, tenant_root: "/t", fs: %{}})
    for {tag, m, _} <- mods, tag != :main, do: apply(m, :__gg_register, [])
    try do apply(main, :run, []) catch :throw, _ -> :ok end
    out = Runtime.__output()

    ok_line = Enum.find(out, &String.starts_with?(&1, "BUNDLE_OK["))
    assert ok_line, "rollup did not produce BUNDLE_OK; output=#{inspect(Enum.take(out, 10))}"

    code = ok_line |> String.replace_prefix("BUNDLE_OK[", "") |> String.replace_suffix("]", "")
    golden = File.read!(Path.join(@conf, "rollup/rollup_bundle_golden.js"))
    assert String.trim(code) == String.trim(golden), "bundle mismatch:\n  got=#{inspect(code)}\n  want=#{inspect(golden)}"
  end
end
