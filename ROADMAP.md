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
| `TinyLasers.Wasm.*` — WASM→BEAM runtime (was Washy) | Porffor (JS→WASM **compiler**) |
| `TinyLasers.Gate.*` — JS→BEAM capability gate | test262 / rollup conformance |
| capability / host-import surface | the `.work` product, dogfood, DeployKit |
| memory, sandbox, fuel, heap-cap | host-backend impls (real Store, rollup host) |

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

## Next (ordered, proof-gated)

1. **Finish the test migration.** Bring the remaining `washy_*` suites (conformance, async,
   crypto, density, beam_e2e, env_policy, ...) — some may need helpers/host shims. Locks the
   full runtime behavior in tiny-lasers.
2. **WASIX / Linux ABI rebuild** (the big forward work). Replace the throwaway VFS/Store + host
   layer with a proper POSIX/syscall surface (fs→pluggable backend, gated net, clock/rand, no
   host exec) — this is what lets recompiled Rust/Go/C/C++ (lane 2) and emulated binaries
   (lane 3) run. The `TinyLasers.Store` stub and the host_* modules are placeholders for this.
3. **Native-speed lever (R0).** Measure how close `TinyLasers.Wasm`'s WASM→BEAM lowering gets to
   native BeamAsm on a compute kernel; improve it. This is the differentiating PoC.
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
