# Research Brief: JS → WASM → BEAM performance (v2 — corrected framing)

**Status:** open research. **Audience:** a researcher without access to our codebase. This document is
self-contained: it gives the architecture, the **measured** cost model, the constraints, and the open
questions. The goal is for you to find real answers (from literature, other JS engines, other JS→WASM
compilers, or original analysis) that we can act on.

> **Read this header before proposing anything.** An earlier draft of this brief framed the bottleneck as
> "`[f64, i8]` values + `trunc_sat` + the type-tag load." We measured it. That framing is **wrong**. Those
> three together cost **~1.2 s of a 20–25 s run**. The actual wall is something else (Section 3.3). If your
> proposal's headline savings come from eliminating `trunc_sat` or halving the type-tag load, you are
> optimizing 5% of the problem. **We will only act on proposals that attack the dominant cost.** Section 6
> lists exactly what we want covered and what we do not.

---

## 1. Executive summary

We run untrusted JavaScript on the Erlang BEAM VM by compiling it to WebAssembly and then executing that
WASM on a WASM→BEAM runtime we built. On a parser benchmark (**acorn 8.17** parsing a corpus of ~33 small
JS programs), execution takes **~20–24 seconds**. We made it ~6× faster this session (117 s → 20 s on the
eager lane) by fixing the WASM→BEAM runtime, then **microbenchmarked every host seam** to find the wall.

The wall, measured:

> **The remaining ~22 s is not slow operations and it is not the host seams. It is a huge NUMBER of cheap
> BEAM operations, and the dominant ones are register/constant churn (`local.get`/`local.set`/`local.tee`/
> `i32.const`/`f64.const`), not loads and not `trunc_sat`.**

Per-operation cost is already near native (BEAM JIT, "BeamAsm", ~1–3 ns/op). The JS→WASM compiler emits
**~19 million WASM operations per parsed token** (~6.3 billion ops for the whole run). The runtime cannot
make a single op cheaper than it already is; the only way forward is to **emit fewer ops** — i.e., improve
the JS→WASM compiler's code generation. **That is the research target, and within it the target is the
register/constant churn first, dispatch second, loads last.**

---

## 2. System architecture (what we have)

### 2.1 The pipeline

```
JavaScript source
      │  (Porffor: a JS→WASM compiler we use, written in JS)
      ▼
   .wasm  (standard WebAssembly, wasm32)
      │  (our WASM→BEAM runtime: decoder + a BEAM-assembly transpiler + an interpreter)
      ▼
BEAM execution  (Erlang VM, BeamAsm JIT)
```

- **Porffor** compiles JS to `wasm32`. We do not control its internals directly; we consume its `.wasm`
  output. (Open JS→WASM compiler; we can in principle patch it but treat its codegen as the thing to
  understand and improve.)
