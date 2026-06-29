defmodule TinyLasers.WasmWasixCTest do
  @moduledoc """
  **The multi-language native lane: REAL recompiled C and Rust binaries run on tiny-lasers via WASIX.**

  Unmodified unix programs compiled against wasix-libc / the wasix Rust toolchain run on TinyLasers.Wasm —
  their `socket()`/`open()`/`read()`/`write()`/`pthread_*` land on our WASIX host imports (`sock_*`,
  `path_open`/`fd_read`/`fd_write` → VFS, `thread_spawn` + `futex_wait/wake` → BEAM processes), and they
  exit with main()'s 42 — IDENTICALLY in the interpreter and the asm/transpile lane (interp ≡ asm, the
  conformance bar). This proves the ABI translates to BEAM-resident resources: nothing is stored in WASM
  linear memory except transient syscall buffers; files live in the VFS, pipes/threads/sockets are BEAM.

  Covers C (socket+poll, fs open/write/read, pthreads, termios/tty, TCP server) and Rust (std threads,
  rayon, tokio, serde_json+regex, flate2+sha2, float-heavy, num-bigint, trait-object dispatch, std::net).
  Migrated from nexus's `washy_wasix_c_test.exs`.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Wasm

  # Concurrency fixtures share process-global futex/thread registries; clear them between tests so the
  # suite is deterministic (each fixture is independently green; only cross-test state caused flakes).
  setup do
    for tab <- [:tl_futex, :tl_threads] do
      try do
        if :ets.whereis(tab) != :undefined, do: :ets.delete_all_objects(tab)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    for pid <- Process.get(:tl_thread_pids, []), is_pid(pid), do: Process.exit(pid, :kill)
    Process.delete(:tl_thread_pids)

    for {_id, %{transport: t}} when t != nil <- Map.values(Process.get(:tl_sockstate, %{})) do
      try do
        :gen_tcp.close(t)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    for key <- [:tl_sockstate, :tl_socknext, :tl_fdmap, :tl_descs, :tl_pipes, :tl_thread_id],
        do: Process.delete(key)

    :ok
  end

  @dir Path.join(__DIR__, "../conformance/wasix")
  defp fixture(name), do: Path.join(@dir, name)

  defp run(mod, transpile?) do
    try do
      Wasm.call_io(mod, "_start", [],
        transpile: transpile?, tier_threshold: 1, tier_async: false, fuel: 1_000_000_000_000)

      :no_exit
    catch
      :throw, {:tl_exit, code} -> {:exit, code}
    end
  end

  test "a wasix-libc unix C binary (socket+poll) runs on tiny-lasers, interp ≡ asm, exits 42" do
    {:ok, mod} = Wasm.decode(File.read!(fixture("unix_socket_poll.wasm")))

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
    {:ok, mod} = Wasm.decode(File.read!(fixture("_memcmp_divergence.wasm")))
    mod = %{mod | id: :wb95w7_memcmp_fixture}

    interp = run(mod, false)
    run(mod, true)
    asm = run(mod, true)

    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)} — asm lane diverged from the oracle"
  end

  test "a wasix-libc pthreads program (2 threads, shared atomic counter) runs interp ≡ asm, exits 42" do
    {:ok, mod} = Wasm.decode(File.read!(fixture("unix_pthread.wasm")))

    names = MapSet.new(mod.imports, fn {_m, name, _t} -> name end)
    assert "futex_wait" in names and ("thread-spawn" in names or "thread_spawn" in names)
    assert match?({_min, _max, :shared}, mod.mem), "expected a shared memory (threaded module)"

    interp = run(mod, false)
    asm = run(mod, true)

    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)}"
    assert interp == {:exit, 42}, "2 threads × 1000 atomic incs must total 2000 → 42, got #{inspect(interp)}"
  end

  test "a real Rust-std threads binary (wasix toolchain) runs interp ≡ asm, exits 42" do
    {:ok, mod} = Wasm.decode(File.read!(fixture("rust_threads.wasm")))

    names = MapSet.new(mod.imports, fn {_m, name, _t} -> name end)
    assert "futex_wait" in names and Enum.any?(names, &String.starts_with?(&1, "thread"))
    assert match?({_min, _max, :shared}, mod.mem), "expected an IMPORTED shared memory (threaded module)"
    assert mod.table_type != nil, "expected an IMPORTED function table"
    assert mod.start != nil, "expected a start function (__wasm_init_memory loads passive data)"

    interp = run(mod, false)
    asm = run(mod, true)

    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)}"
    assert interp == {:exit, 42}, "real Rust threads must total 2000 → exit 42, got #{inspect(interp)}"
  end

  @tag timeout: 300_000
  test "a real Rust rayon crate (wasix toolchain) runs interp ≡ asm, exits 42" do
    {:ok, mod} = Wasm.decode(File.read!(fixture("rust_rayon.wasm")))
    mod = %{mod | id: :wb_t5n9_rayon_fixture}

    names = MapSet.new(mod.imports, fn {_m, name, _t} -> name end)
    assert "thread_parallelism" in names, "expected rayon's thread_parallelism import"
    assert match?({_min, _max, :shared}, mod.mem) and mod.table_type != nil and mod.start != nil

    interp = run(mod, false)
    run(mod, true)
    asm = run(mod, true)

    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)} — asm lane diverged from the oracle"
    assert interp == {:exit, 42}, "rayon parallel-sum must be 500500 → exit 42, got #{inspect(interp)}"
  end

  @tag timeout: 300_000
  test "the tokio async runtime (current-thread rt + timer) runs interp ≡ asm, exits 42" do
    {:ok, mod} = Wasm.decode(File.read!(fixture("rust_tokio.wasm")))
    mod = %{mod | id: :wb_t5n9_tokio_fixture}
    assert match?({_min, _max, :shared}, mod.mem) and mod.start != nil

    interp = run(mod, false)
    run(mod, true)
    asm = run(mod, true)

    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)}"
    assert interp == {:exit, 42}, "tokio runtime must drive the async sum → exit 42, got #{inspect(interp)}"
  end

  @tag timeout: 240_000
  test "serde_json + regex (heavy parse/alloc, 5714 fns) runs interp ≡ asm, exits 42" do
    {:ok, mod} = Wasm.decode(File.read!(fixture("rust_parse.wasm")))
    mod = %{mod | id: :wb_t5n9_parse_fixture}

    interp = run(mod, false)
    run(mod, true)
    asm = run(mod, true)

    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)} — asm lane diverged on heavy parse"
    assert interp == {:exit, 42}, "serde_json+regex must compute → exit 42, got #{inspect(interp)}"
  end

  test "a termios C program (raw mode + TIOCGWINSZ) drives the §4 tty, interp ≡ asm, exits 42" do
    {:ok, mod} = Wasm.decode(File.read!(fixture("unix_termios.wasm")))
    mod = %{mod | id: :wb_termios_fixture}

    names = MapSet.new(mod.imports, fn {_m, name, _t} -> name end)
    assert "tty_get" in names and "tty_set" in names, "expected the §4 tty surface"

    TinyLasers.Wasm.Tty.attach(cols: 120, rows: 40)
    interp = run(mod, false)
    asm = run(mod, true)

    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)}"
    assert interp == {:exit, 42}, "termios raw-mode + winsize must work → exit 42, got #{inspect(interp)}"
  end

  @tag timeout: 300_000
  test "a TCP loopback server (bind+listen+accept on a pthread, echo) runs interp ≡ asm, exits 42" do
    {:ok, mod} = Wasm.decode(File.read!(fixture("unix_tcp_server.wasm")))
    mod = %{mod | id: :wb_npcv_tcp_server_fixture}

    names = MapSet.new(mod.imports, fn {_m, name, _t} -> name end)
    assert "sock_open" in names and "sock_bind" in names and "sock_listen" in names,
           "expected the §3 sock_* server surface"
    assert "thread_spawn" in names or "thread-spawn" in names or "thread_spawn_v2" in names,
           "expected the §2 thread surface (pthread server)"

    interp = run(mod, false)
    asm = run(mod, true)

    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)}"
    assert interp == {:exit, 42},
           "the server thread must accept + echo to the main client → exit 42, got #{inspect(interp)}"
  end

  @tag timeout: 300_000
  test "flate2 + sha2 (compression + crypto bit-ops) runs interp ≡ asm, exits 42" do
    {:ok, mod} = Wasm.decode(File.read!(fixture("rust_compute.wasm")))
    mod = %{mod | id: :wb_t5n9_compute_fixture}

    interp = run(mod, false)
    run(mod, true)
    asm = run(mod, true)

    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)} — asm lane diverged on compress/hash"
    assert interp == {:exit, 42}, "zlib round-trip + sha256 must verify → exit 42, got #{inspect(interp)}"
  end

  @tag timeout: 300_000
  test "a float-heavy program (sin integration + transcendentals) runs interp ≡ asm, exits 42" do
    {:ok, mod} = Wasm.decode(File.read!(fixture("rust_float.wasm")))
    mod = %{mod | id: :wb_t5n9_float_fixture}

    interp = run(mod, false)
    run(mod, true)
    asm = run(mod, true)

    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)} — asm lane diverged on float math"
    assert interp == {:exit, 42}, "sin-integration ≈ 2.0 must verify → exit 42, got #{inspect(interp)}"
  end

  @tag timeout: 300_000
  test "num-bigint (158-digit factorial + dual-method modexp) runs interp ≡ asm, exits 42" do
    {:ok, mod} = Wasm.decode(File.read!(fixture("rust_bignum.wasm")))
    mod = %{mod | id: :wb_t5n9_bignum_fixture}
    interp = run(mod, false)
    run(mod, true)
    asm = run(mod, true)
    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)} — asm lane diverged on bignum"
    assert interp == {:exit, 42}, "bignum self-checks must agree → exit 42, got #{inspect(interp)}"
  end

  @tag timeout: 300_000
  test "heavy trait-object dynamic dispatch + recursion (call_indirect) runs interp ≡ asm, exits 42" do
    {:ok, mod} = Wasm.decode(File.read!(fixture("rust_dynamic.wasm")))
    mod = %{mod | id: :wb_t5n9_dynamic_fixture}
    interp = run(mod, false)
    run(mod, true)
    asm = run(mod, true)
    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)} — asm lane diverged on call_indirect"
    assert interp == {:exit, 42}, "vtable dispatch must match inline compute → exit 42, got #{inspect(interp)}"
  end

  @tag timeout: 300_000
  test "Rust std::net TCP loopback echo runs interp ≡ asm, exits 42 (§3 sockets via Rust std)" do
    {:ok, mod} = Wasm.decode(File.read!(fixture("rust_net.wasm")))
    mod = %{mod | id: :rust_net_fixture}

    names = MapSet.new(mod.imports, fn {_m, name, _t} -> name end)
    assert "sock_open" in names and "sock_connect" in names, "expected the wasix sock_* surface via Rust std"

    interp = run(mod, false)
    run(mod, true)
    asm = run(mod, true)
    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)} — asm lane diverged on std::net"
    assert interp == {:exit, 42}, "Rust std::net echo must round-trip → exit 42, got #{inspect(interp)}"
  end
end
