defmodule TinyLasers.Wasm.Trap do
  @moduledoc """
  A **wasm trap** — the structured, catchable signal both Wasm backends raise on a spec-defined
  fault (out-of-bounds access, integer divide-by-zero, integer overflow, `unreachable`, …).

  A trap is the whole isolation story made concrete: it is a *caught Elixir exception in one BEAM
  process*, never a VM fault. The interpreter raises it; the wasm→BEAM transpiler will lower the same
  faults to the SAME exception — so the differential oracle can assert that both backends trap
  *identically* (same `reason`), not merely that both happen to fail.

      raise TinyLasers.Wasm.Trap, reason: :out_of_bounds
  """
  defexception [:reason]

  @impl true
  def message(%{reason: r}), do: "washy trap: #{r}"

  @doc "Raise a trap with `reason` (an atom like `:out_of_bounds` / `:div_by_zero`)."
  def trap!(reason), do: raise(__MODULE__, reason: reason)
end
