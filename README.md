# tiny-lasers

Isolated, multi-language execution + build sandbox on the BEAM. Home for the
"confine on the BEAM" architecture work (migrated here carefully, after research).

Kept as a **subtree** inside the `workbooks` monorepo; mirrors to
`github.com/workbooks-sh/tiny-lasers`.

---

## The goal

Run **untrusted code in many languages** (JS, Rust, Go, C, C++) — including a real
build pipeline (the npm/Rollup supply chain, native toolchains) — **isolated,
byte-identical to native**, denser than containers/microVMs.

## The two hard constraints (these drive every decision)

1. **Multi-language native.** Not just JS. Rust/Go/C/C++ are in scope — that was the
   original pull toward WebAssembly (every one of them has a WASM target).
2. **No NIFs / no native execution.** Untrusted code may **never** run on the real host
   CPU. Isolation comes from the BEAM (per-process) + the execution sandbox.

Constraint 2 is the load-bearing one. It means: **untrusted execution must be either
BEAM bytecode or WASM-on-Washy.** There is no third substrate.

## The decisive logic

> To run a **native binary** under "no native execution," you must **emulate a CPU**, and
> that emulator must itself run as **WASM-on-Washy**. Every *faster* option
> (WSL1, User-Mode-Linux, gVisor, an emulator-as-native-NIF) runs native code on the host
> CPU — forbidden by constraint 2. So the slowness of CPU emulation is **irreducible**:
> it is the cost of emulating a CPU *because you are not allowed to use the real one*.

This is why "is blink it?" has a precise answer: a CPU-emulator-compiled-to-WASM is the
**only possible shape** for the run-a-prebuilt-native-binary lane. blink is one candidate
engine for that lane — not the architecture.

## "Linux emulation" is two different things — don't conflate them

| | (i) Linux **ABI** on WASM | (ii) Linux **machine** on WASM |
|---|---|---|
| What | give Linux/POSIX syscalls to programs you **recompile** to WASM | emulate the **x86 CPU + Linux**, run **prebuilt** ELF binaries |
| CPU emulation | **none** | **yes** |
| Speed | fast (one layer: WASM→BEAM) | slow (x86→emulator→WASM→BEAM) |
| Needs | source / recompile | nothing — runs any binary |
| Tech | WASI, Wasix, WALI | blink, v86, TinyEMU, QEMU-wasm |

Code we **build** (Rust/Go/C/C++) goes through **(i)** — recompile to a fuller-POSIX WASM
target, run on Washy, near-native. **(ii)** is only for the **prebuilt long tail** —
closed binaries, npm native addons we didn't compile, tools with no usable source.

## The architecture: three lanes by speed

1. **JS → BEAM capability gate** — *fastest, JS only.* No WASM at all. Native BEAM,
   confined by a handle-gate, free GC. (Spike proven: see status below.)
2. **Recompile → WASM** against a fuller-POSIX layer in Washy (the **(i)** path) — *fast,
   source-available.* Covers everything we build: Rust/Go/C/C++.
3. **Emulate → WASM** (the **(ii)** path, blink/v86/TinyEMU compiled to WASM) — *slow,
   prebuilt-only.* The compatibility fallback, batch/build lane.

Pick per workload. Most of the workload lands in lanes 1–2; lane 3 is the contained
fallback for what can't be recompiled.

## Why an emulator-as-WASM is coherent (and a security upgrade)

blink is explicitly **not** a security sandbox ("meant to run *trusted* binaries").
Compiling it to WASM **neutralizes that weakness**: a blink-WASM module can only call the
imports Washy grants it, so even a blink bug cannot escape Washy. The untrusted x86 guest
is doubly contained (blink emulates it; Washy confines blink). **The trusted core is Washy
+ the import layer, not blink.**

## Requirements for "Linux emulation done correctly" for us

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

## Open research (do before migrating anything)

- **R1 (make-or-break):** Does blink compile to WASM/WASI cleanly, and does the WASM build
  keep fork/clone/threads/mmap? Justine's work targets native portability (APE), not WASM —
  this is unproven and may be a blocker. **v86 / TinyEMU already run as WASM** (boot Linux
  in the browser) and are the proven fallback if blink doesn't.
- **R2:** Perf. Run a real native binary under the chosen emulator-on-Washy; measure the
  slowdown vs. an acceptable build-lane threshold.
- **R3:** Evaluate v86 / TinyEMU / QEMU-wasm as lane-3 engines alongside blink.
- **R4:** Scope the fuller-POSIX layer for Washy (the lane-2 path): which syscalls beyond
  WASI (threads, fork/exec, sockets-gated, fs→Store) and recompile-feasibility per language.
- **R5:** Decide the lane split — enumerate which prebuilt binaries are *truly* unavoidable
  (and thus actually need lane 3).

## Status

- **Lane 1 (JS→BEAM gate): proven.** Confinement holds against static + dynamic (eval) code,
  with a mechanical bytecode gate (`dangerous_refs`). Currently lives in the monorepo at
  `nexus/lib/nexus/guest_gate/` + `nexus/test/guest_gate_*redteam_test.exs` (commits
  `b5b400d8`, `1f89b58b`) — to migrate here deliberately, after the research above.
- Lanes 2–3: research stage (R1–R5).

> Docs here are Markdown for now; migrate to `.work` once the reactor is bootstrapped in
> this repo.