- **Our WASM→BEAM runtime** has two execution lanes:
  - **Interpreter lane:** walks the WASM opcode stream.
  - **ASM lane:** transpiles WASM functions to **BEAM assembly** (the BEAM VM's own instruction set), which
    the BEAM compiler then JITs to native code via BeamAsm. This is "lowering WASM to machine code" on the
    BEAM side.
  - A **tiering** system: functions start interpreted and get promoted to the ASM lane when hot
    (background-compiled or eagerly).

### 2.2 The BEAM-specific angle (why this is interesting)

The BEAM VM is not a typical WASM host. Relevant facts:

- BEAM has **BeamAsm**, a JIT that compiles BEAM bytecode to native machine code. So our "ASM lane" really
  does end up as native code — per-op cost is a few nanoseconds.
- BEAM's native value representation is **tagged terms**: immediate small integers, floats, tuples, lists,
  binaries. There is no linear memory in the WASM sense; we *emulate* WASM linear memory ourselves.
- We back WASM linear memory with an **`:atomics` array** (an Erlang NIF for atomic 64-bit slots), one
  8-byte slot per 8 bytes of linear memory, kept in the process dictionary. Loads/stores are
  `:atomics.get`/`:atomics.put` calls (each a NIF call, ~9 ns) plus bounds checking and little-endian
  byte math.
- **BEAM has its own peephole optimizer (`beam_clean`).** It already folds redundant register moves. We
  verified this empirically: eliminating a `local.get` round-trip through a temporary register saved ~0.1 s
  because the optimizer was already doing it. **Do not propose CSE on register moves as a win — the host
  already does it.** This matters for Section 6.

### 2.3 Porffor's value model (NOT the dominant cost — but listed for completeness)

Porffor represents **every JavaScript value as a tagged pair** stored in linear memory:

- **value**: an `f64` (8 bytes) — even integers, even object pointers are stored as `f64`.
- **type**: an `i8` tag (1 byte) distinguishing number/string/object/...

Consequences (each *measured*, not assumed):

1. **Pointers are `f64`** → every address use needs `trunc_sat` (f64→i32). **True dynamic count: 424,385
   calls = 0.003 s for the whole run. This is a FALSE LEAD. Do not headline it.**
2. **Every value read = 2 memory loads** (an `f64.load` for the value + an `i32.load8_u` for the type tag)
   plus address arithmetic. **True cost: `f64.load` = 22.6 M × 50.7 ns = 1.15 s; the type-tag load is a
   subset of 2.6 M i32 loads = 0.08 s. Total loads ≈ 1.2 s. Real but small (~5% of the run).**
3. **Polymorphic property access is a linear type-dispatch if-chain** (~20 branches comparing the type tag
   against known type ids). This is a real op-count driver — see Section 3.3; it is the #2 cost, not #1.
4. **The #1 op-count driver is register/constant churn**, NOT listed in older framings: Porffor materializes
   a `local.get` + an `i32.const`/`f64.const` + an op for essentially every sub-expression, then stores the
   result back to a local. See Section 3.3 for the measured breakdown.

---

## 3. The benchmark and the numbers

**Benchmark:** acorn 8.17.0 (a real JS parser), parsing a corpus of ~33 small JS snippets (the kinds of
things you'd find in a parser test suite — declarations, expressions, classes, etc.). End-to-end:
compile JS→WASM, decode, execute on our runtime.

**Current timings (post-optimization):**
- tiered (interp → ASM in background): **23.9 s**
- eager-ASM (compile everything up front): **20.0 s**
- (session start: 117 s eager / 84 s tiered — a ~6× improvement came from the runtime fixes below)

### 3.1 Per-host-seam costs (microbenchmarked, true numbers)

We measured the actual nanosecond cost of each "host seam" (the BEAM functions our emitted asm calls for
stateful WASM ops):

| operation | ns/op | notes |
|---|---|---|
| bare `call_ext` to a trivial Elixir fn | ~7 | the cost of a remote function call from emitted BEAM asm |
| `:atomics.get` (1 slot) | 8.7 | linear-memory backing read |
| `Process.get` | 4.9 | process-dict read |
| `charge_fuel` (per loop iteration) | 13.6 | `Process.get` + `:atomics.sub_get` + compare |
| `guest_fload` (f64 load, **aligned**) | 50.7 | bounds check + 2× `:atomics.get` + float decode |
| `guest_fload` (f64 load, **unaligned**) | 238.9 | byte-by-byte loop (4.7× slower than aligned) |
| `guest_load` (i32 load) | 30.8 | |
| `guest_fcmp` (f64 compare) | 12.3 | classify both operands + compare |
| `wtrunc_sat` (f64→i32 trunc helper) | 7.4 | |

### 3.2 Dynamic call counts (true, measured with counters on a 25 s run)

| seam | dynamic calls | est. time |
|---|---|---|
| `charge_fuel` (per loop back-edge) | 25.0 M | 0.35 s |
| `guest_fcmp` (f64 compare) | 22.8 M | 0.28 s |
| `guest_fload` (f64 load) | 22.6 M | 1.15 s |
| `guest_load` (i32 load) | 2.6 M | 0.08 s |
| `guest_farith` (f64 add/sub/mul/div) | 645 k | 0.04 s |
| `call_local` (function-call trampoline) | 332 k | 0.03 s |
| `guest_store` (i32 store) | 295 k | 0.02 s |
| `trunc_sat` | 424 k | 0.003 s |

**Total time in all host seams combined: ≈ 2.9 s out of 25 s.** This is the measurement that killed the
"seams are the bottleneck" hypothesis.

### 3.3 The wall — and what it is actually made of (read this twice)

The other **~22 s is pure BEAM computation between seams**: `move` (register copies for `local.get`/
`local.set`), `gc_bif` (arithmetic like `+ - * band bor`), and `test`/branch (for `if`/`br_if`/compares).
These are the cheapest instructions BEAM has (~1–3 ns each). At ~3 ns, **22 s ≈ 7 billion BEAM ops**,
which corresponds to **~6.3 billion dynamic WASM ops** for 33 parses ≈ **191 M WASM ops per parse** ≈
**~19 M WASM ops per token**.

We took a static op histogram weighted by callcount (static count × function callcount) to see *what kind*
of cheap ops dominate. Absolute numbers from this method are unreliable (it over-counts cold ops), but the
**relative proportions** are sound because the hot ops share the same loop multipliers:

| op (static × callcount) | weighted count | category | share of cheap-op mass |
|---|---|---|---|
| `local.get` | 7.8 M | **register churn** | |
| `i32.const` | 6.8 M | **const churn** | |
| `f64.const` | 3.5 M | **const churn** | |
| `local.set` | 3.0 M | **register churn** | |
| `local.tee` | 1.2 M | **register churn** | |
| **subtotal register + const churn** | **~22.5 M** | | **~73%** |
| `if` | 829 k | **dispatch** | |
| `i32.eq` | 496 k | **dispatch** | |
| **subtotal dispatch** | **~1.4 M** | | **~4%** |
| `f64.load` / `trunc_sat` | 40 k / 738 k | loads | ~1.2 s wall (see 3.2) |

**The dominant cheap-op mass (~73%) is register/constant churn: `local.get` / `local.set` / `local.tee` /
`i32.const` / `f64.const`.** This is Porffor emitting a fresh local + a fresh constant + an op for nearly
every JS sub-expression, then storing the result back — a near-1:1 expansion of the JS AST into
materialized temporaries. **Dispatch (~4% by this measure, but billions of ops and a real second-place) is
the 20-branch property-access if-chain. Loads are ~1.2 s. `trunc_sat` is 0.003 s.**

> **Per-op cost is already near the floor. The lever is op COUNT, and within op count the lever is
> register/const churn first, dispatch second, loads last.**

---

## 4. What we have already tried (and the measured effect)

1. **Added f32/f64 load/store to the ASM lane.** Originally only integer memory ops were lowered to BEAM
   asm; f64 loads/stores (which dominate because JS numbers are f64) bailed to the interpreter. Adding
   them: acorn **84 s → 29.6 s** (tiered), **117 s → 26.3 s** (eager). *Lesson: unsupported-op fallbacks
   to the interpreter on hot paths are catastrophic.*
2. **Aligned fast path for f64/f32 loads/stores** (one `:atomics` op instead of a byte loop): +8–13%.
3. **Eliminated redundant register round-trips** in `local.get`/`local.set`/`local.tee` (each emitted two
   `move`s where one sufficed). BEAM's `beam_clean` optimizer already folded these at compile time, so
   runtime effect was ~0.1 s — but emitted code is ~half the size, which speeds up BEAM compilation of the
   asm modules (matters for the eager lane). *Lesson: BEAM already does move-CSE; do not re-propose it.*
4. **Inlined the f64-compare finite fast path** into BEAM asm (a BEAM `test` op instead of a `call_ext` to
   a helper): ~5× cheaper per compare (12.3 ns → ~3 ns), but only ~0.2 s saved because the helper was
   already cheap.
5. **Microbenchmarked every seam** (Section 3.1) — this *disproved* our earlier hypothesis that the seams
   were the bottleneck. They are only ~3 s. **Validating the instrument before trusting it was the key
   turn.** We expect the same rigor from you: any claim about cost must come with a measurement, not an
   assertion.

**Net:** acorn eager-ASM **117 s → 20.0 s (5.9×)**, tiered **84 s → 23.9 s (3.5×)**. Further runtime
inlining can save at most ~0.5–1 s more. The remaining 22 s is the op-count wall in Section 3.3.

---

## 5. Constraints (what any solution must respect)

- **Untrusted code must never run native.** Everything is emulated/sandboxed. The JS is untrusted; we
  compile it to WASM and run it in our runtime. We will not run it natively on the host.
- **The host is the BEAM VM.** We get BeamAsm (native JIT) for free, but we do not get a conventional
  WASM runtime (wasmtime/wasmer/WASIX). Linear memory, the process model, POSIX — all emulated by us.
- **We can modify the JS→WASM compiler (Porffor)** if a codegen transform is justified. We can also
  consider alternative JS→WASM compilers, or a different compilation target entirely (e.g., JS→BEAM-asm
  directly, skipping WASM), though that is a larger architectural decision.
- **Bit-identical semantics matter.** JS must behave like JS (IEEE-754 floats incl. NaN/±Inf, -0.0,
  32-bit integer wraparound, etc.). Any codegen transform must preserve these.
- **We control both ends** of the pipeline (the JS→WASM compiler *and* the WASM→BEAM runtime). Proposals
  may change the contract between them — e.g., a different value representation, host imports for object
  access, or mapping JS values to native BEAM terms across the boundary.

---

## 6. What we want covered (insist) and what we do not (do not)

This section is the contract for your deliverable. We ranked by measured leverage.

### 6.1 COVER — register/constant churn reduction (the ~73%, the actual #1)

This is the dominant cheap-op mass and nothing we have tried touches it. We want concrete, ranked
codegen transforms a single-pass JS→WASM compiler can apply to **emit fewer `local.get`/`local.set`/
`local.tee`/`i32.const`/`f64.const`** while staying bit-identical to JS. Cover at least:

- **Expression fusion / register targeting:** computing sub-expressions directly into the destination
  operand instead of materializing a temp + `local.set` + later `local.get`. What's the state of the art
  for stack-to-register translation in single-pass compilers (e.g., the Wasmtime cranelift-style
  operand-stack approach, or LuaJIT's register allocation)? What's the minimal version that fits a
  single-pass JS→WASM compiler?
- **Local allocation / reuse:** reusing the same WASM local for values with non-overlapping live ranges
  instead of allocating a fresh local per AST node. How much does linear-scan or a simple
  first-fit-by-liveness allocator cut `local.get`/`set` count on parser-shaped code?
- **Constant pooling / dedup:** Porffor re-emits the same `i32.const`/`f64.const` repeatedly. How much
  does a per-function constant pool (load constants into locals once at entry, reuse) cut `const` count?
  Tradeoffs vs. increased local pressure?
- **Dead-store / dead-local elimination** within a function.

For each: **expected op-count reduction (multiplier on the ~22.5 M churn mass), implementation difficulty,
and any single-pass-safe variant.** Cite real compilers that do it.

### 6.2 COVER — mapping JS values to native BEAM terms across the boundary (highest ceiling)

Section 2.2: BEAM already has native tagged terms (immediate ints, floats, tuples, maps). Today we pay the
linear-memory tax (`f64.load` + `i8.load` + `trunc_sat` + address arithmetic) to uphold a WASM linear
memory that the host doesn't natively have. We control both the JS→WASM compiler and the WASM→BEAM
runtime. **We want a serious evaluation of representing JS values as native BEAM terms across the
boundary** — the option that eliminates the linear-memory churn *and* much of the address-arith churn
together, not just halves the loads.

Cover:
- What JS→WASM compilation model makes this work? **WasmGC** (struct/array/ref types) and/or
  **externref** (reference-types proposal) emitted by the JS→WASM compiler, then lowered by us to BEAM
  maps/tuples/refs. What does each require of the compiler and of our runtime?
- Property access as a **native BEAM map/tuple lookup** instead of offset arithmetic + 20-branch
  dispatch. What's the op-count delta? Does it subsume the dispatch problem (Section 6.3)?
- Object allocation as native BEAM GC instead of bump-pointer-in-linear-memory. GC pressure tradeoffs on
  the BEAM (which is per-process, generational-ish).
- **The sandbox/blurring concern:** externref/WasmGC still carries WASM type safety, but object identity
  and memory isolation now cross into the host. How do existing host-managed-GC WASM designs (V8's
  WasmGC, SpiderMonkey's) reason about isolation? Is this acceptable for untrusted code, or does it
  require a hardened subset?
- A realistic estimate of the ceiling: if JS values are BEAM terms in registers and property access is a
  BEAM map lookup, what fraction of the ~22 s wall survives? What's the realistic target wall time?

**This is the option we most want a verdict on, including a clear "do it / don't do it and why."**

### 6.3 COVER — polymorphic dispatch (the ~4%, billions of ops, real #2)

The 20-branch linear if-chain per property access. Cover:

- **`br_table` on the type tag** for O(1) dispatch: semantically safe? Code-size cost? **Prerequisite you
  must address:** Porffor's type ids are *not* dense (a real dispatch site branches on `36, 37, 38, … 90,
  195`). `br_table` wants a dense 0..N index. Is a type-id → dense-index remap (computed once, or baked
  into the compiler) the right approach, or is a small perfect-hash jump table better?
- **AOT inline caching** (Chris Fallin / Weval style): a static corpus of fast-path stubs + a runtime-
  mutable function pointer (via `call_indirect` into a WASM table) that starts at a generic slow path and
  gets rewritten to a specialized stub after first execution. How exactly is the pointer-mutation done
  within WASM's no-self-modifying-code constraint? What's the realistic hit-rate on a parser workload
  (acorn property accesses are reportedly near-monomorphic — confirm or refute with data)?
- **Megamorphic fallback.** When does a site degrade, and what does the fallback cost?
- **The Hopc/Serrano-Poirier (2025) caveat** that inline caches don't always help on modern x86 because
  branch predictors mask if-chains. **Argue explicitly whether it applies to BEAM.** Our position: BEAM
  executes sequential BeamAsm with no cross-basic-block hardware speculation, so collapsing dispatch ops
  should translate near-linearly to wall time — but we want your independent assessment with evidence.

### 6.4 COVER — calibration, but MEASURED not asserted

We do not want another "this is 2–3 orders of magnitude too high, by reasoning." We want **numbers**:

- Run **acorn 8.17.0** (open source) on V8, SpiderMonkey, and QuickJS with bytecode/opcount dumps
  (`--trace-ignition`, `--print-bytecode`, SpiderMonkey `IONFLAGS`, QuickJS `-d`) on a comparable small
  JS corpus. Report **bytecode ops/token and machine ops/token for each.**
- Compare against **Porffor** output (open source) compiled for the same snippet: dump the generated WASM
  (`wasm-objdump -d`), confirm the `[f64, i8]` model and the churn pattern from Section 3.3, and report
  **WASM ops/token**, broken down by op category (register/const, dispatch, loads, arithmetic) the same
  way Section 3.3 does.
- Compare against **Javy** (Shopify, QuickJS→WASM) and any other JS→WASM compiler you can find
  (AssemblyScript, Engine265) for the same snippet: value representation, op density by category,
  dispatch strategy.
- **Give a verdict: is ~19 M WASM ops/token 2×, 10×, or 50× too high, and against which measured
  baseline?** And: what is the realistic floor for a WASM-compiled JS parser, given JS's runtime typing?

### 6.5 COVER — the architectural verdict, with the QuickJS caveat

Compare the design space for running untrusted JS on BEAM and give a verdict:

- (a) JS → WASM → BEAM-asm (current)
- (b) JS → BEAM-asm directly (skip WASM; we have "machine code control" via BeamAsm)
- (c) JS → a compact custom bytecode → a BEAM-native interpreter
- (d) Embed an existing JS engine (QuickJS) as a wasm module and run *that* on our WASM→BEAM runtime

**On (d) specifically:** we have *empirically* found QuickJS too slow for our purposes and have rejected it
as a bar. If you want to argue (d) is viable, you must address *why* our QuickJS experience was bad
(likely QuickJS-native, or QuickJS-via-WASM-on-a-conventional-runtime) and *why* QuickJS-via-WASM-on-our-
BEAM-runtime would be different — with measured or cited numbers, not "Javy is 1–3 s" hand-waves. We are
skeptical but will listen to evidence.

Tradeoffs for each option: op count, semantic fidelity, sandboxing, engineering cost. We lean (a) or (b);
we want your independent call.

### 6.6 DO NOT — de-emphasized (do not make these your headline)

We measured these. They are small. You may mention them as secondary, but do not build your proposal's
main savings on them:

- **`trunc_sat` elimination as a headline win.** True dynamic count = 424 k = **0.003 s**. It is a false
  lead. (If a representation change like NaN-boxing or BEAM-terms eliminates it as a side effect, fine —
  but do not count 0.003 s toward your claimed speedup.)
- **NaN-boxing (`i64` with tag in NaN bits) as a 3–5× headline.** It halves the loads (~1.2 s → ~0.6 s)
  and removes `trunc_sat` (~0.003 s). That is **~0.5–0.6 s on a 20 s run (~3%), not 3–5×**, because it does
  nothing to the ~73% register/const churn and only partially touches dispatch. If you propose NaN-boxing,
  **score it against the Section 3.3 breakdown** and give the real multiplier, not the load-centric one.
  It may still be worth doing — but as a ~3% win or as a stepping stone to Section 6.2, not as the answer.
- **CSE on register moves / redundant `local.get`.** BEAM's `beam_clean` already folds these (Section 4,
  item 3). Do not propose it as a win.
- **Calibration by assertion.** "V8 does a few hundred instructions per token" is not a measurement.
  Run the dumps (Section 6.4) or cite a paper that did.

---

## 7. What we'd most like from you (deliverable)

A single document, ranked by impact-on-our-decisions:

1. **Measured calibration verdict (Section 6.4):** ops/token for V8/SpiderMonkey/QuickJS/Porffor/Javy on
   acorn, by op category, with a clear "normal vs pathological" call. This is the gating question — if
   19 M/token is 50× too high, the answer is "fix Porffor's codegen"; if it's 2× too high, the answer is
   "this is roughly the floor, change architecture."
2. **A ranked list of register/const-churn codegen transforms (Section 6.1)** with expected op-count
   multiplier, implementation difficulty, and single-pass-safe variants, citing real compilers.
3. **A verdict on BEAM-term mapping (Section 6.2):** do it / don't, what the compiler and runtime must
   emit, the realistic wall-time ceiling, and the sandbox implications for untrusted code.
4. **A dispatch plan (Section 6.3):** br_table (with the dense-remap prerequisite solved) vs AOT inline
   caching, with hit-rate evidence on parser workloads and an explicit take on the Hopc/BEAM question.
5. **The architectural verdict (Section 6.5).**

For every performance claim, give a number and where it came from. We have been burned once by trusting a
plausible-sounding cost model over a measurement; we will not again.

---

## 8. Data you can collect without our code

- Run **acorn 8.17.0** (open source) on V8/SpiderMonkey/QuickJS with opcount dumps on a small JS corpus
  and report **ops/token by category** for each. This directly calibrates Section 6.4.
- Inspect **Porffor** (open-source JS→WASM compiler) output: compile a small JS snippet and dump the
  generated WASM (`wasm-objdump -d`). Confirm the `[f64, i8]` value model, the register/const churn
  pattern (Section 3.3), and the polymorphic if-chain. Report op counts per category per JS source line.
- Compare with **Javy** (Shopify, QuickJS→WASM) and other JS→WASM compilers for the same snippet: value
  representation, op density by category, dispatch strategy.
- Literature: V8/SpiderMonkey inline-cache hit-rate data on parser workloads; tracing-JIT effectiveness
  on parsers; AOT JS compilation (AssemblyScript, StaticWebAssembly, WasmGC) representation choices;
  single-pass register allocation (linear-scan, Poletto/Sarkar); the Wevel/Fallin AOT-IC work; the
  Serrano/Poirier 2025 Hopc DBM-IC study.

---

## 9. One-paragraph framing for the researcher

> We run untrusted JS on the Erlang BEAM VM via JS→WASM→BEAM-asm. After runtime optimizations took us ~6×
> (117 s → 20 s on an acorn-parser benchmark), we microbenchmarked every host seam and found they total
> only ~3 s of the 20 s. The remaining ~22 s is ~6.3 billion *cheap, already-native* BEAM ops — the
> JS→WASM compiler emits ~19 M WASM ops per parsed token. We weighted a static op histogram by callcount
> and found the dominant cheap-op mass (~73%) is **register/constant churn** (`local.get`/`local.set`/
> `local.tee`/`i32.const`/`f64.const` — Porffor materializes a temp + a const per sub-expression), with
> **polymorphic-dispatch if-chains** a real second (~4% by static share but billions of ops) and **loads
> only ~1.2 s**. `trunc_sat` is 0.003 s — a false lead. Per-op cost is at the floor; the lever is op
> count, and within it: register/const churn first, dispatch second, loads last. We need: (1) a *measured*
> calibration of our op density vs V8/SpiderMonkey/QuickJS/Porffor/Javy on acorn, by op category; (2)
> concrete single-pass codegen transforms that cut the register/const churn; (3) a verdict on mapping JS
> values to native BEAM tagged terms across the WASM/BEAM boundary (our highest-ceiling option); (4) a
> dispatch plan (br_table with a dense type-id remap, and/or AOT inline caches); (5) an architectural
> verdict on JS→WASM→BEAM-asm vs alternatives. Every performance claim must come with a measurement.

---

## 10. Session findings (2026-06-30) — measurement artifacts corrected, compilation gates fixed

### 10.1 The "2.2× asm speedup" was a measurement artifact (probe effect, not observer effect)
Every perf probe passed `tier: {:sync, 1}` — a **no-op option**. The real tier knobs are
`:tier_threshold` (default **20**) and `:tier_async` (default **true**). So every "eager-asm" run was
actually **async-lazy @ threshold 20**, where the background compile worker **dropped** excess hot
functions (see 10.2). The 18 s "eager-asm" was a partial-asm/partial-interp mix, NOT a true asm measurement.

True numbers (acorn, same 7-probe corpus), single cold run on the test machine:

| mode | wall | what runs |
|---|---|---|
| pure-interp | 37.9 s | all interpreted |
| async-lazy @20 (the old "eager-asm") | ~18 s | some asm + dropped funcs interpreted |
| true sync-eager (threshold 1, sync) | 117 s | all asm, but ~80 s inline compile overhead |
| **warm steady-state (queue fix, threshold 100)** | **15.6 s** | all hot funcs cached → asm, no compile |

**Warm steady-state is the production-relevant number: 15.6 s = 2.43× vs pure-interp.** A module loads
once and runs many times; the persistent `JitCache` amortizes the one-time compile across runs.

### 10.2 The async tier silently DROPPED hot functions — fixed
`compile_one_async` gated inflight compiles with an `:atomics` counter (`@max_inflight_compiles = 2`) and
**silently dropped** every hot function that crossed the threshold while the gate was full (`:atomics.sub`
+ return, no spawn). A dropped function stayed `:pending` in the per-run `:tl_jit` dict; on every
subsequent call the `:pending` branch polled `cached_one/2` → `:miss` forever → it ran **interpreted for
ALL of its calls**. On a compile storm (acorn's parse dispatchers), most hot functions were dropped.

**Fix:** `TinyLasers.Wasm.Transpile.AsyncCompiler` — a bounded **queue** GenServer. `enqueue/2` dedups
by `{mod.id, gfidx}`; the server spawns up to `max_inflight` (default 2, runtime-tunable via `set_max/1`)
workers and drains the next queued item on each `:done`. **No hot function is dropped** — it waits its
turn. CPU is still bounded so compilation never starves the interpreter. Result: `gf360` (12 082 calls)
went from 12 082 interp invocations (never compiled) → 0 interp in the warm run (fully asm).

### 10.3 `call_indirect` multi-value lowered (t1)
The asm lane's `call_indirect` only supported ≤1 result; Porffor's `[f64, i32]` value pair forces nr=2,
so 474/486 bailed functions (incl. the two hottest) fell to interp on `{:call_indirect, 53}`. Extended
`tables.ex` to lower multi-value `call_indirect` (nr ≤ 16) via the shared `unpack_result_list` (exposed
from `TranspileAsm`). Static bail 486 → 13 (the 13 remaining are cold `try_legacy`/`simd`/`return`).
Oracle-green (asm vs interp bit-identical across the asm/differential suite).

### 10.4 Compilation-gate false positives were blocking correct programs — fixed (red-team)
Two pre-existing test failures were **compilation invariant gates**, not execution bugs (exactly the
"chasing ghosts in execution" risk):

- **marked 4.3.0** hit `INV-LOOP-FRESH` and wouldn't compile. The `cc_invariants.cjs` heuristic
  **over-reports**: the output AST cannot distinguish a per-iteration block-scoped *declaration* (real
  bug) from a *mutation of an outer `let`* (correct JS — one shared cell IS the semantics). Verified
  with `skip_invariants: true`: marked **completes and is byte-identical to node (16/16)** — a false
  positive blocking a correct program. The SOUND, decidable check lives in `closure_convert.cjs`
  (`CC_INVARIANTS`, uses binding provenance `b.kind + b.declStmt`) and correctly passes marked. **Fix:**
  demoted the heuristic's `INV-LOOP-FRESH` to a **non-blocking warning**; the construction-time
  `CC_INVARIANTS` check remains the hard gate for the real bug class. marked now passes.

- **rollup bundle gate** is a reporting test tracking the compile frontier; its baseline
  (`INV-CAPTURE-BOUND`) was stale. Demoting `INV-LOOP-FRESH` moved the frontier forward to
  `INV-NO-NATIVE-CAPTURE` — a **real** gap (Porffor native/unboxed functions can't capture from an
  enclosing scope; `closure_convert` must box them). Updated the test to track the new frontier.

**Net: 253 → 0 failures** (focused battery 110/110 green; full suite re-run in progress). The asm lane
is oracle-identical to the interpreter across the differential suite — execution-perf numbers are now
trustworthy (no correctness ghosts).

### 10.5 The remaining lever is EXECUTION, not compilation
Compilation overhead is a one-time cold cost, amortized by the persistent `JitCache` across runs. The
warm floor is **15.6 s of pure asm execution** = ~6.3 B cheap BEAM ops (the flat-WASM op-count problem,
§6.4). The execution-pad levers, in priority order:
1. **`externref` for JS values in Porffor** (t2) — one BEAM term per JS value instead of the `[f64, i32]`
   pair. Cuts the ~73% register/const churn (every sub-expression materializes a temp + a const) AND
   subsumes t1 (`call_indirect` nr 2→1). Highest-ceiling structural change.
2. **`br_table` + dense type-id remap / AOT inline cache** for the polymorphic dispatch if-chains
   (H6: 96.9% monomorphic → a shape-indexed `br_table` collapses the if-chain). Second lever.
3. Per-op lowering micro-opts (deferred until the hot path is externref-shaped).

`INV-NO-NATIVE-CAPTURE` (the rollup frontier) is the next **compilation** gap to close so rollup can
reach the execution lane at all — but it does not block the acorn execution-perf work.

### 10.6 Execution-pad ceiling measured — externref is 4.22× on the dispatch-heavy path
A synthetic spike (2 M property accesses, interp lane, both correct: acc = 3.14 × N):

| path | wall | per-access |
|---|---|---|
| `[f64,i8]` + 20-branch type-tag if-chain (Porffor's real dispatch) | 3626.5 ms | 1813 ns |
| `externref` + host `element/2` (one BEAM term per value) | 859.4 ms | 430 ns |

**Ratio: 4.22×. externref cuts the dispatch-path execution time by 76.3%.** This is the execution-pad
ceiling for the dispatch-heavy hot path (acorn's tokenizer state-machine objects): collapsing the
type-tag if-chain into a single host element lookup. The externref **runtime plumbing already exists**
(the spike ran end-to-end); the t2 work is getting Porffor to **emit** externref for JS values (codegen)
+ lowering the externref ops in the asm lane to `gc_bif`. This is the highest-ceiling execution-pad
lever; the asm-lane delta will be smaller than the 4.22× interp figure (asm already lowers some
dispatch) but still the dominant structural win.

### 10.7 br_table lever — blocked by a Porffor brTable codegen bug (characterized, not yet fixed)
Porffor already has `--typeswitch-brtable` (`brTable()` at `compiler/codegen.js:3178`) that emits the
~20-branch type-tag dispatch as a `br_table` (nested-block labeled-switch pattern) instead of an
if-chain — the cheapest execution-pad win IF it worked. It does not, yet:

- With the flag, acorn compiles to 9.3 MB wasm (smaller — br_table is more compact than the if-chain)
  but `wasm-tools validate` rejects it: **"func 4: type mismatch: expected f64 but nothing on stack"**.
  The wasm is malformed → the TinyLasers decoder then mis-aligns (surfacing as a spurious
  `catch_clause` failure on a try_table, a red herring).
- Root cause: `brTable()` emits each case body between block `end`s and trusts it produces the
  `returns` value. The if-chain path (`typeSwitch` line 3404-3406) adds a `number(0, returns)` fallback
  when a default is missing; `brTable()` does NOT, so a typeSwitch whose default doesn't push the
  result leaves the stack empty → type mismatch.
- Two blockers remain for the br_table lever: (1) this Porffor `brTable()` codegen bug, (2) the asm
  lane's `br_table` lowering is **void-only** (`tables.ex:121`) — the brTable pattern's targets exit
  blocks of mixed result-arity, so the asm lane would bail even on valid br_table wasm. Both are
  fixable; the br_table win is **subsumed by externref** (which eliminates the type-tag dispatch
  entirely), so br_table is only worth fixing as a near-term [f64,i8]-path win while externref is built.

### 10.8 Porffor codegen map for the externref vertical slice (t2)
Porffor's value model: every JS value = `[f64 payload, i32 type tag]` (~42 tags in
`compiler/types.js`); `allocVar` (`codegen.js:3442`) gives every binding TWO locals (`name` +
`name#type`); `setLastType`/`getLastType` track the expression-result tag; user-fn signatures are
`returns: [valtypeBinary, Valtype.i32]` (`codegen.js:7411`) and params `(valtype,i32)×N` (`:8058`).
Object literals: `generateObject` (`codegen.js:6285`) mallocs a linear-memory blob, per-property
`__Porffor_object_expr_init`. Property access: `generateMember` → `typeSwitch` (`codegen.js:6545`,
the ~20-branch dispatch) → default `__Porffor_object_get` (`:6778`). `externref` (0x6f) is defined in
`wasmSpec.js` Reftype but UNUSED for values (only `funcref` for indirect calls). The minimal slice:
`generateObject` → host externref constructor; `generateMember` default → host `element/2`; an ABI
knob `valtypeMode: 'externref'` touching `allocVar`, `generateFunc.returns/params`, `assemble.getType`.
Scope to plain object literals + dot-access for the slice; leave closure boxes / arrays / typed-array
branches / `funcref` wrapper for later.

