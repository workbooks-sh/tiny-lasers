defmodule TinyLasers.Wasm.Metrics do
  @moduledoc """
  Operability metrics for Wasm runs — lock-free `:counters` on the hot path (no GenServer to bottleneck
  under load), plus a small `:ets` table for the trap-reason + fuel-bucket histograms. Every run brackets
  itself with `start_run/1` … `finish_run/3`; `snapshot/0` reads the live picture for a dashboard:

    * **throughput** — total runs, and counts by outcome (`ok` / `trap` / `timeout` / `error`)
    * **traps by reason** — `out_of_fuel` / `out_of_bounds` / `stack_exhausted` / … (what's actually failing)
    * **fuel histogram** — distribution of work per run (log2 buckets)
    * **latency** — total + avg µs per run
    * **concurrency** — in-flight gauge + observed peak (the backpressure picture)
    * **density** — live linear-memory bytes across in-flight cells ⇒ cells/GB

  Lazily initialized (`ensure/0`), so it works in tests without app boot.
  """
  @counters {__MODULE__, :counters}
  @reasons {__MODULE__, :reasons_tab}

  # fixed counter slots
  @total 1
  @ok 2
  @trap 3
  @timeout 4
  @error 5
  @in_flight 6
  @peak 7
  @fuel_used 8
  @latency_us 9
  @out_bytes 10
  @mem_bytes 11
  @size 11

  @doc "Create the counter array + reason table once (idempotent)."
  def ensure do
    case :persistent_term.get(@counters, nil) do
      nil ->
        ref = :counters.new(@size, [:write_concurrency])
        :persistent_term.put(@counters, ref)
        :ets.new(reasons_name(), [:named_table, :public, :set, write_concurrency: true])
        :persistent_term.put(@reasons, reasons_name())
        ref

      ref ->
        ref
    end
  rescue
    # ETS table already exists (race) — fine
    ArgumentError -> :persistent_term.get(@counters)
  end

  defp reasons_name, do: :nexus_washy_metric_reasons
  defp ctr, do: :persistent_term.get(@counters, nil) || ensure()

  @doc "Mark a run started: bump in-flight (+ peak) and the live memory gauge. Returns a token to finish."
  def start_run(mem_bytes \\ 0) do
    c = ctr()
    :counters.add(c, @in_flight, 1)
    :counters.add(c, @mem_bytes, mem_bytes)
    inflight = :counters.get(c, @in_flight)
    if inflight > :counters.get(c, @peak), do: :counters.put(c, @peak, inflight)
    %{t0: System.monotonic_time(:microsecond), mem: mem_bytes}
  end

  @doc """
  Mark a run finished. `outcome` is `:ok | :trap | :timeout | :error`; opts carry `:reason` (trap atom),
  `:fuel_used`, `:out_bytes`.
  """
  def finish_run(%{t0: t0, mem: mem}, outcome, opts \\ []) do
    c = ctr()
    :counters.add(c, @total, 1)
    :counters.sub(c, @in_flight, 1)
    :counters.sub(c, @mem_bytes, mem)
    :counters.add(c, slot(outcome), 1)
    :counters.add(c, @latency_us, System.monotonic_time(:microsecond) - t0)
    if f = opts[:fuel_used], do: bump_fuel(c, f)
    if o = opts[:out_bytes], do: :counters.add(c, @out_bytes, o)
    if outcome == :trap and opts[:reason], do: :ets.update_counter(reasons_tab(), {:trap, opts[:reason]}, 1, {{:trap, opts[:reason]}, 0})
    :ok
  end

  defp slot(:ok), do: @ok
  defp slot(:trap), do: @trap
  defp slot(:timeout), do: @timeout
  defp slot(_), do: @error

  defp bump_fuel(c, f) when is_integer(f) and f > 0 do
    :counters.add(c, @fuel_used, f)
    bucket = trunc(:math.log2(f))
    :ets.update_counter(reasons_tab(), {:fuel_log2, bucket}, 1, {{:fuel_log2, bucket}, 0})
  end

  defp bump_fuel(_c, _f), do: :ok
  defp reasons_tab, do: :persistent_term.get(@reasons, nil) || (ensure(); :persistent_term.get(@reasons))

  @doc "The live metrics picture (for a dashboard / gauge)."
  def snapshot do
    c = ctr()
    total = :counters.get(c, @total)
    lat = :counters.get(c, @latency_us)
    mem = :counters.get(c, @mem_bytes)
    inflight = :counters.get(c, @in_flight)

    %{
      total: total,
      ok: :counters.get(c, @ok),
      trap: :counters.get(c, @trap),
      timeout: :counters.get(c, @timeout),
      error: :counters.get(c, @error),
      in_flight: inflight,
      peak_in_flight: :counters.get(c, @peak),
      avg_latency_us: if(total > 0, do: div(lat, total), else: 0),
      fuel_used: :counters.get(c, @fuel_used),
      out_bytes: :counters.get(c, @out_bytes),
      mem_bytes: mem,
      cells_per_gb: if(inflight > 0 and mem > 0, do: round(inflight * 1_073_741_824 / mem), else: nil),
      traps_by_reason: histogram(:trap),
      fuel_log2: histogram(:fuel_log2),
      # JIT density: the fixed recycled module-atom pool (atom-table wall fix) + the live atom-table
      # picture. `module_pool.in_use`/`evictions` show how hard the pool is recycling; `atoms.count` vs
      # `atoms.limit` is the wall the pool exists to keep flat (deep-research report §7).
      module_pool: module_pool_stats(),
      atoms: %{count: :erlang.system_info(:atom_count), limit: :erlang.system_info(:atom_limit)}
    }
  end

  defp module_pool_stats do
    TinyLasers.Wasm.ModulePool.stats()
  rescue
    _ -> %{size: 0, in_use: 0, evictions: 0, acquires: 0, exhausted: 0, skips: 0}
  end

  defp histogram(kind) do
    reasons_tab()
    |> :ets.match_object({{kind, :_}, :_})
    |> Map.new(fn {{^kind, k}, v} -> {k, v} end)
  end

  @doc "Reset all metrics (tests)."
  def reset do
    c = ctr()
    for i <- 1..@size, do: :counters.put(c, i, 0)
    :ets.delete_all_objects(reasons_tab())
    :ok
  end
end
