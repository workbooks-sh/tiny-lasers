defmodule TinyLasers.Gate.F2ConfinementTest do
  @moduledoc """
  **F2 Phase 2 — H2: confinement holds across the JS surface (the TCB, adversarial).**

  The load-bearing invariant: guest RUNTIME data never crosses into the atom / MFA / raw-fun / raw-pid
  domain, so a host module is not merely blocked but UNNAMEABLE. Every escape attempt below is compiled to
  native BEAM and checked THREE ways:

    1. `dangerous_refs` on the emitted binary = `%{ext: [], bifs: []}` (references only the Runtime).
    2. the escape resolves to a guest value (`:undefined` / guest error), never a host effect.
    3. no guest STRING VALUE is interned as an atom (the atom-domain firewall).

  Scope honesty: this covers the compiled AOT path across dynamic dispatch, host-name strings, prototype
  tricks, and higher-order calls. Compile-time IDENTIFIER names ARE atomized (bounded by source size — the
  classic atom-DoS is closed for the dynamic/eval path by interpreting, and bounded for AOT by a source cap);
  runtime guest data mints zero atoms, which is what this asserts.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.Js

  defp confined?(bin), do: match?(%{ext: [], bifs: []}, TinyLasers.Gate.dangerous_refs(bin))

  # every escape attempt: emitted binary references only the Runtime, AND the result is a confined guest value.
  @escapes [
    {"os.cmd", "os.cmd('rm -rf /')"},
    {"File deref", "File.read('/etc/passwd')"},
    {"erlang module string call", "var m = 'Elixir.System'; m.cmd('whoami')"},
    {"computed dynamic dispatch", "var o = { a: 1 }; var k = 'constructor'; o[k]"},
    {"prototype access", "var o = { x: 1 }; o.__proto__"},
    {"constructor access", "var o = { x: 1 }; o.constructor"},
    {"computed call of host-looking name", "var o = {}; var n = 'spawn'; o[n]()"},
    {"apply-looking", "var f = { apply: 1 }; f.apply"},
    {"higher-order returning host?", "function f() { return os; } var g = f(); g"},
    {"string that names a BIF", "var s = 'halt'; s"}
  ]

  for {name, src} <- @escapes do
    test "confined: #{name}" do
      %{binary: bin, result: res, output: out} = Js.run(unquote(src))
      assert confined?(bin), "guest referenced a non-Runtime module: #{inspect(TinyLasers.Gate.dangerous_refs(bin))}"
      # no host effect: either a plain guest value, undefined, or a guest error — never a crash/escape.
      assert match?({:ok, _}, res) or match?({:guest_error, _}, res), "unexpected result #{inspect(res)}"
      assert out == [], "guest produced host output it was not granted"
    end
  end

  test "guest string VALUES are never interned as atoms (the atom-domain firewall)" do
    # a program whose RUNTIME data is a set of distinctive strings used as keys, values, and dynamic-dispatch
    # names — none may become an atom.
    prog = fn tag ->
      """
      var o = {};
      o['#{tag}_alpha'] = '#{tag}_bravo';
      o['#{tag}_charlie'] = o['#{tag}_alpha'];
      var arr = ['#{tag}_delta', '#{tag}_echo'];
      var pick = arr[0];
      o[pick] = '#{tag}_foxtrot';
      o['#{tag}_alpha']
      """
    end

    %{result: {:ok, "zzq_bravo"}, binary: bin} = Js.run(prog.("zzq"))
    assert confined?(bin)

    # PRECISE invariant: every distinctive guest string is absent from the atom table (raises if interned).
    for s <- ~w(zzq_alpha zzq_bravo zzq_charlie zzq_delta zzq_echo zzq_foxtrot) do
      assert_raise ArgumentError, fn -> :erlang.binary_to_existing_atom(s, :utf8) end
    end

    # RUNTIME backstop (compile-time module/identifier atoms are bounded per program and not the concern):
    # run a SECOND program with the SAME structure but DIFFERENT string data. If guest string values were
    # atomized, the fresh strings would balloon the atom table; they don't (only ~1 new module-name atom).
    base = :erlang.system_info(:atom_count)
    for tag <- ~w(aaa bbb ccc ddd eee), do: Js.run(prog.(tag))
    grew = :erlang.system_info(:atom_count) - base
    assert grew < 30, "5 same-structure programs with distinct string data grew the atom table by #{grew}"
  end

  test "a granted capability is the ONLY side-effect surface; ungranted ones are inert" do
    # print IS granted by default → output flows; fs_write is NOT granted → the identifier is undefined.
    %{output: out, binary: bin} = Js.run("print('hello'); fs_write('/etc/x', 'pwned')", caps: default_print_only())
    assert out == ["hello"]
    assert confined?(bin)
  end

  defp default_print_only, do: %{0 => %{fun: &TinyLasers.Gate.Runtime.cap_print/2}}
end
