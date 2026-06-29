# tiny-lasers — roadmap

## Mission

The **standalone, publishable execution substrate**: run untrusted multi-language code
isolated on the BEAM. Extract it out of the heavy nexus mix project, prove it, **publish it**,
then **vendor it back into nexus**. WASM-on-BEAM is the substrate; the work is making the
WASM→BEAM lowering more native/efficient, migrating off it only where it truly can't reach.

## Layering (keep it clean — no compilers/product in here)

`nexus → tiny-lasers`, never the reverse.

| In **tiny-lasers** (substrate) | Stays in **nexus** (consumer) |
|---|---|
| `TinyLasers.Wasm.*` — WASM→BEAM runtime (was Washy) | the `.work` product, dogfood, DeployKit |
| `TinyLasers.Gate.*` — JS→BEAM capability gate | host-backend impls (real Store, rollup host) |
| `TinyLasers.Js.*` — Porffor compiler + predictive conformance | rollup/npm integration wrappers |
| `TinyLasers.Wasm.HostRollup` — Rust parser sibling module | vite CLI orchestration wrappers |
| capability / host-import surface | |

## Done

- **Scaffold + Lane 1 (gate).** Clean mix project, zero third-party deps. `TinyLasers.Gate`
  (JS→BEAM, red-team **18/18**).
- **Runtime extracted.** The full Washy WASM→BEAM runtime (27 modules: decode / transpile /
  transpile_asm / asm_ops / validate / trap / module_pool / jit_cache / wat / fd_table /
  host_* / vfs / actor / ...) moved out of nexus and **renamed `Nexus.Washy → TinyLasers.Wasm`**.
  Booted by `TinyLasers.Application`. Decoupled — only a `TinyLasers.Store` stub stands in for
  the throwaway VFS `{:store}` backend. Dropped nexus-product wrappers (session/sandbox/oracle/
  host_rollup). **Suite: 125 tests, 0 failures, 1 skipped.**
- **Faithfulness proven.** The 1 skip (asm EH-op fallback) **fails identically in nexus** — a
  pre-existing bug we inherited, not extraction damage. The runtime behaves byte-for-byte as it
  did inside nexus.
- **JS runs through tiny-lasers, byte-identical.** Real Porffor-compiled `.wasm` fixtures (generated
  + node-validated on the nexus lane, checked in as bytes) run on `TinyLasers.Wasm`'s transpile lane
  identically to node — across the **hard surface rollup/vite need**: closures + loop-capture, regex
  (replace + match-groups), heap bigint, float repr / `toFixed`, Map/Set, template literals,
  spread/rest, try/catch + `instanceof`, typed arrays, sort, optional chaining, `padStart`. The
  Porffor **compiler stays in nexus**; only its output is exercised here (`tools/gen_porffor_fixtures.exs`).
- **Host-call I/O bridge proven.** A Porffor guest calling `__host('echo_upper', …)` round-trips bytes
  through linear memory via the `e` import — the exact memory-exchange ABI rollup's `__host('rollup_parse')`
  rides, proven decoupled from nexus's rollup machinery (Rust parser, render path).
- **Zero-dep restored.** Removed a phantom `Jason` dependency (the JS↔BEAM `Term`/`host_call` wire
  format would have raised the moment any fs/`Beam.*` path was hit — the rollup critical path) with a
  self-contained `TinyLasers.Wasm.Json` codec. Fitting a supply-chain-isolation substrate: still **zero
  third-party deps**. Locked by `json_test` + the migrated `beam_host_test` bridge round-trip.
- **Suite: 171 tests, 0 failures, 1 skipped** — stable across seeds (the two first-spike gate atom
  red-team tests were hardened from a flaky global `atom_count` proxy to the precise invariant).

### Then, this session

- **WASIX is LOCKED (lanes 2–3, C + Rust).** The full conformance suite (14 real recompiled binaries,
  11MB of fixtures) runs on `TinyLasers.Wasm`, interp ≡ asm, exit 42 — C/wasix-libc (socket+poll, fs
  open/write/read, pthreads, termios/tty, TCP server) and Rust/wasix (std threads, rayon, **tokio**,
  serde_json+regex, flate2+sha2, float, num-bigint, trait-objects, std::net). Blink is **dropped** —
  recompile-to-WASIX is the clean ABI→BEAM seam; Blink only earns its keep for opaque prebuilt x86.
- **The ABI translates to BEAM-resident resources.** `fd_read` dispatches on fd kind: files → VFS,
  pipes → BEAM processes, sockets → host BEAM. Linear memory holds only the transient syscall buffer.
- **The washy shell runs ("bash in WASM").** `priv/shell/sh.c` → `wasm32-wasip1` (`tools/build_shell.sh`),
  run on the runtime interp ≡ asm: builtins, **fork-less pipelines** (buffered chaining), `for`/`if`
  grammar, and `> /work/f` redirect persisting into the BEAM-resident VFS.
- **Rename complete.** Internal `:washy_*` atoms → `:tl_*` (was module-namespaces only); branding swept;
  `:nexus_washy_metric_reasons` (wrongly nexus-branded) → `:tl_metric_reasons`. Nothing reads "washy".
- **Suite: 203 tests, 0 failures, 1 skipped.**

- **Predictive conformance stack.** Tiered gates before expensive test262/npm runs:
  `TinyLasers.Js.Conformance`, preflight scanner, invariant gate (`check_invariants.cjs`),
  census, ASM coverage report, signature-driven test262 re-runs. CLI: `mix porffor.check`.
  Hard-fail CI: invariants + closure corpus. Reporting: census/preflight/coverage.
