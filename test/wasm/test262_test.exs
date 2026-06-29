defmodule TinyLasers.JsPorfforTest262Test do
  @moduledoc """
  **test262 conformance gate** — the official ECMAScript spec tests, run on the Porffor→Washy WASM→BEAM
  ASM transpiler lane (the shipping lane for running untrusted JS *emulated in WASM*, per the EMULATION
  THESIS). Mirrors the corpus tests (regex/async/number): compile on the ASM lane via
  `TinyLasers.Js.Debug.diagnose(transpile: true)`, classify against the spec expectation.

  Runs the **committed curated slice** (`test/conformance/test262/cases/`, ~419 cases — manifest + WHY in
  `manifest.work`). node is an ORACLE only (the vendored `assert.js`/`sta.js` define the spec expectation by
  throwing on failure); the lane is the thing under test.

  ## Why it shells out to the isolated runner

  Some test262 cases drive the no-GC lane into a cross-case memory accumulation that **SIGABRTs the whole
  BEAM** (exactly the ceiling `TinyLasers.Js.Debug`'s docs + `run_corpus.exs` warn about). A SIGABRT cannot
  be caught in-process, so running all 419 cases in one ExUnit BEAM would crash the suite. Instead the gate
  drives `scripts/test262-run-isolated.exs`, which runs the slice in small **OS-isolated batches** — a
  crashed batch is reported as crashed cases, never a lost run. This keeps the gate green-or-red, never a
  hung/aborted process (the CLAUDE.md "never leave a process wedged" rule).

  Tagged `@tag :test262` / `@moduletag :test262` so it is a focused subset (`mix test --only test262`) and
  does NOT wedge CI. It is a REPORTING gate: asserts the harness ran and prints the catalogue; it does not
  fail the build on the engine gaps it surfaces (gap-fixing is delegated — gaps filed under bd epic wb-8p78).
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Js.Porffor

  @slice Path.join([__DIR__, "conformance", "test262"])
  @cases Path.join(@slice, "cases")
  @script Path.join([File.cwd!(), "scripts", "test262-run-isolated.exs"])

  @moduletag :test262

  setup_all do
    if File.dir?(@cases) and File.regular?(Porffor.porf_entry()),
      do: :ok,
      else: {:skip, "test262 slice or porffor absent"}
  end

  @tag :test262
  @tag timeout: 1_800_000
  test "test262 curated slice runs on the ASM lane in OS-isolated batches (catalogue gaps)" do
    {out, _code} =
      System.cmd("mix", ["run", @script],
        env: [{"DIR", "cases"}, {"BATCH", "15"}, {"MIX_ENV", "dev"}],
        stderr_to_stdout: true,
        cd: File.cwd!()
      )

    report = out |> String.split("\n") |> Enum.drop_while(&(not String.starts_with?(&1, "=== test262")))
    IO.puts("\n" <> Enum.join(report, "\n"))

    pass_line = Enum.find(report, "", &String.starts_with?(&1, "pass "))
    [_, pass] = Regex.run(~r/^pass (\d+)\//, pass_line) || [nil, "0"]

    # The gate's ONE hard assertion: the harness ran to a terminal verdict AND produced passes (proving the
    # ASM lane + assemble + classify path is live, not vacuously green). Engine gaps below this are catalogued
    # under bd wb-8p78, NOT failed here.
    assert pass_line != "", "isolated runner produced no summary — harness/driver broken:\n#{out}"
    assert String.to_integer(pass) > 0, "harness produced zero passes — assemble/classify likely broken"
  end
end
