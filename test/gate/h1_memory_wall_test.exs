defmodule TinyLasers.Gate.H1MemoryWallTest do
  @moduledoc """
  **F2 Phase 0 — H1: the memory wall vanishes when objects are directly-held GC'd BEAM terms.**

  The hybrid (host-objects on the WASM lane) has no GC: an allocation-heavy program (marked parsing 16
  docs, thousands of `Object.assign` merges) exhausts the linear-memory arena and OOMs. This locks the
  go/no-go proof that the BEAM-native representation removes that wall — AND the load-bearing constraint
  that a HANDLE TABLE does NOT (it reproduces the wall by holding a strong ref to every object forever).

  Workload mirrors marked's hot path: build small objects and `Object.assign({}, a, b)` (a FRESH object,
  functional — never a shared mutation), then discard. The direct-term run does 10x the iterations of the
  handle-table run in a small fraction of the memory.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.Runtime

  defp total_mb, do: :erlang.memory(:total) |> div(1024 * 1024)

  test "handle-table representation ACCUMULATES (reproduces the wall, BEAM-colored)" do
    Runtime.__init(%{caps: %{}})

    for _ <- 1..100_000 do
      a = Runtime.obj_new([{"x", 1.0}, {"y", 2.0}])
      b = Runtime.obj_new([{"z", 3.0}])
      m = Runtime.obj_new([])
      m = Enum.reduce(Runtime.keys(a), m, fn k, acc -> Runtime.set(acc, k, Runtime.get(a, k)) end)
      _ = Enum.reduce(Runtime.keys(b), m, fn k, acc -> Runtime.set(acc, k, Runtime.get(b, k)) end)
      :ok
    end

    # The heap grew by ~3 entries/iter and NONE were reclaimed — the handle table defeats GC. This asserts
    # the design finding: the current gate representation must become direct-term for H1 to hold.
    entries = map_size(Process.get(:gg_heap))
    assert entries >= 300_000, "expected the handle table to accumulate every object; got #{entries}"
  end

  test "direct immutable-term representation stays FLAT under 20x the allocation load (H1)" do
    :erlang.garbage_collect()
    before = total_mb()

    # 2,000,000 functional Object.assign-merges; each result is unreachable next iter -> GC reclaims.
    final =
      Enum.reduce(1..2_000_000, %{}, fn _i, _acc ->
        a = %{"x" => 1.0, "y" => 2.0}
        b = %{"z" => 3.0}
        Map.merge(a, b)
      end)

    :erlang.garbage_collect()
    delta = total_mb() - before

    assert final == %{"x" => 1.0, "y" => 2.0, "z" => 3.0}
    # Flat memory despite 2M allocations — the wall is gone. (Generous bound; observed ~16MB vs the
    # handle table's +110MB at 1/10th the iterations.)
    assert delta < 60, "direct-term memory should stay flat under allocation pressure; grew #{delta} MB"
  end
end
