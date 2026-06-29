defmodule TinyLasers.Wasm.Density do
  @moduledoc """
  Density telemetry — the live picture of the *hard walls* the Wasm runtime must watch BEFORE they crash
  the node. We run thousands of untrusted wasm/JS guests per box, and the BEAM has a handful of global,
  non-elastic resources whose exhaustion is unrecoverable. The deep-research report
  (`nexus/reference/beam/MEMORY-ANALYSIS-REPORT.md`, §7) named each wall, its danger threshold, and the
  remediation; this module encodes exactly that table so a dashboard can surface a wall while it's still
  approaching rather than after the VM dies.

  Pure, cheap reads — no side effects, safe to poll on a gauge.

    * `report/0`   — gather every watched metric into one flat map.
    * `assess/0`   — classify each metric against its danger threshold ⇒ list of
                     `%{metric, value, status: :ok | :warn | :danger, remediation}`.
    * `summary/0`  — a human one-liner ("atoms 4% · modules 312 · binary 18MB · OK").

  The thresholds (report §7):

    | metric              | source                                   | danger              | remediation |
    |---------------------|------------------------------------------|---------------------|-------------|
    | atom table          | `system_info(:atom_count/:atom_limit)`   | >85% of limit       | stop new compiles; consolidate funcs → one module per guest |
    | loaded modules      | `length(:code.all_loaded())`             | >100_000            | soft-purge inactive; consolidate |
    | allocator frag      | `system_info({:allocator, :eheap_alloc})`| carrier frag >1.2   | `+Mea max`, `+M<S>acul de` |
    | literal carrier     | `:erlang.memory(:code)` proxy / PT carrier | >800 MB (of 1 GB) | `+MIscs` larger |
    | off-heap binary     | `:erlang.memory(:binary)`                | >50% of RAM         | force `garbage_collect/1` on I/O procs |

  We also fold in the cheap recovery levers already measured by `TinyLasers.Wasm.Metrics.snapshot/0`
  (`module_pool` + `atoms`) so the same surface shows the pool that exists to keep the atom wall flat.
  """

  # --- thresholds (report §7) -------------------------------------------------
  @atom_danger_frac 0.85
  @atom_warn_frac 0.70
  @modules_danger 100_000
  @modules_warn 50_000
  @frag_danger 1.2
  @frag_warn 1.1
  # literal/code carrier — 1 GB super-carrier, danger at 800 MB
  @literal_danger 800 * 1024 * 1024
  @literal_warn 600 * 1024 * 1024
  @binary_danger_frac 0.50
  @binary_warn_frac 0.35

  @remediation %{
    atoms: "atom table >85% of limit → stop new compiles; consolidate funcs → one module per guest (report Wall #1)",
    modules: "loaded modules >100k → soft-purge inactive; consolidate to fewer, bigger modules (report Wall #3)",
    frag: "eheap carrier fragmentation >1.2 → boot with +Mea max and +M<S>acul de (carrier reuse under churn)",
    literal: "literal/code carrier >800MB of the 1GB super-carrier → boot with a larger +MIscs",
    binary: "off-heap (refc) binary >50% of RAM → force :erlang.garbage_collect/1 on busy I/O guest procs (report Wall #5)"
  }

  @doc "Gather every watched metric into one flat map (pure reads)."
  def report do
    mem = :erlang.memory()
    atom_count = :erlang.system_info(:atom_count)
    atom_limit = :erlang.system_info(:atom_limit)
    total_ram = total_ram_bytes(mem)

    %{
      atom_count: atom_count,
      atom_limit: atom_limit,
      atom_frac: safe_div(atom_count, atom_limit),
      loaded_modules: length(:code.all_loaded()),
      process_count: :erlang.system_info(:process_count),
      eheap_carrier_frac: eheap_carrier_frac(),
      literal_carrier_bytes: mem[:code] || 0,
      binary_bytes: mem[:binary] || 0,
      total_ram_bytes: total_ram,
      binary_frac: safe_div(mem[:binary] || 0, total_ram),
      mem_total_bytes: mem[:total] || 0,
      mem_processes_bytes: mem[:processes] || 0,
      mem_ets_bytes: mem[:ets] || 0,
      mem_atom_bytes: mem[:atom] || 0,
      # the recovery levers already measured elsewhere — folded in, not re-derived
      runtime: runtime_levers()
    }
  end

  @doc """
  Classify each watched metric against its danger threshold. Returns a list of
  `%{metric, value, status: :ok | :warn | :danger, remediation}`.
  """
  def assess do
    r = report()

    [
      classify(:atoms, r.atom_frac, @atom_warn_frac, @atom_danger_frac, @remediation.atoms),
      classify(:modules, r.loaded_modules, @modules_warn, @modules_danger, @remediation.modules),
      classify(:frag, r.eheap_carrier_frac, @frag_warn, @frag_danger, @remediation.frag),
      classify(:literal, r.literal_carrier_bytes, @literal_warn, @literal_danger, @remediation.literal),
      classify(:binary, r.binary_frac, @binary_warn_frac, @binary_danger_frac, @remediation.binary)
    ]
  end

  @doc ~S'A human one-liner — e.g. "atoms 4% · modules 312 · binary 18MB · OK".'
  def summary do
    r = report()
    worst = worst_status(assess())

    [
      "atoms #{pct(r.atom_frac)}",
      "modules #{r.loaded_modules}",
      "frag #{Float.round(r.eheap_carrier_frac, 2)}",
      "binary #{mb(r.binary_bytes)}MB",
      status_word(worst)
    ]
    |> Enum.join(" · ")
  end

  # --- classifier (exposed for tests with synthetic values) -------------------

  @doc """
  Pure threshold classifier. `value >= danger` → `:danger`; `>= warn` → `:warn`; else `:ok`.
  Exposed so tests can feed synthetic values without standing up the VM walls.
  """
  def classify(metric, value, warn, danger, remediation) do
    status =
      cond do
        value >= danger -> :danger
        value >= warn -> :warn
        true -> :ok
      end

    %{metric: metric, value: value, status: status, remediation: remediation}
  end

  @doc "Reduce an `assess/0` list to the single worst status."
  def worst_status(assessments) do
    Enum.reduce(assessments, :ok, fn %{status: s}, acc -> max_status(acc, s) end)
  end

  # --- internals --------------------------------------------------------------

  defp max_status(:danger, _), do: :danger
  defp max_status(_, :danger), do: :danger
  defp max_status(:warn, _), do: :warn
  defp max_status(_, :warn), do: :warn
  defp max_status(_, _), do: :ok

  defp status_word(:ok), do: "OK"
  defp status_word(:warn), do: "WARN"
  defp status_word(:danger), do: "DANGER"

  defp runtime_levers do
    TinyLasers.Wasm.Metrics.snapshot()
    |> Map.take([:module_pool, :atoms])
  rescue
    _ -> %{module_pool: %{}, atoms: %{}}
  end

  # eheap_alloc carrier "fragmentation" ≈ allocated bytes / in-use (live) bytes across carriers.
  # >1.2 means we're holding ~20% more carrier than we're using — schedulers retaining empty carriers.
  defp eheap_carrier_frac do
    case :erlang.system_info({:allocator, :eheap_alloc}) do
      info when is_list(info) ->
        {alloc, used} = carrier_bytes(info)
        if used > 0, do: alloc / used, else: 1.0

      _ ->
        1.0
    end
  end

  # Sum mbcs/sbcs carrier_size (allocated) and blocks_size (live) across every scheduler instance.
  defp carrier_bytes(info) do
    Enum.reduce(info, {0, 0}, fn
      {:instance, _id, stats}, acc -> acc_carrier(stats, acc)
      _other, acc -> acc
    end)
  end

  defp acc_carrier(stats, acc) when is_list(stats) do
    Enum.reduce([:mbcs, :sbcs], acc, fn key, {a, u} ->
      case Keyword.get(stats, key) do
        sub when is_list(sub) ->
          {a + pair_val(sub, :carriers_size), u + pair_val(sub, :blocks_size)}

        _ ->
          {a, u}
      end
    end)
  end

  defp acc_carrier(_stats, acc), do: acc

  # carrier sub-stats are a proplist of tuples, each `{key, current, max_since_clear, max_ever}`
  # (or a plain `{key, current}`). Scan for the key and take the `current` (first value) field.
  defp pair_val(sub, key) do
    Enum.find_value(sub, 0, fn
      {^key, current, _, _} -> current
      {^key, current} -> current
      _ -> false
    end)
  end

  # Physical RAM if the OS reports it; else fall back to current total BEAM allocation
  # (so binary_frac stays a meaningful ratio even without :memsup).
  defp total_ram_bytes(mem) do
    case apply(:memsup, :get_system_memory_data, []) do
      data when is_list(data) ->
        Keyword.get(data, :total_memory) || Keyword.get(data, :system_total_memory) || mem[:total] || 1

      _ ->
        mem[:total] || 1
    end
  rescue
    _ -> mem[:total] || 1
  catch
    :exit, _ -> mem[:total] || 1
  end

  defp safe_div(_n, 0), do: 0.0
  defp safe_div(n, d), do: n / d

  defp pct(frac), do: "#{round(frac * 100)}%"
  defp mb(bytes), do: round(bytes / (1024 * 1024))
end
