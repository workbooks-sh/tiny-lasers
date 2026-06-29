defmodule TinyLasers.Wasm.DiffTrace do
  @moduledoc """
  **Differential localizer for interp≢asm divergence — turns "the transpiled run is wrong somewhere" into
  "asm function `wf_<gfidx>` is the culprit" automatically.**

  The interpreter is the correctness ORACLE; the asm/transpiler lane is the production deliverable and must
  be bit-identical. When it isn't, this harness binary-searches *which* asm-compiled guest function causes
  the divergence, using the `:tl_jit_only` seam in `TinyLasers.Wasm.lazy_invoke/6`: an installed allow-set
  restricts the asm lane to exactly those gfidxs (everything else interprets), so we can run a subset
  through the asm lane and check whether the divergence reproduces.

  This is the tool that cracked wb-7jwh (an asm void-call leaking a phantom 0, mis-attributed for hours to
  the f64 number-parser): a per-byte memory-write differential found the first divergent write + owning
  function; the bisection below pinned the single function whose asm compilation flips the result.

  ## Usage

      # `thunk.(opts)` runs the guest once with the given `instance_start` opts (re-decoding the module so
      # each run is independent) and returns a COMPARABLE term (e.g. the output bytes / final AST buffer).
      DiffTrace.localize(nfuncs, n_imports, thunk)
      #=> :identical
      #=> {:divergent, gfidx}            # this single asm fn flips the result (force it to interp → correct)
      #=> {:interaction, [gfidx, ...]}   # no single fn; the set is the minimal reproducing block

  Localizing requires running the guest O(log n) times, so it's a diagnostic — call it from a test or an
  iex session, not on the hot path. The `:tl_jit_only` check it relies on is a single process-dict read
  in the JIT gate (nil in normal operation).
  """

  @asm_opts [transpile: true, tier_threshold: 1, tier_async: false]

  @doc """
  Localize an interp≢asm divergence. `thunk.(opts)` must run the guest with the given `instance_start` opts
  and return a comparable result. Returns `:identical` (asm == interp), `{:divergent, gfidx}` (one asm fn
  is responsible), or `{:interaction, gfidxs}` (a minimal multi-fn set — no single culprit).
  """
  def localize(nfuncs, n_imports, thunk) when is_integer(nfuncs) and is_integer(n_imports) do
    Process.delete(:tl_jit_only)
    golden = thunk.([])

    all = for i <- 0..(nfuncs - 1)//1, do: i + n_imports
    bad? = fn allow -> run_allow(MapSet.new(allow), thunk) != golden end

    cond do
      not bad?.(all) -> :identical
      true -> narrow(all, bad?)
    end
  end

  # Install the asm allow-set, run the asm lane, clear it. A run is independent (the thunk re-decodes and
  # `instance_start` resets `:tl_jit`); a trap/throw counts as "divergent" (catch → sentinel ≠ golden).
  defp run_allow(allow, thunk) do
    Process.put(:tl_jit_only, allow)

    try do
      thunk.(@asm_opts)
    catch
      kind, val -> {:difftrace_threw, kind, val}
    after
      Process.delete(:tl_jit_only)
    end
  end

  # Binary-search the allow-list for a minimal reproducing subset: if a half alone reproduces, recurse into
  # it; if neither half does (the divergence needs functions from BOTH), it's an interaction — report the
  # current set. Single survivor ⇒ that's the culprit.
  defp narrow([single], _bad?), do: {:divergent, single}

  defp narrow(list, bad?) do
    {a, b} = Enum.split(list, div(length(list), 2))

    cond do
      bad?.(a) -> narrow(a, bad?)
      bad?.(b) -> narrow(b, bad?)
      true -> {:interaction, list}
    end
  end

  @doc """
  Function-level invariant oracle: every function, run in the interpreter, must leave EXACTLY its declared
  result arity on the operand stack (no leaked/dropped operands — the failure mode behind the br-discard
  and void-call bugs). `invoke.(gfidx)` must invoke that function and return `{:ok, stack_height}` (or
  `{:trap, _}` to skip). Returns the list of `{gfidx, expected, got}` violations (empty == all sound).
  """
  def result_arity_violations(mod, invoke) do
    ni = length(mod.imports)

    for li <- 0..(length(mod.code) - 1)//1,
        {_params, results} = Enum.at(mod.types, Enum.at(mod.funcs, li)),
        match?({:ok, _}, invoke.(li + ni)),
        {:ok, height} = invoke.(li + ni),
        height != length(results) do
      {li + ni, length(results), height}
    end
  end
end
