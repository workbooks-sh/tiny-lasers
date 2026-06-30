<p align="center">
<<<<<<< Updated upstream
  <img src="assets/laser-cat.gif" width="200" alt="pew pew" />
  <br />
  <em><sub>a "pew-pew" type sandbox</sub></em>
=======
  <img src="assets/laser-cat.gif" width="200" alt="laser cat" /><br/>
  <em>a "pew-pew" type sandbox</em>
>>>>>>> Stashed changes
</p>

# tiny-lasers

<<<<<<< Updated upstream
**Run untrusted code from any language, safely, on the BEAM — without ever letting it touch the real CPU.**

Isolated, multi-language execution + build sandbox on the BEAM. Home for the
"confine on the BEAM" architecture work (migrated here carefully, after research).

Kept as a **subtree** inside the `workbooks` monorepo; mirrors to
`github.com/workbooks-sh/tiny-lasers`.

---

## Why does this exist?

You want to run other people's code — JS, Rust, Go, C, C++, even whole `npm install`
build pipelines — and you want it to behave *exactly* like it would natively. But you
also can't trust a line of it. So you give it a playground it can't escape: every "pew"
of computation happens inside a sandbox, never on the host.

Two rules make that real, and everything below is just the consequence of taking them
seriously:

1. **Many languages, behaving natively.** Not just JS. Rust/Go/C/C++ are in scope — that
   was the original pull toward WebAssembly, since every one of them has a WASM target.
2. **Nothing untrusted runs on the real CPU.** No NIFs, no native execution, ever.
   Isolation comes from the BEAM (per-process) + the execution sandbox.

Rule 2 is the load-bearing one. It means **untrusted execution must be either BEAM
bytecode or WASM-on-Washy** — there is no third substrate. Keep that in your pocket; it
explains every design choice that follows.

## The goal
=======
**A BEAM-native sandbox for running real, untrusted runtimes from any language — by compiling them to WebAssembly and executing that WASM _on the BEAM itself_, never as native code.**

---

## What is tiny-lasers?
>>>>>>> Stashed changes

The Erlang VM (the BEAM) already runs the most-isolated processes in production computing: every process has its own heap, is preemptively scheduled, and fails alone — one crash takes down one process, never the node. tiny-lasers turns that guarantee into a universal code sandbox.

<<<<<<< Updated upstream
## The decisive logic

Here's the bit that surprises people. What happens when the code is a **prebuilt native
binary** — no source, can't recompile?

> To run a native binary under "no native execution," you must **emulate a CPU**, and
> that emulator must itself run as **WASM-on-Washy**. Every *faster* option
> (WSL1, User-Mode-Linux, gVisor, an emulator-as-native-NIF) runs native code on the host
> CPU — forbidden by constraint 2. So the slowness of CPU emulation is **irreducible**:
> it is the cost of emulating a CPU *because you are not allowed to use the real one*.

In other words: the slowness isn't a bug to optimize away, it's the price of admission.
This is why "is blink it?" has a precise answer: a CPU-emulator-compiled-to-WASM is the
**only possible shape** for the run-a-prebuilt-native-binary lane. blink is one candidate
engine for that lane — not the architecture.
=======
Untrusted code in **any language with a WASM target** — JavaScript, Rust, Go, C, C++ — is compiled ahead-of-time to WebAssembly, and that WASM is then executed **inside the BEAM**: decoded and interpreted in pure Elixir, and JIT-transpiled to BEAM assembly when it gets hot. The result is that every guest runs _as a real BEAM process_. There is no native execution path for untrusted code, ever.

JavaScript is the most-developed lane today — tiny-lasers carries a from-scratch JS→WASM compiler — but the thesis is general: **many languages, one BEAM-isolated WASM execution substrate.**

## Why the BEAM?

Because the isolation primitives you want for a sandbox are the ones the BEAM was built on 30 years ago:

