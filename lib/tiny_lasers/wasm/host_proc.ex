defmodule TinyLasers.Wasm.HostProc do
  @moduledoc """
  The WASIX §6 PROCESS MODEL (wb-yq11) — `proc_spawn`/`proc_exec` (async subprocess → pid),
  `proc_join` (wait → exit status), and signals (`proc_raise`/`proc_signal`/`sigaction` + default
  actions + EINTR). The HOST half of the syscalls; the guest call-site (interpreter OR asm lane)
  lowers to `call_ext invoke_host`, so this one impl serves both lanes — same shape as `HostSock`.

  ## ⬛ THE EMULATION ⬛ (cause-and-effect matches; the method is emulation — read CLAUDE.md thesis)
  There is no real fork/exec/process. A "subprocess" is a MONITORED BEAM process running
  `TinyLasers.Wasm.host_exec/3` (the cooperative fork+exec+wait already proven against real Rust
  coreutils). We run it ASYNC: spawn it, return the pid immediately, and let `proc_join` collect the
  exit status later. The guest only needs to BELIEVE it spawned an OS process.

  ### proc_spawn — async subprocess  (ABI we chose, DOCUMENTED)
      proc_spawn(name_ptr, name_len,    -- argv[0] program name (resolved via :washy_programs)
                 args_ptr, args_len,    -- the REMAINING argv, NEWLINE-delimited (one arg per line)
                 env_ptr,  env_len,     -- environment, NEWLINE-delimited "K=V" (currently recorded,
                                            not yet injected into the child's WASI env — documented gap)
                 stdin_fd,              -- fd whose buffered bytes become the child's stdin (-1 = none)
                 stdout_fd,             -- pipe fd the child's stdout is written to (-1 = capture only)
                 stderr_fd,             -- reserved; merged into stdout in this model (-1 = capture)
                 ret_pid_ptr) -> errno  -- writes the allocated pid (u32) here; returns 0 on success
  We pick NEWLINE-delimited args/env (not NUL) because it is trivially representable from a `washy`
  shell and unambiguous for the tests; a guest that hands NUL-delimited bytes is split the same way
  (we split on both "\n" and "\0"). DOCUMENT, don't re-derive.

  ### proc_exec — replace-image  (emulation: run-then-exit)
  True in-place image replacement (the new program inherits the SAME pid and never returns) is not
  meaningful in the BEAM model — there is no native process image to overwrite. The FAITHFUL
  observable behaviour is **run the new image to completion, then exit the caller with the child's
  exit code** (exec never returns on success). So `proc_exec` runs `host_exec` SYNCHRONOUSLY and then
  `throw {:washy_exit, code}` — exactly what a real `execve` looks like from the outside.

  ### proc_fork — TRUE return-twice fork (on the reified-stack interpreter lane, wb-nsrp)
  `proc_fork` returns 0 in the child and the child pid in the parent. We don't need asyncify or native
  stack capture: the run is executed on the REIFIED-stack interpreter (`TinyLasers.Wasm.tramp`, `cps:
  true`), whose call/control stack is an explicit copyable `frames` list — so AT the proc_fork host
  boundary the guest continuation is in hand. `TinyLasers.Wasm.fork_cps` snapshots linear memory + globals
  into a child BEAM process and resumes that continuation twice (child over the copied memory, pid-out
  = 0; parent pid-out = child pid). `register_fork_child/0` here just allocates the pid + inserts the
  :running registry entry the child reports its exit to. The legacy 2-arg `fork/2` seam (no reified
  stack, e.g. a transpiled-only run) still returns ENOSYS so such a guest falls back to proc_spawn.

  ## State model — ONE home: the `:washy_procs` process-dict map
  `:washy_procs` (parent run's process dict) maps `pid -> %{...}`:
      %{os_pid: pid,                     -- the allocated WASIX pid (>= 2; 1 = the root run)
        beam: beam_pid,                  -- the monitored worker BEAM process (nil after reap)
        ref: monitor_ref,
        status: :running | {:exited, code} | {:signaled, sig},
        argv: [..],                      -- the resolved command line
        output: binary,                  -- the child's captured stdout (filled on completion)
        stdio: {stdin_fd, stdout_fd, stderr_fd},
        pending: MapSet,                 -- signal numbers raised but not yet acted on
        handlers: %{signum => :default | :ignore | handler_func_idx},
        mask: MapSet}                    -- blocked signals (recorded; full masking deferred)
  pids are allocated from a per-run counter (`:washy_proc_ctr`) STARTING AT 2 (1 is the root run).

  The child BEAM process has its OWN process dict (it can't write the parent's `:washy_procs`), so on
  completion it SENDS `{:proc_exited, pid, code, output}` to the parent; `proc_join` does a BOUNDED
  selective receive for that (or a `:DOWN`), updating `:washy_procs`. A background reaper (the §2
  threads pattern) drains the monitor message so the parent mailbox stays clean and a crash is logged,
  never propagated.

  ## signals  (default actions + EINTR; async handler invocation DEFERRED)
  `proc_raise(sig)` raises a signal on the CURRENT process; `proc_signal(pid, sig)` on a target.
  Delivery:
    * SIGKILL(9) / SIGTERM(15) / SIGINT(2) default → TERMINATE the target: kill its worker, record
      `{:signaled, sig}`.
    * SIGCHLD(17) / SIGURG(23) default → IGNORE.
    * any other signal → per the registered handler, else default-terminate.
    * if a guest `sigaction` handler is registered, we record the signal PENDING for the guest to
      observe at a poll point (`sigpending`-style) — we do NOT invoke the handler func mid-execution.
      Full async signal-handler invocation (re-entering the guest at an arbitrary point) is the
      deferred hard part, like fork-continuation. DOCUMENTED; tracked in bd.
  EINTR: when a target is blocked in a BOUNDED receive (proc_join here; poll_oneoff/futex are a
  follow-up), we send it `{:wb_signal, sig}` so the blocking syscall returns EINTR (WASIX errno 27).

  ## errno (WASIX) — the integers already used across washy.ex / host_sock.ex
      success 0 · EAGAIN 6 · EBADF 8 · ECHILD 12 · EINTR 27 · EINVAL 28 · ENOSYS 52 · ESRCH 71
  BOUNDED blocking ONLY (project rule): proc_join caps at `@join_ms`; reaper at `@reap_ms`. Never an
  infinite block; children complete, are reaped, or hit the cap.
  """

  import Bitwise
  alias TinyLasers.Wasm.FdTable
  import TinyLasers.Wasm, only: [read_bytes: 3, write_bytes: 3, host_exec: 2]

  # ── errno (WASIX) ──────────────────────────────────────────────────────────────────────────────
  @e_ok 0
  @e_again 6
  @e_inval 28
  @e_intr 27
  @e_nosys 52
  @e_srch 71
  @e_child 12

  # ── signal numbers (POSIX) ─────────────────────────────────────────────────────────────────────
  @sigint 2
  @sigkill 9
  @sigterm 15
  @sigchld 17
  @sigurg 23

  # bounded caps — NEVER an infinite block (project rule).
  @join_ms 60_000
  @reap_ms 60_000

  @procs :washy_procs
  @ctr :washy_proc_ctr

  # ── registry helpers (ONE home: :washy_procs) ──────────────────────────────────────────────────
  defp procs, do: Process.get(@procs, %{})
  defp put_procs(m), do: Process.put(@procs, m)
  defp get_proc(pid), do: Map.get(procs(), pid)

  defp update_proc(pid, fun) do
    case get_proc(pid) do
      nil -> :error
      p -> put_procs(Map.put(procs(), pid, fun.(p))); :ok
    end
  end

  # per-run pid counter starting at 2 (1 = the root run). Monotonic + distinct.
  defp next_pid do
    n = Process.get(@ctr, 2)
    Process.put(@ctr, n + 1)
    n
  end

  @doc "Test/host seam: snapshot of the process registry for the current run."
  def registry, do: procs()

  @doc "Test/host seam: read a process entry by pid (nil if unknown)."
  def proc(pid), do: get_proc(pid)

  # ── proc_spawn ─────────────────────────────────────────────────────────────────────────────────
  def spawn(mem, name_ptr, name_len, args_ptr, args_len, env_ptr, env_len,
            stdin_fd, stdout_fd, stderr_fd, ret_pid_ptr) do
    name = read_bytes(mem, name_ptr, name_len)
    args = split_list(read_bytes(mem, args_ptr, args_len))
    _env = split_list(read_bytes(mem, env_ptr, env_len))
    argv = [name | args]

    cond do
      name == "" ->
        @e_inval

      true ->
        pid = next_pid()
        # the child's stdin = whatever bytes are buffered behind stdin_fd (a pipe), else "".
        stdin = fd_drain(stdin_fd)
        parent = self()

        # The worker is a FRESH BEAM process with its OWN dict — it must inherit the parent run's
        # program registry + VFS so host_exec can resolve argv[0] (else 127). Snapshot the keys
        # host_exec/call_io read (§2 threads adopt context the same way).
        ctx = %{
          programs: Process.get(:washy_programs),
          vfs: Process.get(:washy_vfs),
          backend: Process.get(:washy_backend),
          rt: Process.get(:washy_rt),
          exec_policy: Process.get(:washy_exec_policy),
          host_dispatch: Process.get(:washy_host_dispatch)
        }

        # MONITORED worker (the §2 spawn_monitor + reaper pattern). It runs the sub-program's wasm
        # module via host_exec (isolated run context — call_io snapshots/restores), captures stdout,
        # and reports back. host_exec swallows :washy_exit/traps and returns {output, code}.
        {beam, ref} =
          Elixir.Kernel.spawn_monitor(fn ->
            if ctx.programs, do: Process.put(:washy_programs, ctx.programs)
            if ctx.vfs, do: Process.put(:washy_vfs, ctx.vfs)
            if ctx.backend, do: Process.put(:washy_backend, ctx.backend)
            if ctx.rt, do: Process.put(:washy_rt, ctx.rt)
            if ctx.exec_policy, do: Process.put(:washy_exec_policy, ctx.exec_policy)
            if ctx.host_dispatch, do: Process.put(:washy_host_dispatch, ctx.host_dispatch)

            {output, code} =
              try do
                host_exec(argv, stdin)
              catch
                # defensive: host_exec already catches exit/traps, but never let the worker crash the run.
                :throw, {:washy_exit, c} -> {"", c}
              end

            send(parent, {:proc_exited, pid, code, output})
          end)

        entry = %{
          os_pid: pid,
          beam: beam,
          ref: ref,
          status: :running,
          argv: argv,
          output: "",
          stdio: {stdin_fd, stdout_fd, stderr_fd},
          pending: MapSet.new(),
          handlers: %{},
          mask: MapSet.new()
        }

        put_procs(Map.put(procs(), pid, entry))
        if ret_pid_ptr >= 0, do: write_u32(mem, ret_pid_ptr, pid)
        @e_ok
    end
  end

  # ── proc_exec — replace-image emulation: run-then-exit (never returns on success) ───────────────
  def exec(mem, name_ptr, name_len, args_ptr, args_len, _env_ptr, _env_len, stdin_fd) do
    name = read_bytes(mem, name_ptr, name_len)
    args = split_list(read_bytes(mem, args_ptr, args_len))

    if name == "" do
      @e_inval
    else
      stdin = fd_drain(stdin_fd)
      {_out, code} = host_exec([name | args], stdin)
      # exec never returns on success — the caller IS the new image, then it exits with its code.
      throw({:washy_exit, code})
    end
  end

  # ── proc_fork — true return-twice fork via the reified-stack interpreter (wb-nsrp) ───────────────
  # The continuation capture + memory copy + child resume lives in TinyLasers.Wasm.tramp (it needs the
  # interpreter's frame stack). This seam just allocates the child pid and inserts a :running registry
  # entry so a later proc_join finds it; the forked child sends {:proc_exited,pid,code,output} to the
  # parent (the run process) on exit, which `join/4` already consumes. Returns the new pid.
  def register_fork_child do
    pid = next_pid()

    entry = %{
      os_pid: pid,
      beam: nil,
      ref: nil,
      status: :running,
      argv: ["<fork>"],
      output: "",
      stdio: {0, 1, 2},
      pending: MapSet.new(),
      handlers: %{},
      mask: MapSet.new()
    }

    put_procs(Map.put(procs(), pid, entry))
    pid
  end

  # legacy 2-arg path (no reified stack available, e.g. a transpiled-only run) still degrades to ENOSYS.
  def fork(_mem, _ret_pid_ptr), do: @e_nosys

  # ── proc_join / wait — BOUNDED block until the child reaches a terminal status ───────────────────
  # flags: bit 0 (1) = WNOHANG (don't block — return EAGAIN if still running).
  def join(mem, pid_ptr, flags, ret_status_ptr) do
    # arg0 is a WASIX `__wasi_option_pid_t` — a tagged optional: {tag:u8@0, pid:u32@+4}. tag 0 = None
    # (wait for ANY child → -1); nonzero = Some(pid). (The real wasix-libc waitpid passes this struct;
    # the unix_fork fixture revealed it — earlier code read the pid at offset 0, i.e. the tag.)
    pid =
      cond do
        pid_ptr < 0 -> -1
        read_u8(mem, pid_ptr) == 0 -> -1
        true -> read_u32(mem, pid_ptr + 4)
      end

    wnohang = (flags &&& 1) != 0

    case get_proc(pid) do
      nil ->
        @e_child

      %{status: {:exited, _}} = p ->
        write_status(mem, ret_status_ptr, p.status)
        @e_ok

      %{status: {:signaled, _}} = p ->
        write_status(mem, ret_status_ptr, p.status)
        @e_ok

      %{status: :running} ->
        if wnohang do
          # WNOHANG: still running → no block, EAGAIN, no status written.
          @e_again
        else
          # BOUNDED selective receive: the worker's {:proc_exited,...}, a {:wb_signal,...} (→ EINTR),
          # or the @join_ms cap. NEVER infinite.
          receive do
            {:proc_exited, ^pid, code, output} ->
              update_proc(pid, fn p -> %{p | status: {:exited, code}, output: output, beam: nil} end)
              reap(pid)
              write_status(mem, ret_status_ptr, {:exited, code})
              @e_ok

            {:wb_signal, _sig} ->
              # a signal interrupted the wait — the POSIX EINTR contract.
              @e_intr
          after
            @join_ms ->
              @e_again
          end
        end
    end
  end

  # ── proc_raise(sig) — signal the CURRENT process (target = self / the root run's pid space) ──────
  # In this model "current process" maps onto the most-recently-spawned child the guest holds; but a
  # guest typically calls proc_signal(pid, sig). proc_raise with no pid raises on EVERY known child's
  # behalf is wrong — instead we treat proc_raise(sig) as "deliver sig to pid in args" via signal/3
  # when a pid is supplied, else record it as a self-pending signal the guest can observe. We expose
  # both; the call_host clause picks the arity.
  def raise_self(sig) do
    # record a self-pending signal (pid 1 = the root run). No worker to kill; default-terminate of
    # SELF would mean exiting the run — we honour SIGKILL/SIGTERM/SIGINT by throwing washy_exit.
    if sig in [@sigkill, @sigterm, @sigint] do
      throw({:washy_exit, 128 + sig})
    else
      @e_ok
    end
  end

  # ── proc_signal(pid, sig) — deliver a signal to a target child ───────────────────────────────────
  def signal(pid, sig) do
    case get_proc(pid) do
      nil ->
        @e_srch

      %{status: {:exited, _}} ->
        @e_srch

      %{status: {:signaled, _}} ->
        @e_srch

      p ->
        handler = Map.get(p.handlers, sig, :default)

        cond do
          handler == :ignore ->
            @e_ok

          is_integer(handler) ->
            # a guest handler is registered — record PENDING for the guest to observe at a poll point.
            # Async mid-execution invocation is DEFERRED (see moduledoc + bd). Still interrupt a block.
            update_proc(pid, fn p -> %{p | pending: MapSet.put(p.pending, sig)} end)
            interrupt(p, sig)
            @e_ok

          sig in [@sigchld, @sigurg] ->
            # default action = ignore (still record pending so sigpending can report it).
            update_proc(pid, fn p -> %{p | pending: MapSet.put(p.pending, sig)} end)
            @e_ok

          sig in [@sigkill, @sigterm, @sigint] or true ->
            # default action = terminate. Kill the worker, record {:signaled, sig}, reap.
            terminate(pid, p, sig)
            @e_ok
        end
    end
  end

  # ── sigaction(sig, act_ptr, oldact_ptr) — register/replace a handler ─────────────────────────────
  # ABI (the slice we use, DOCUMENTED): act_ptr / oldact_ptr point at a `struct sigaction` whose FIRST
  # word (off 0, u32) is `sa_handler` — our convention: 0 = SIG_DFL (:default), 1 = SIG_IGN (:ignore),
  # any other value = a guest FUNCTION TABLE INDEX (the handler func idx). We read/write only that
  # word; the rest of the struct (mask/flags) is recorded as opaque/zero (full mask handling deferred).
  # A pid context: sigaction targets the CURRENT process — pid 1 (the root) by default, or the
  # most-recent child the guest is configuring; we register on pid 1 (the run's own handler table)
  # since a guest installs its OWN handlers. The handlers map lives per-pid in :washy_procs, and we
  # ensure a pid-1 self entry exists.
  def sigaction(mem, sig, act_ptr, oldact_ptr) do
    self_entry = ensure_self()
    old = Map.get(self_entry.handlers, sig, :default)

    # write the OLD handler back (encode :default→0, :ignore→1, idx→idx).
    if oldact_ptr >= 0 do
      write_u32(mem, oldact_ptr, encode_handler(old))
    end

    if act_ptr >= 0 do
      new = decode_handler(read_u32(mem, act_ptr))
      update_proc(1, fn p -> %{p | handlers: Map.put(p.handlers, sig, new)} end)
    end

    @e_ok
  end

  # ── sigpending: bitmask of signals raised but not yet acted on (for the current/self process) ────
  def sigpending(mem, set_ptr) do
    self_entry = ensure_self()
    mask = Enum.reduce(self_entry.pending, 0, fn s, acc -> acc ||| (1 <<< s) end)
    if set_ptr >= 0, do: write_u32(mem, set_ptr, mask &&& 0xFFFFFFFF)
    if set_ptr >= 0 and mask > 0xFFFFFFFF, do: write_u32(mem, set_ptr + 4, mask >>> 32 &&& 0xFFFFFFFF)
    @e_ok
  end

  # ── internals ───────────────────────────────────────────────────────────────────────────────────

  # ensure a pid-1 SELF entry exists (the run's own handler/pending table).
  defp ensure_self do
    case get_proc(1) do
      nil ->
        e = %{
          os_pid: 1,
          beam: nil,
          ref: nil,
          status: :running,
          argv: [],
          output: "",
          stdio: {-1, -1, -1},
          pending: MapSet.new(),
          handlers: %{},
          mask: MapSet.new()
        }

        put_procs(Map.put(procs(), 1, e))
        e

      e ->
        e
    end
  end

  # terminate a child: kill its worker (best-effort), record {:signaled, sig}, reap.
  defp terminate(pid, %{beam: beam} = _p, sig) do
    if is_pid(beam) and Process.alive?(beam), do: Process.exit(beam, :kill)
    update_proc(pid, fn p -> %{p | status: {:signaled, sig}, beam: nil} end)
    reap(pid)
  end

  # interrupt a child blocked in a bounded receive so its syscall returns EINTR.
  defp interrupt(%{beam: beam}, sig) when is_pid(beam) do
    send(beam, {:wb_signal, sig})
  end

  defp interrupt(_p, _sig), do: :ok

  # drain the monitor :DOWN for a reaped child (BOUNDED) so the parent mailbox stays clean; a crash is
  # logged, never propagated — the §2 reaper discipline.
  defp reap(pid) do
    case get_proc(pid) do
      %{ref: ref} when is_reference(ref) ->
        Process.demonitor(ref, [:flush])
        update_proc(pid, fn p -> %{p | ref: nil} end)

      _ ->
        :ok
    end
  end

  # split a NEWLINE- or NUL-delimited byte blob into a list of args/env, dropping empties.
  defp split_list(""), do: []
  defp split_list(bin) do
    bin
    |> String.split(["\n", "\0"], trim: true)
  end

  # drain all buffered bytes behind a pipe fd → the child's stdin. -1 / non-pipe → "".
  defp fd_drain(fd) when fd < 0, do: ""

  defp fd_drain(fd) do
    case FdTable.get(fd) do
      %{kind: :pipe, ref: {pid, _end}} ->
        n = TinyLasers.Wasm.FdTable.Pipe.available(pid)
        if n > 0, do: TinyLasers.Wasm.FdTable.Pipe.read(pid, n), else: ""

      _ ->
        ""
    end
  end

  # WASIX `JoinStatus` struct (what wasix-libc waitpid decodes — NOT the POSIX code<<8 int):
  #   byte 0    = type tag: 1 = ExitNormal, 2 = ExitSignal  (0 = nothing, 3 = stopped)
  #   u16 @ 2   = exit code (ExitNormal) — libc forms WEXITSTATUS = (u16 << 8) >> 8
  #   u8  @ 4   = signal   (ExitSignal) — libc forms WTERMSIG = status & 0x7f
  # (The unix_fork fixture revealed this layout; the earlier POSIX code<<8 int was an invented ABI.)
  defp write_status(_mem, ptr, _status) when ptr < 0, do: :ok

  # NB: write ONLY the struct's own bytes — the guest packs option_pid right after it on the stack
  # (ret_status+6), so an over-wide write corrupts the pid tag → spurious ECHILD (the unix_fork bug).
  defp write_status(mem, ptr, {:exited, code}),
    do: write_bytes(mem, ptr, <<1::little-8, 0, code::little-16>>)

  defp write_status(mem, ptr, {:signaled, sig}),
    do: write_bytes(mem, ptr, <<2::little-8, 0, 0::little-16, sig::little-8>>)

  defp encode_handler(:default), do: 0
  defp encode_handler(:ignore), do: 1
  defp encode_handler(idx) when is_integer(idx), do: idx

  defp decode_handler(0), do: :default
  defp decode_handler(1), do: :ignore
  defp decode_handler(idx), do: idx

  # little-endian u32 read/write through guest linear memory (write_bytes/read_bytes are washy's).
  defp write_u32(mem, addr, val) do
    write_bytes(mem, addr, <<val::little-32>>)
  end

  defp read_u32(mem, addr) do
    <<v::little-32>> = read_bytes(mem, addr, 4)
    v
  end

  defp read_u8(mem, addr) do
    <<v::little-8>> = read_bytes(mem, addr, 1)
    v
  end
end
