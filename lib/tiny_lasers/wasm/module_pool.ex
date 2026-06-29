defmodule TinyLasers.Wasm.ModulePool do
  @moduledoc """
  **The fixed, recycled pool of generated-module name atoms (the atom-table wall, residual fix).**

  The JIT compiles guest wasm chunks into generated BEAM modules whose names are ATOMS, and atoms are
  NEVER garbage-collected (hard VM ceiling ~1,048,576). Minting a fresh unique module-name atom per
  compiled chunk (a fresh `tl_mod_<unique_integer>` atom) grows the atom table O(distinct guest binaries ×
  chunks/binary) — unbounded as distinct programs accumulate, so at scale the node crashes.

  This module **pre-interns a FIXED pool of N module-name atoms at startup** (`tl_pool_0 ..
  tl_pool_(N-1)`). Those N atoms are the ONLY generated-module atoms the JIT ever uses, so total
  generated-module atoms are bounded to **N forever**, regardless of how many distinct programs run.

  ## Acquiring a slot — `acquire/0`
  Hands out a pool slot's atom round-robin (LRU-ish: the oldest-used slot is reused first). Before a slot's
  atom can carry a *new* module, any module currently loaded under that atom must be DISPLACED — and we
  must do so under the **safe code-reload protocol** (`reference/beam/MEMORY-ANALYSIS-REPORT.md` §"Protocol
  for Safe Module Atom Reuse"), because the BEAM keeps at most **2 versions** of a module and a HARD purge
  **kills processes still executing the old version**. We NEVER hard-purge:

    * `:code.soft_purge/1` removes OLD code only, and ONLY if no process is currently executing it —
      returning `false` (and purging nothing) if any process is. So soft_purge can never kill a guest.
    * To recycle atom `A` that has a *current* version loaded: `:code.delete(A)` makes the current version
      "old" (new calls can no longer resolve to it; in-flight calls keep running it), then
      `:code.soft_purge(A)` removes that old version IFF no live guest is still executing it.
    * If `soft_purge` returns `false`, a guest is mid-execution in that slot — we DO NOT purge it (never
      kill a guest), restore it as current (`:code.purge` is never used), and SKIP to another slot.
    * After scanning all N slots without finding a free/purgeable one, `acquire/0` returns `:exhausted`;
      the caller falls back to INTERPRETING that chunk (correct, just not JIT-accelerated this time).

  ## Cache invalidation on eviction
  When a slot is recycled its previously-loaded module is purged, so any `JitCache` `{:ok, {module, _, _}}`
  entry pointing at it is now dangling. We do NOT eagerly sweep the cache (it's keyed by guest, not by
  pool atom). Instead the dispatch path uses **lazy validation**: `loaded?/1` (`:erlang.module_loaded/1`)
  on a cache hit — a hit whose module is no longer loaded is treated as a MISS and transparently
  recompiles into a fresh slot. See `TinyLasers.Wasm.Transpile.cached_one/2`.

  ## Telemetry
  `stats/0` exposes `size` (N), `in_use` (slots that currently carry a loaded module), and `evictions`
  (count of displacements that purged a live module) for the density dashboard (wb-wzgu).
  """
  use GenServer
  require Logger

  @prefix "tl_pool_"

  # Pool size. Each loaded BEAM module costs ~10–30 KiB of `ll_alloc` (metadata/exports/literals/
  # stackmaps), so N modules cap generated-code memory at ~N×20 KiB. N=4096 ⇒ ~80 MiB code ceiling and
  # 4096 module atoms — three orders of magnitude under the ~1M atom wall (leaving the table for
  # everything else), while comfortably exceeding any realistic *concurrent* hot working set (a hot
  # program transpiles ≈ functions/48 chunks; even hundreds of distinct hot programs resident at once fit
  # in 4096 slots). Past the working set, slots recycle: cold programs' modules are displaced and their
  # cache entries lazily recompile on next use. Configurable via `config :nexus, TinyLasers.Wasm.ModulePool,
  # size: N` for tuning at extreme density.
  @default_size 4096

  # ── telemetry counters (lock-free; read by stats/0) ──
  @c_evictions 1
  @c_acquires 2
  @c_exhausted 3
  @c_skips 4
  @counter_size 4

  def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Acquire a pool slot for a fresh compile. Returns `{:ok, module_atom, token}` (the slot's pre-interned
  atom — with any module previously loaded under it safely displaced — and a monotonic generation token
  for this acquisition), or `:exhausted` (every slot currently carries a live, in-execution module —
  caller should interpret this chunk instead).

  The returned atom is ready to receive a `:code.load_binary/3`. The caller MUST load a module under it
  promptly and pin `token` in any cache entry it writes (so a later lookup can detect recycling via
  `valid?/2`). Until the caller loads, the slot is considered free for that atom.
  """
  def acquire, do: GenServer.call(server(), :acquire, 30_000)

  @doc "Pool telemetry for the density dashboard: `%{size, in_use, evictions, acquires, exhausted, skips}`."
  def stats do
    c = counters()

    %{
      size: size(),
      in_use: in_use(),
      evictions: :counters.get(c, @c_evictions),
      acquires: :counters.get(c, @c_acquires),
      exhausted: :counters.get(c, @c_exhausted),
      skips: :counters.get(c, @c_skips)
    }
  end

  @doc "How many pool slots currently carry a loaded generated module (scanned live)."
  def in_use do
    n = size()
    Enum.count(0..(n - 1)//1, fn i -> :erlang.module_loaded(String.to_existing_atom(@prefix <> Integer.to_string(i))) end)
  rescue
    _ -> 0
  end

  @doc """
  **Test-only:** reconfigure the pool to size `n` and reset its cursor/counters. Pre-interns
  `tl_pool_0 .. tl_pool_(n-1)` (a no-op for atoms already interned) and purges any modules currently
  loaded in the first `n` slots so the test starts from a clean, bounded pool. Returns `:ok`.
  """
  def reset(n) when is_integer(n) and n > 0, do: GenServer.call(server(), {:reset, n}, 30_000)

  @doc "The configured pool size N (number of pre-interned module atoms)."
  def size do
    case :persistent_term.get({__MODULE__, :size}, nil) do
      nil -> Application.get_env(:nexus, __MODULE__, [])[:size] || @default_size
      n -> n
    end
  end

  @doc "Is the generated module `m` still loaded? (lazy cache-validation hook — `:erlang.module_loaded/1`)."
  def loaded?(m) when is_atom(m), do: :erlang.module_loaded(m)
  def loaded?(_), do: false

  @doc """
  The CURRENT generation token for pool atom `m` — a monotonic integer bumped on every `acquire/0` of that
  slot. A cached JIT MFA pins the token it was compiled under; `valid?/2` returns true only if the slot
  still carries THAT generation. This is what makes recycling correct: when a slot's atom is reused for a
  DIFFERENT program (same atom, NEW code, still `module_loaded`), the token advances, so the old MFA is
  detected as dead and recompiled — `module_loaded?` alone can't see this (the atom is still loaded).
  """
  def token(m) when is_atom(m) do
    case :persistent_term.get({__MODULE__, :tokens}, nil) do
      nil -> 0
      tab -> case :ets.lookup(tab, m) do
        [{_, t}] -> t
        [] -> 0
      end
    end
  end

  def token(_), do: 0

  @doc "Is cached generation `tok` still the live generation for module `m` (and is `m` loaded)?"
  def valid?(m, tok) when is_atom(m), do: :erlang.module_loaded(m) and token(m) == tok
  def valid?(_, _), do: false

  # ── GenServer ──────────────────────────────────────────────────────────────────────────────────

  @impl true
  def init(_) do
    n = size()
    :persistent_term.put({__MODULE__, :size}, n)
    # Pre-intern all N atoms NOW so the only generated-module atoms that ever exist are these N. The
    # atoms enter the table here and are reused forever; nothing else mints a generated-module atom.
    atoms = for i <- 0..(n - 1)//1, do: String.to_atom(@prefix <> Integer.to_string(i))
    atoms = List.to_tuple(atoms)
    ctr = :counters.new(@counter_size, [:write_concurrency])
    :persistent_term.put({__MODULE__, :counters}, ctr)
    tokens = ensure_tokens_table()
    # cursor = next slot to try (round-robin). `gen` is a monotonic counter minted into the per-atom token
    # table on each acquire, so a recycled atom's stale cached MFAs are detectable (see token/1, valid?/2).
    {:ok, %{atoms: atoms, n: n, cursor: 0, ctr: ctr, tokens: tokens, gen: 0}}
  end

  defp ensure_tokens_table do
    case :persistent_term.get({__MODULE__, :tokens}, nil) do
      nil ->
        tab = :ets.new(:tl_module_pool_tokens, [:named_table, :public, :set, read_concurrency: true])
        :persistent_term.put({__MODULE__, :tokens}, tab)
        tab

      tab ->
        tab
    end
  rescue
    ArgumentError -> :persistent_term.get({__MODULE__, :tokens})
  end

  @impl true
  def handle_call({:reset, n}, _from, %{ctr: ctr, tokens: tokens} = st) do
    :persistent_term.put({__MODULE__, :size}, n)
    atoms = List.to_tuple(for i <- 0..(n - 1)//1, do: String.to_atom(@prefix <> Integer.to_string(i)))
    # purge any modules sitting in the new slot range so the test starts bounded & clean
    for i <- 0..(n - 1)//1 do
      a = elem(atoms, i)
      if :erlang.module_loaded(a), do: (:code.delete(a); :code.soft_purge(a))
      if :erlang.check_old_code(a), do: :code.soft_purge(a)
    end

    for i <- 1..@counter_size, do: :counters.put(ctr, i, 0)
    # keep `gen` monotonic across resets so a recycled atom never reuses an old token value.
    {:reply, :ok, %{st | atoms: atoms, n: n, cursor: 0, ctr: ctr, tokens: tokens}}
  end

  def handle_call(:acquire, _from, %{n: n, cursor: cursor, atoms: atoms, ctr: ctr, tokens: tokens, gen: gen} = st) do
    :counters.add(ctr, @c_acquires, 1)

    case find_slot(atoms, n, cursor, ctr, 0) do
      {:ok, slot, atom} ->
        tok = gen + 1
        # pin the new generation for this atom: any prior cached MFA on it is now stale (token advanced).
        :ets.insert(tokens, {atom, tok})
        {:reply, {:ok, atom, tok}, %{st | cursor: rem(slot + 1, n), gen: tok}}

      :exhausted ->
        :counters.add(ctr, @c_exhausted, 1)
        {:reply, :exhausted, st}
    end
  end

  # Walk slots round-robin from `cursor`; return the first one we can safely (re)claim. `tried` counts
  # how many slots we've scanned so we stop after a full lap (→ :exhausted).
  defp find_slot(_atoms, n, _slot, _ctr, tried) when tried >= n, do: :exhausted

  defp find_slot(atoms, n, slot, ctr, tried) do
    atom = elem(atoms, slot)

    case displace(atom, ctr) do
      :ok ->
        {:ok, slot, atom}

      :busy ->
        # a live guest is executing the module in this slot — never purge it; try the next slot.
        :counters.add(ctr, @c_skips, 1)
        find_slot(atoms, n, rem(slot + 1, n), ctr, tried + 1)
    end
  end

  # Make `atom` ready to receive a fresh module, under the safe (never-kill-a-guest) protocol.
  #
  #   :ok   — the atom is now free of any *current* version and any purgeable old version; ready to load.
  #   :busy — a guest is still executing code under this atom (old OR current); we did NOT purge it. Skip.
  defp displace(atom, ctr) do
    cond do
      # Clear any lingering OLD version first (a current that was `delete`d in a prior pass but couldn't
      # be purged because a guest was running it). soft_purge removes old code ONLY if no process runs it;
      # `false` ⇒ a guest is still in the old code ⇒ busy, never force it.
      :erlang.check_old_code(atom) ->
        if :code.soft_purge(atom), do: displace(atom, ctr), else: :busy

      :erlang.module_loaded(atom) ->
        # A current version is loaded. `delete` makes it "old" (new lookups can't reach it; in-flight
        # calls keep executing it), then `soft_purge` removes that old version — succeeding ONLY if no
        # guest is still running it. If a guest is mid-execution, soft_purge returns false: we leave the
        # guest running the (now-old) code and report busy. A later acquire retries the purge once it exits.
        :code.delete(atom)

        if :code.soft_purge(atom) do
          :counters.add(ctr, @c_evictions, 1)
          :ok
        else
          :busy
        end

      true ->
        :ok
    end
  end

  defp server do
    case Process.whereis(__MODULE__) do
      nil ->
        # Not started (e.g. `mix run --no-start` / a bare test) — start an unsupervised instance so the
        # pool still works. Idempotent under races.
        case start_link([]) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      pid ->
        pid
    end
  end

  defp counters do
    case :persistent_term.get({__MODULE__, :counters}, nil) do
      nil ->
        _ = server()
        :persistent_term.get({__MODULE__, :counters})

      c ->
        c
    end
  end
end