- **Per-process heaps** → memory isolation is structural, not bolted on. A guest's memory is the process's memory.
- **Preemptive scheduling (reduction counting)** → a guest can't starve its neighbors or wedge a scheduler. Fairness is enforced by the VM.
- **Fault isolation** → a guest trap is a caught exception that kills exactly one process. Supervision restarts it. Nothing else notices.
- **OTP supervision** → guests are ordinary supervised processes with the same lifecycle, monitoring, and teardown as everything else on the node.

When WASM executes _as BEAM code_, the WASM sandbox and the BEAM's process model stack: the guest is doubly contained, and it inherits every one of these guarantees for free. See the runtime moduledoc in [`lib/tiny_lasers/wasm.ex`](lib/tiny_lasers/wasm.ex).
>>>>>>> Stashed changes

## How it works

<<<<<<< Updated upstream
People say "Linux emulation" to mean two very different amounts of work. They cost wildly
different things:

| | (i) Linux **ABI** on WASM | (ii) Linux **machine** on WASM |
=======
```
  any language  ──►  WebAssembly  ──►  executed ON the BEAM
   (JS, Rust,        (standard            ├─ interpreted (pure Elixir)
    Go, C, C++)       WASM toolchains)    └─ JIT-transpiled to BEAM assembly (hot fns)
```

1. **Compile to WASM.** Source is lowered to WebAssembly ahead of time — through tiny-lasers' own JS compiler, or any standard toolchain (`rustc`, `tinygo`, `clang`) for the other languages.
2. **Run it on the BEAM.** [`TinyLasers.Wasm`](lib/tiny_lasers/wasm.ex) is a WASM decoder + stack-machine interpreter written in pure Elixir. Linear memory is backed by `:atomics` (shared, threadable); host imports are plain Elixir function calls; traps are caught exceptions. Untrusted WASM runs with no native runtime underneath it.
3. **Tier up the hot paths.** Execution starts fully interpreted (zero upfront compile cost). Hot functions are counted and, past a threshold, transpiled in the **background** to BEAM _assembly_ — `{function, ...}` opcode tuples compiled via `:compile.forms/2` and JIT'd to native by BeamAsm. WASM opcodes map nearly 1:1 to BEAM asm, so the lowering is linear and the transpiled function is bit-identical to the interpreter. This is the [`TranspileAsm`](lib/tiny_lasers/wasm/transpile_asm.ex) lane; it runs async via [`transpile/async_compiler.ex`](lib/tiny_lasers/wasm/transpile/async_compiler.ex). A guest can trampoline between transpiled and interpreted functions transparently.
4. **Confine it.** Loops are fuel-bounded (runaway guests trap `:out_of_fuel`), and a capability gate ([`TinyLasers.Gate`](lib/tiny_lasers/gate.ex)) restricts which host functions a guest can reach — every external module/BIF in the emitted bytecode is inspected, and a non-empty set of dangerous references is an escape that's rejected.

## How it compares

There are two common ways to run WASM in or near Elixir/production sandboxes. Both put untrusted code on a native code path; tiny-lasers does not.

