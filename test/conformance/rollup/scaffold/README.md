# Rollup Porffor-ASM-lane scaffold (canonical — no longer in /tmp)

The hand-assembled driver that runs the full Rollup bundle on the Porffor→Washy ASM lane and walks the
init/feature gaps. Recovered from `/private/tmp` and committed here so it is never "lost" again.

- `rollup_node.js` — the assembled guest: pre-declared globals (`var require, module, …, __host`) so bare
  refs resolve (Porffor can't bind a bare ref from `globalThis.X =`), the byte-ABI host bridge (`__hostCall`
  / `__host`, raw-bytes `rollup_parse`), the inlined node shims, and the Rollup bundle.
- `node_bridge.js` — the standalone bare-assignment bridge (`require = globalThis.require; …`).
- `run_forced.exs` — the runner: prepends `host_prelude` (minus its `const __host`), force-calls
  `hostCall("echo","")` so the `e` import is emitted, compiles `--pageSize=65536`, runs via
  `Nexus.Washy.call_io` (which keeps `:washy_mem` on a throw, so the throw decode works), and prints the
  frontier (`DONE` / `TRAP` / `THROW t=<type> MSG=[…]`).

Run: `mix run test/conformance/rollup/scaffold/run_forced.exs`
