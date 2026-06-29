defmodule TinyLasers.WasmWasixCTest do
  @moduledoc """
  **The multi-language native lane: REAL recompiled C and Rust binaries run on tiny-lasers via WASIX.**

  These are unmodified unix programs compiled against wasix-libc / the wasix Rust toolchain — their
  `socket()` / `open()`/`read()`/`write()` / `pthread_*` land on our WASIX host imports (`sock_open`,
  `path_open`/`fd_read`/`fd_write` → VFS, `thread_spawn` + `futex_wait`/`futex_wake` → BEAM processes),
  and they exit with main()'s 42 — IDENTICALLY in the interpreter and the asm/transpile lane (interp ≡ asm,
  the conformance bar). This proves the ABI translates to BEAM-resident resources: nothing is stored in
  WASM linear memory except the transient syscall buffers; files live in the VFS, pipes/threads are BEAM
  processes. Migrated from nexus's `washy_wasix_c_test.exs` (a focused core; the heavier Rust crate
  fixtures — tokio/serde/rayon/bignum — follow once their .wasm are vendored).
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Wasm

  # Concurrency fixtures share process-global futex/thread registries; clear them between tests so the
  # suite is deterministic (each fixture is independently green; only cross-test state caused flakes).
  setup do
    for tab <- [:washy_futex, :washy_threads] do
      try do
        if :ets.whereis(tab) != :undefined, do: :ets.delete_all_objects(tab)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    for pid <- Process.get(:washy_thread_pids, []), is_pid(pid), do: Process.exit(pid, :kill)
    Process.delete(:washy_thread_pids)

    for key <- [:washy_sockstate, :washy_socknext, :washy_fdmap, :washy_descs, :washy_pipes, :washy_thread_id],
        do: Process.delete(key)

    :ok
  end

  @dir Path.join(__DIR__, "../conformance/wasix")

  defp run(mod, transpile?) do
    try do
      Wasm.call_io(mod, "_start", [],
        transpile: transpile?, tier_threshold: 1, tier_async: false, fuel: 1_000_000_000_000)

      :no_exit
    catch
      :throw, {:washy_exit, code} -> {:exit, code}
    end
  end

  test "a wasix-libc unix C binary (socket+poll) runs on tiny-lasers, interp ≡ asm, exits 42" do
    {:ok, mod} = Wasm.decode(File.read!(Path.join(@dir, "unix_socket_poll.wasm")))

    names = MapSet.new(mod.imports, fn {_m, name, _t} -> name end)
    assert "sock_open" in names, "expected the wasix sock_* surface"
    assert "poll_oneoff" in names
    assert "futex_wait" in names, "expected the WASIX futex host import (wasi-libc threads)"

    interp = run(mod, false)
    asm = run(mod, true)

    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)}"
    assert interp == {:exit, 42}, "the unix binary must run and exit with main()'s 42, got #{inspect(interp)}"
  end

  test "a wasix-libc fs program (open/write/read + dlmalloc) runs interp ≡ asm, incl. the warmed JIT lane" do
    {:ok, mod} = Wasm.decode(File.read!(Path.join(@dir, "_memcmp_divergence.wasm")))
    mod = %{mod | id: :wb95w7_memcmp_fixture}

    interp = run(mod, false)
    run(mod, true)  # warm-up: tier_threshold 1 compiles the hot functions to native BEAM
    asm = run(mod, true)

    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)} — asm lane diverged from the oracle"
  end

  test "a wasix-libc pthreads program (2 threads, shared atomic counter) runs interp ≡ asm, exits 42" do
    {:ok, mod} = Wasm.decode(File.read!(Path.join(@dir, "unix_pthread.wasm")))

    names = MapSet.new(mod.imports, fn {_m, name, _t} -> name end)
    assert "futex_wait" in names and ("thread-spawn" in names or "thread_spawn" in names)
    assert match?({_min, _max, :shared}, mod.mem), "expected a shared memory (threaded module)"

    interp = run(mod, false)
    asm = run(mod, true)

    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)}"
    assert interp == {:exit, 42}, "2 threads × 1000 atomic incs must total 2000 → 42, got #{inspect(interp)}"
  end

  test "a real Rust-std threads binary (wasix toolchain) runs interp ≡ asm, exits 42" do
    {:ok, mod} = Wasm.decode(File.read!(Path.join(@dir, "rust_threads.wasm")))

    names = MapSet.new(mod.imports, fn {_m, name, _t} -> name end)
    assert "futex_wait" in names, "expected the WASIX futex host import (Rust std threads)"

    interp = run(mod, false)
    asm = run(mod, true)

    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)}"
    assert interp == {:exit, 42}, "a Rust std 2-thread atomic program must exit 42, got #{inspect(interp)}"
  end
end