<table>
  <thead>
    <tr>
      <th align="left"></th>
      <th align="left">Native runtimes<br/><sub>Wasmer / Wasmtime</sub></th>
      <th align="left">WASMEX<br/><sub>Wasmtime via a NIF</sub></th>
      <th align="left"><b>tiny-lasers</b></th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td align="left"><b>Execution model</b></td>
      <td align="left">WASM → native machine code</td>
      <td align="left">WASM → native machine code, inside a NIF</td>
      <td align="left">WASM → BEAM (interpreted + JIT'd to BEAM asm)</td>
    </tr>
    <tr>
      <td align="left"><b>Isolation rests on</b></td>
      <td align="left">WASM sandbox + the OS (processes)</td>
      <td align="left">the WASM sandbox only — the NIF has none</td>
      <td align="left">the BEAM process model + the WASM sandbox</td>
    </tr>
    <tr>
      <td align="left"><b>Crash blast radius</b></td>
      <td align="left">the OS process / subprocess</td>
      <td align="left"><b>the whole node</b> (a NIF fault crashes the VM)</td>
      <td align="left">one process</td>
    </tr>
    <tr>
      <td align="left"><b>Native-escape surface</b></td>
      <td align="left">yes — a runtime bug escapes natively</td>
      <td align="left">yes — runs native inside the VM</td>
      <td align="left"><b>none</b> for untrusted guests</td>
    </tr>
    <tr>
      <td align="left"><b>Scheduling</b></td>
      <td align="left">OS scheduler</td>
      <td align="left">blocks BEAM schedulers during long calls</td>
      <td align="left">preemptive, reduction-counted</td>
    </tr>
  </tbody>
</table>

**Native runtimes (Wasmer / Wasmtime)** compile WASM to native machine code. Isolation rests on the WASM sandbox plus the operating system — untrusted code still runs natively, a runtime bug is a native escape surface, and the guest lives outside the BEAM's supervision, scheduling, and fault model.

**WASMEX**, the Elixir WASM library, wraps a native runtime (Wasmtime) through a **NIF**. NIFs execute native code _inside_ the BEAM VM with no isolation: a crashing or misbehaving NIF can take down the entire node, and a long-running native call can block the schedulers. You get WASM, but you give up the BEAM's core guarantees.

**tiny-lasers** executes WASM _as BEAM code_. Every guest is a genuine BEAM process — preemptively scheduled, fault-isolated, fuel-bounded — with no native code path for untrusted guests. The differentiator isn't "WASM next to the BEAM." It's **WASM _as_ the BEAM.**

## Languages

**JavaScript — the built-out lane.** tiny-lasers vendors and customizes [**Porffor**](compilers/js/porffor/), an ahead-of-time JS/TS→WASM compiler: it compiles the _program itself_ to a small WASM module rather than shipping an engine that interprets it. The lane is validated by a conformance harness ([`lib/tiny_lasers/js/`](lib/tiny_lasers/js/), [`test/conformance/`](test/conformance/)) that compiles real npm packages and diffs their output **byte-for-byte against Node** — acorn, marked, bignumber.js, dayjs and more ship as checked-in golden corpora (`*-X.Y.Z.js` + `*_corpus.golden.txt`). Development climbs a **conformance ladder** of progressively harder real targets (acorn → magic-string → rollup → svelte → vite → node), each rung exercising more of the language until it's identical to native Node.

**Rust, Go, C, C++ — via standard toolchains.** Anything that targets WASM runs on the same substrate through a WASI/WASIX POSIX layer ([`host_fs.ex`](lib/tiny_lasers/wasm/host_fs.ex), [`host_net.ex`](lib/tiny_lasers/wasm/host_net.ex), [`host_sock.ex`](lib/tiny_lasers/wasm/host_sock.ex), [`host_proc.ex`](lib/tiny_lasers/wasm/host_proc.ex)). The conformance fixtures are real:

- **Rust** — threaded and async workloads: `rust_threads`, `rust_rayon`, `rust_tokio`, `rust_net`, `rust_parse`, `rust_bignum`, `rust_float` ([`test/conformance/wasix/`](test/conformance/wasix/)).
- **POSIX** — `unix_pthread`, `unix_socket_poll`, `unix_tcp_server`, `unix_termios` — pthreads, sockets, polling, and termios, served by the host layer.
- **Go & C++** — `go_sort`, `cpp_stl` compiled from `.go` / `.cpp` sources ([`test/conformance/native/`](test/conformance/native/)).

Threads, sockets, and pthreads all resolve to host imports on the BEAM — shared linear memory via `:atomics`, no native syscall path for the guest.

## Architecture

| Component | Path | Role |
>>>>>>> Stashed changes
|---|---|---|
| WASM runtime | [`lib/tiny_lasers/wasm.ex`](lib/tiny_lasers/wasm.ex) | Pure-Elixir decoder + stack-machine interpreter; `:atomics`-backed shared memory; content-addressed module cache; tiering. |
| BEAM-asm JIT | [`lib/tiny_lasers/wasm/transpile_asm.ex`](lib/tiny_lasers/wasm/transpile_asm.ex) | Lowers hot WASM functions to BEAM assembly, compiled + JIT'd to native; bit-identical to the interpreter. |
| Async tiering | [`lib/tiny_lasers/wasm/transpile/async_compiler.ex`](lib/tiny_lasers/wasm/transpile/async_compiler.ex) | Background compilation so a run never stalls on a tier-up. |
| Host / WASI layer | [`lib/tiny_lasers/wasm/host_*.ex`](lib/tiny_lasers/wasm/) | WASI/WASIX imports: filesystem (VFS), net, sockets, processes, crypto, I/O. |
| Capability gate | [`lib/tiny_lasers/gate.ex`](lib/tiny_lasers/gate.ex) | Confines guests to a granted set of host capabilities; rejects dangerous bytecode references. |
| JS lane | [`lib/tiny_lasers/js/`](lib/tiny_lasers/js/) | Porffor host bindings, host objects, conformance harness. |
| JS compiler | [`compilers/js/porffor/`](compilers/js/porffor/) | Vendored + customized Porffor JS→WASM ahead-of-time compiler. |

Zero third-party runtime dependencies — the substrate is just Elixir and the BEAM.

---

<<<<<<< Updated upstream
The trick is not to pick one substrate, but to route each workload to the cheapest lane
that can run it. Fastest first:

1. **JS → BEAM capability gate** — *fastest, JS only.* No WASM at all. Native BEAM,
   confined by a handle-gate, free GC. (Spike proven: see status below.)
2. **Recompile → WASM** against a fuller-POSIX layer in Washy (the **(i)** path) — *fast,
   source-available.* Covers everything we build: Rust/Go/C/C++.
3. **Emulate → WASM** (the **(ii)** path, blink/v86/TinyEMU compiled to WASM) — *slow,
   prebuilt-only.* The compatibility fallback, batch/build lane.

Pick per workload. Most of the workload lands in lanes 1–2; lane 3 is the contained
fallback for what can't be recompiled.

## Why an emulator-as-WASM is coherent (and a security upgrade)

There's a neat twist here. blink is explicitly **not** a security sandbox ("meant to run
*trusted* binaries"). Compiling it to WASM **neutralizes that weakness**: a blink-WASM
module can only call the imports Washy grants it, so even a blink bug cannot escape Washy.
The untrusted x86 guest is doubly contained — blink emulates it; Washy confines blink.
**The trusted core is Washy + the import layer, not blink.**

## Requirements for "Linux emulation done correctly" for us

For lane 3 to count as "done correctly," an emulator has to clear all of these:

1. Compiles to WASM/WASI and runs on Washy (no NIF).
2. Emulates syscalls **internally**, so we redirect them via Washy imports:
   FS → Store/VFS, network denied or gated, clock/rand controlled, no host exec.
3. Security boundary = the WASM sandbox (the emulator need not be hardened).
4. Supports the syscalls real toolchains need **in the WASM build**: fork/clone/exec,
   threads, mmap, pipes. (This is where blink-to-WASM is most at risk.)
5. Per-run teardown frees the whole emulated address space (it lives in the WASM
   instance's linear memory; process death reclaims it — arena-on-exit, no GC needed for
   batch builds).
6. Tolerable performance for the **build lane** (batch). Must be measured on a real build.
7. Deterministic where byte-exact output matters (controlled clock/rand/env).
=======
<sub>Mirrored to <a href="https://github.com/workbooks-sh/tiny-lasers">github.com/workbooks-sh/tiny-lasers</a>.</sub>
>>>>>>> Stashed changes
