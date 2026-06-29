# tiny-lasers — next steps (inked)

## Mission

tiny-lasers is the **standalone, publishable execution substrate**: run untrusted
multi-language code isolated on the BEAM. It is intended to **replace Washy** (the
WASM→BEAM runtime currently living deep inside `nexus`), be **published as its own
library**, and then be **vendored back into nexus**. Pulling it out of the heavy nexus
mix project is the point — a clean PoC we can prove, publish, and depend on.

## The layering (keep this clean — do NOT drag compilers/product in here)

| Belongs in **tiny-lasers** (substrate) | Stays in **nexus** (consumer) |
|---|---|
| WASM→BEAM runtime (Washy core) | Porffor (JS→WASM **compiler**) |
| JS→BEAM capability gate (`TinyLasers.Gate`) | test262 / rollup conformance harnesses |
| capability / host-import **interface** | the `.work` product, dogfood, DeployKit |
| memory model, sandbox, fuel, heap-cap | host-backend **implementations** (Store-backed VFS, rollup host) |

**Dependency direction: `nexus → tiny-lasers`, never the reverse.** nexus provides the
backends (storage, compiler hooks) through interfaces tiny-lasers defines.

## Current state

- **Phase 0 — DONE.** Scaffolded as a clean mix project (zero third-party deps). Lane 1,
  the **JS→BEAM capability gate**, migrated in as `TinyLasers.Gate.{Runtime,Codegen,Parser,
  Interp}` — red-team **18/18 green**. This is the JS→BEAM work, owned here, free of any
  compiler baggage.
- Washy still lives in `nexus/lib/washy*` (~13k LOC, 28 modules).

## Scoping the Washy extraction (grounded — measured, not guessed)

Washy's coupling is almost all to its **own** `Nexus.Washy.*` sub-modules. The only real
external nexus dependencies to break:

- **`Nexus.Store`** (~10 refs) — the storage backend behind the VFS.
- **`Nexus.Compilers`** (1 ref) — a single hook.
- **`host_rollup.ex`** — rollup-specific; does **not** migrate (stays in nexus, plugs in via
  the host-import interface).

So the extraction is: a small decoupling seam + a mechanical namespace rename. Not a rewrite.

## Next steps (ordered, each gated by a green proof)

1. **Define the seams in tiny-lasers** — a `TinyLasers.Store` behaviour (key→bytes,
   tenant-scoped) and a host-import/capability interface. This is the contract that lets the
   runtime depend on *nothing* in nexus.
   *Proof:* compiles standalone; a trivial in-memory Store impl passes a roundtrip test.
2. **Extract Washy core → tiny-lasers** — move the runtime engine (decode, transpile /
   transpile_asm, validate, trap, sandbox, memory, module_pool, jit_cache) renamed
   `Nexus.Washy.* → TinyLasers.Wasm.*`; wire `Nexus.Store` calls to the Store behaviour;
   leave `host_rollup` + the lone `Nexus.Compilers` hook behind in nexus.
   *Proof:* Washy's existing test suite passes **in tiny-lasers standalone** (no nexus dep);
   a WASM module decode→run roundtrip is green.
3. **Native-speed lever (the differentiating PoC)** — measure how close the WASM→BEAM
   lowering gets to native BeamAsm on a tight compute kernel, then improve it. This is the
   "interpret/AOT WASM better for isolation" thesis made concrete.
   *Proof:* a measured slowdown number vs native, and a demonstrated improvement.
4. **Lane-2 host/POSIX layer** — the capability surface (fs→Store, gated net, clock/rand,
   no host exec) so recompiled WASM (Rust/Go/C/C++) runs against it.
   *Proof:* a recompiled C/Rust program runs isolated, fs→Store, byte-correct output.
5. **Publish + vendor** — release tiny-lasers; nexus deletes its Washy copy and depends on
   tiny-lasers, supplying the Store/host backend impls.
   *Proof:* nexus's Porffor/rollup lanes run on the vendored tiny-lasers, suites green.

## Principles

- **Lean.** Substrate only. No compilers, no conformance suites, no product code.
- **Decouple via behaviours**, not direct nexus calls.
- **Proof-driven + incremental.** Migrate a piece only with explicit time and a green gate —
  never big-bang. The monorepo folder is the working copy; publishing comes after the PoC.
