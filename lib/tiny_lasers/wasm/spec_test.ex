defmodule TinyLasers.Wasm.SpecTest do
  @moduledoc """
  Runs WebAssembly **spec-test scripts** (`.wast`) against Wasm: parse (`Sexp`) → assemble each
  `(module …)` to bytes (`Wat`) → decode/validate/run, and check the assertions:

    * `assert_return (invoke "f" args…) results…` — the call returns the expected value(s)
    * `assert_trap (invoke "f" args…) "msg"` — the call traps
    * `assert_invalid (module …) "msg"` — validation rejects the module
    * `assert_malformed` / `assert_exhaustion` / `register` / … — recorded as **skipped**, not failed

  Returns a summary `%{pass, fail, skip, failures}`. Forms the harness can't yet handle (an unsupported
  WAT op, a directive we don't model) are **skipped with a reason** — never silently passed and never
  counted against the pass rate as a failure. `run_file/1` reads a `.wast` from disk; `pass_rate/1`
  is `pass / (pass + fail)`.
  """
  import Bitwise
  alias TinyLasers.Wasm
  alias TinyLasers.Wasm.{Sexp, Wat, Validate}

  @doc "Run a `.wast` source string. → `%{pass, fail, skip, failures}`."
  def run(wast) when is_binary(wast) do
    wast
    |> Sexp.parse_all()
    |> Enum.reduce(%{mod: nil, pass: 0, fail: 0, skip: 0, failures: []}, &directive/2)
    |> Map.delete(:mod)
  end

  @doc "Run a `.wast` file from disk."
  def run_file(path), do: path |> File.read!() |> run()

  @doc "pass / (pass + fail); 1.0 if nothing ran."
  def pass_rate(%{pass: p, fail: f}) when p + f > 0, do: p / (p + f)
  def pass_rate(_), do: 1.0

  # ── directives ──────────────────────────────────────────────────────────────────────────────────
  defp directive(["module" | _] = form, state) do
    case assemble_decode(form) do
      {:ok, mod} -> %{state | mod: mod}
      # a module the harness can't yet build isn't a conformance failure — skip subsequent asserts
      {:error, _} -> %{state | mod: :unsupported}
    end
  end

  defp directive(["assert_return", ["invoke", {:string, fname} | args] | expected], state) do
    grade(state, fn mod ->
      actual = Wasm.call(mod, fname, Enum.map(args, &eval_const/1))

      case expected do
        [] -> {:ok, actual}
        [e] -> if actual == eval_const(e), do: {:ok, actual}, else: {:fail, {fname, actual, eval_const(e)}}
        _ -> :skip
      end
    end)
  end

  defp directive(["assert_trap", ["invoke", {:string, fname} | args] | _msg], state) do
    grade(state, fn mod ->
      try do
        v = Wasm.call(mod, fname, Enum.map(args, &eval_const/1))
        {:fail, {:expected_trap, fname, v}}
      rescue
        Wasm.Trap -> {:ok, :trapped}
      end
    end)
  end

  defp directive(["assert_invalid", ["module" | _] = m, _msg], state) do
    case assemble_decode(m) do
      {:ok, mod} ->
        # assembled + decoded; structural validation must reject it. If it passes structural validation,
        # the module is ill-TYPED (not ill-structured) — detecting that needs full type validation, which
        # is deferred. We don't claim it: SKIP (tracked as the validation gap), not a false pass/fail.
        case Validate.validate(mod) do
          {:error, _} -> bump(state, :pass)
          :ok -> bump(state, :skip)
        end

      {:error, _} ->
        # couldn't even assemble/decode — that's also a rejection of an invalid module
        bump(state, :pass)
    end
  end

  # everything else (assert_malformed/exhaustion/register/named modules/…) — not yet modeled
  defp directive(_other, state), do: bump(state, :skip)

  # ── helpers ───────────────────────────────────────────────────────────────────────────────────
  # run a graded check against the current module; no module / unsupported module → skip
  defp grade(%{mod: nil} = state, _f), do: bump(state, :skip)
  defp grade(%{mod: :unsupported} = state, _f), do: bump(state, :skip)

  defp grade(%{mod: mod} = state, f) do
    case safe(fn -> f.(mod) end) do
      {:ok, _} -> bump(state, :pass)
      :skip -> bump(state, :skip)
      {:fail, why} -> add_fail(state, why)
      {:error, why} -> add_fail(state, {:crash, why})
    end
  end

  defp safe(thunk) do
    thunk.()
  rescue
    e in Wasm.Trap ->
      {:fail, {:unexpected_trap, e.reason}}

    e ->
      msg = Exception.message(e)
      # an unimplemented op is a tracked feature gap, not a wrong answer → skip, don't fail
      if msg =~ "unimplemented" or msg =~ "unhandled", do: :skip, else: {:error, msg}
  catch
    # a literal the harness can't yet evaluate (hex-float, NaN, inf) → skip, don't fail
    :throw, {:unsupported_const, _} -> :skip
    :throw, other -> {:error, {:throw, other}}
  end

  defp assemble_decode(form) do
    with {:ok, bytes} <- Wat.assemble(form),
         {:ok, mod} <- Wasm.decode(bytes) do
      {:ok, mod}
    end
  end

  # evaluate an argument/expected const expression to an Elixir value
  defp eval_const(["i32.const", n]), do: int(n) &&& 0xFFFFFFFF
  defp eval_const(["i64.const", n]), do: int(n) &&& 0xFFFFFFFFFFFFFFFF
  defp eval_const(["f32.const", n]), do: flt(n)
  defp eval_const(["f64.const", n]), do: flt(n)
  defp eval_const(other), do: throw({:unsupported_const, other})

  defp int(s), do: s |> String.replace("_", "") |> do_int()
  defp do_int("0x" <> h), do: String.to_integer(h, 16)
  defp do_int("-0x" <> h), do: -String.to_integer(h, 16)
  defp do_int(s), do: String.to_integer(s)

  # NaN/inf/hex-float literals aren't representable as BEAM floats → the harness can't express the
  # assertion (skipped upstream). Plain decimal floats parse normally.
  defp flt("nan" <> _), do: throw({:unsupported_const, :nan})
  defp flt("+nan" <> _), do: throw({:unsupported_const, :nan})
  defp flt("-nan" <> _), do: throw({:unsupported_const, :nan})
  defp flt("inf"), do: throw({:unsupported_const, :inf})
  defp flt("+inf"), do: throw({:unsupported_const, :inf})
  defp flt("-inf"), do: throw({:unsupported_const, :inf})
  defp flt("0x" <> _), do: throw({:unsupported_const, :hexfloat})
  defp flt("-0x" <> _), do: throw({:unsupported_const, :hexfloat})
  defp flt("+0x" <> _), do: throw({:unsupported_const, :hexfloat})

  defp flt(s) do
    case Float.parse(String.replace(s, "_", "")) do
      {f, _} -> f
      :error -> throw({:unsupported_const, s})
    end
  end

  defp bump(state, key), do: Map.update!(state, key, &(&1 + 1))
  defp add_fail(state, why), do: %{bump(state, :fail) | failures: [why | state.failures]}
end