- **Rollup ladder ported.** `TinyLasers.Wasm.HostRollup` (Rust `@rollup/wasm-node` parser as sibling
  module), `PorfforHost` rollup ops un-stubbed, conformance fixtures at
  `test/conformance/rollup/`, node shims at `compilers/js/node/`. ExUnit: parser byte-match +
  Porffor bridge (`rollup_parse` / `rollup_parse_b64`). Gate driver:
  `mix run test/conformance/rollup/scaffold/real_run.exs` (full 1.27MB bundle, reporting).
- **Ladder rungs wired (baselines locked).**
  - Rung 2 **acorn**: compiles + runs (~59s); tokenizer state-machine gap (all probes ERR) — tracked in
    `acorn_corpus_test.exs` + golden at `test/conformance/acorn_corpus.golden.txt`.
  - Rung 6 **rollup bundle**: compile blocked by `INV-CAPTURE-BOUND` on closure_convert — predictive
    invariant gate catches before 5-min run (`rollup_bundle_gate_test.exs`).

### This session — the native-speed lever (R0)

- **Found the dominant cost: hot f64-load funcs bailed to the interpreter.** The asm (BEAM-assembly)
  lane lowered integer memory ops but **not f32/f64 load/store**, so Porffor's hot tokenizer loops
  (JS numeric values are stored as f64 → every value read/write is an f64.load) ran *interpreted*.
  Coverage showed asm_pct=81% yet tier-async was NO faster than pure interp — the 81% were cheap leaf
  fns, the 19% interp were the expensive hot parser fns. Measured with a new `with_bench/1` per-seam
  counter + `TranspileAsm.diagnose_one/2` (reports the exact instr that forces a bail).
- **Added f32/f64 load/store to the asm lane** (`AsmOps.Memory` via host seams `guest_fload`/`guest_fstore`,
  bit-identical to interp incl. ±Inf/NaN `{:nonfinite,…}`). **acorn rung: tier-async 84s→29.6s (2.8×),
  eager-asm 117s→26.3s (4.5×); asm now beats interp.** Locked by 7 new f32/f64 oracle cases in
  `asm_memory_test` (finite + nonfinite, unaligned, static offset, OOB trap, store-pops-both). 96 asm
  tests green.
- **Remaining cost quantified.** A 26s acorn run does ~51M remote host-seam calls: **22.6M f64 loads** +
  25M `charge_fuel` + 2.7M i32 loads. Each is a BEAM `call_ext` + bounds check + atomics + decode. This
  is the inherent Porffor value-model tax (tagged [value,type] pairs in linear memory; ~686k f64 loads
  per micro-parse). Next levers: inline the f64/i32 load fast path + fuel charge into BEAM asm (drop the
  `call_ext`), and/or strip the rollup bundle's dead watcher stack before the daily gate run.

## Next (ordered, proof-gated)

1. **Fix rung 2 acorn runtime** — tokenizer `push`/`keyword`/`ecmaVersion` undefined on boxed state
   objects (ASM lane). Use `mix porffor.debug` on acorn probe + DiffTrace when interp ≡ asm diverges.
2. **Fix `INV-CAPTURE-BOUND` on rollup bundle** — closure_convert missing `__env_3299` prelude binding;
   unblocks compile → then run the boss gate.
3. **Climb remaining ladder rungs.** magic-string → mini bundler → rollup run green.
   crypto, density, beam_e2e, env_policy, ...) — some may need helpers/host shims. Locks the
   full runtime behavior in tiny-lasers. *(Done so far: core runtime, beam-host bridge; the
   Porffor JS surface is locked via the fixture bridge instead of porting the compiler-coupled
   `washy_porffor_*` suites.)*
   - **Mature the gate (Lane 1) red-team suite.** These were the FIRST spike at capability-gating
     and aren't fully integrated — several leaned on fragile global-VM proxies (atom_count) rather
     than asserting the invariant directly, so they flaked once the WASM lane ran beside them. The
     idea (guest data never crosses into the atom/MFA/pid domain) is sound but under-extrapolated;
     each red-team row should assert its invariant precisely (as the atom tests now do) and the gate
     itself needs more build-out before it's load-bearing. Treat the gate as a spike, not settled.
2. **WASIX / Linux ABI rebuild** (the big forward work). Replace the throwaway VFS/Store + host
   layer with a proper POSIX/syscall surface (fs→pluggable backend, gated net, clock/rand, no
   host exec) — this is what lets recompiled Rust/Go/C/C++ (lane 2) and emulated binaries
   (lane 3) run. The `TinyLasers.Store` stub and the host_* modules are placeholders for this.
3. **Native-speed lever (R0) — in progress.** Measure how close `TinyLasers.Wasm`'s WASM→BEAM
   lowering gets to native BeamAsm on a compute kernel; improve it. **First win: f32/f64 asm memory
   ops (acorn 3-4.5×).** Next: inline the f64/i32 load + fuel-charge fast paths into BEAM asm to drop
   the ~51M/run remote `call_ext` seam calls; strip the rollup bundle's dead watcher stack for the
   daily gate. This is the differentiating PoC.
4. **Fix inherited bugs** — the asm EH-op fallback (the skipped test), as the transpile lane
   matures.
5. **Full rebrand (optional cleanup).** Internal runtime atoms are still `:washy_*` (ETS / pdict
   keys — consistent and internal, not module namespaces). Sweep to `:tl_*` before publish.
6. **Publish + vendor.** Release tiny-lasers; nexus deletes its own Washy, depends on
   tiny-lasers, and supplies the real Store/host backends.

## Principles

- **Lean.** Substrate only. No compilers, no conformance, no product.
- **Decouple via interfaces**, not direct nexus calls.
- **Proof-driven + incremental.** Each migration step gated by a green suite; never big-bang.
- nexus stays untouched until the publish-and-vendor step — the two run in parallel for now.
