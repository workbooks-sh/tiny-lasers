# Research Hypotheses: JS → WASM → BEAM op-count wall

**Companion to:** `js-wasm-beam-perf-research-brief.md`.
**Method:** every hypothesis is stated so it can be **falsified by a measurement we can run on our own
code**, in the workspace's protocol form: *why it fits the evidence | falsification criteria | lowest-cost
test*. Ranked by explanatory power × test cost. The first three are cheap and decisive — they gate
everything below them.

**Current evidence (recap):**
- acorn eager-ASM 20.0 s, tiered 23.9 s. Host seams total ≈ 2.9 s. `trunc_sat` = 424 k = 0.003 s.
- Static×callcount histogram: `local.get` 7.8 M, `i32.const` 6.8 M, `f64.const` 3.5 M, `local.set` 3.0 M,
  `local.tee` 1.2 M (subtotal **~22.5 M, ~73%**); dispatch `if` 829 k + `i32.eq` 496 k (~1.4 M, ~4%);
  `f64.load` 22.6 M = 1.15 s.
- The static×callcount method is **unreliable for absolutes** (over-counts cold ops). All hypotheses below
  that depend on the split must be validated dynamically before being trusted.

---

## H1 — The true dynamic op-split matches the static×callcount proportions (churn ≫ dispatch ≫ loads)

**Why it fits:** the static×callcount method over-counts cold ops, but the hot ops (churn, dispatch, loads)
share the same loop multipliers, so *relative* proportions should hold. If they do, the entire
corrected framing (churn-first) is sound.

**Falsification:** run an interp op-type counter on a single parse; if `local.get`+`set`+`tee`+`const` are
**not** the dominant dynamic bucket (say <50% of dynamic ops), or if dispatch + loads together exceed
churn, the framing is wrong and we re-prioritize.

**Lowest-cost test:** instrument the interpreter `step` to increment a per-op-type counter (an
`:atomics` or `:counters` array) on one parse of the acorn corpus, then print the histogram. Interp is
slow (~2.5 s/parse) but one parse is enough. ~15 min. **This is the gating measurement — run it first.**

---

## H2 — A large fraction of the register churn is *fusion-eligible* single-use temporaries

**Why it fits:** Porffor materializes a temp (`local.set`) per sub-expression then immediately `local.get`s
it once for the consuming op. That set→get-once pattern is exactly what destination-driven fusion
eliminates by keeping the value on the operand stack. If this pattern dominates the churn, fusion's
~0.3–0.4× claim is real.

**Falsification:** scan the emitted WAT for `local.set N` immediately followed (within the same block,
ignoring `end`/control) by a single `local.get N` where N is not referenced again. If that pattern covers
**<30%** of `local.set`/`local.get` pairs, fusion's ceiling is much smaller than claimed and we look
elsewhere.

**Lowest-cost test:** static WAT pattern scan over the compiled acorn module. Use `wasm-objdump -d` or
Porffor's own WAT emitter; a script counts, per local index, set-then-single-use vs set-then-multi-use.
~20 min. Distinguishes "fusion is the big lever" from "fusion is marginal."

---

## H3 — Constant pooling does NOT reduce op count on our substrate (my correction to the researcher)

**Why it fits:** pooling replaces N×`.const` with (2 + N×`local.get`). Op count *rises* by 2/const. For
small `i32.const` (type-tags 36/37/90, small offsets) BEAM lowers to immediate integers — cheaper than a
y-register `move`, so pooling is slower per-op too. Only hot `f64.const` reuse could break even.

**Falsification:** bucket the 10.3 M consts by (value, per-function use count). If the majority are
**small i32s used few times**, pooling loses on both axes → reject 2.3. If a meaningful fraction are
large f64s reused heavily in hot loops, pooling has a marginal case → keep it, scoped to f64.

**Lowest-cost test:** extend the H2 WAT scan to histogram `i32.const`/`f64.const` values and per-function
repeat counts. ~15 min. Resolves the disagreement with the researcher with data instead of argument.

---

## H4 — Property access + address arithmetic is the bulk of what *isn't* pure register churn

**Why it fits:** the externref+tuples ceiling depends on how much of the wall is (a) the 20-branch
dispatch if-chains and (b) the offset arithmetic (`i32.add` of base+offset, `trunc_sat` of f64 pointers,
`i32.const` field offsets). If that combined mass is large, externref+tuples has a big ceiling; if it's
small, fusion alone (H2) suffices and the big externref swing isn't worth it.

**Falsification:** measure the dynamic fraction of ops that occur *inside* a property-access sequence
(the if-chain + its address arithmetic). If **<20%**, externref's ceiling is modest — do fusion, skip
externref. If **>40%**, externref+tuples is justified.

**Lowest-cost test:** harder than H1 — needs structural context, not just op type. Approximation: extend
H1's interp counter to tag ops as "address-arith" (`i32.add`/`i32.const`-small-offset/`trunc_sat` feeding
a load) vs "dispatch" (inside an if-chain on a type tag) vs "other." A precise version records the
current AST/structural context. ~30–45 min. Approximate version ~20 min. **Run only if H1 confirms the
framing.**

---

## H5 — BEAM `element/2` on a tuple is ~10× cheaper than a `map` lookup for a 10-field AST node

**Why it fits:** `element/2` is a `gc_bif` (~1–3 ns, O(1)); a map lookup is a `call_ext`-ish traversal
(~30–80 ns). This is the single number that decides whether the externref ceiling is "3–5 s" (tuples) or
"not much better than today" (maps). The researcher defaulted to maps; I claim that's a 10× mistake.

**Falsification:** microbenchmark `element(N, tuple)` vs `Map.get(map, key)` on a 10-element structure,
10 M iterations each, on this BEAM. If the ratio is **<3×**, maps are acceptable and the distinction
doesn't matter much. If **~10×**, tuples are mandatory for fixed-shape objects.

**Lowest-cost test:** a ~15-line `:timer.tc` microbench in `mix run`. ~5 min. Self-contained, no codebase
spelunking. **Run immediately — it's the cheapest decisive test in the set.**

---

## H6 — Acorn property-access sites are monomorphic (one shape per site), so tuples+shape-index obviate most dispatch

**Why it fits:** parser code processes AST nodes by known type; a given `node.type` site almost always
sees the same shape. If true, a shape-indexed `element/2` needs no 20-branch chain, and br_table/AOT-IC
(Section 4 of the brief) becomes a fallback for the rare polymorphic site, not the primary mechanism.

**Falsification:** record `(call-site-id, type-id)` pairs for property accesses during one parse;
compute the per-site shape-count distribution. If **>80%** of dynamic accesses are at monomorphic sites,
tuples+shape-index subsumes dispatch and we don't build br_table first. If sites are broadly
polymorphic, dispatch work (br_table/IC) is independently necessary.

**Lowest-cost test:** instrument the interp's property-access path to log `(pc, type-tag)` into an ETS
table for one parse, then aggregate. ~30 min. **Run after H4** (only worth it if H4 says the dispatch
mass is large).

---

## H7 — `call_indirect` and `br_table` are the gating prerequisites for the dispatch plan

**Why it fits (already evidenced):** the bail probe showed 75 functions bail on `{:call_indirect, 53}` —
it's the #1 unsupported asm-lane op. `br_table` asm-lane support is unverified. The researcher's AOT-IC
(4.2) and br_table (4.1) both assume clean lowering.

**Falsification:** implement `call_indirect` lowering in the asm lane, re-run the bail probe. If those 75
functions promote and acorn speeds up, the prereq is real and worth doing. If they bail for *other*
reasons too (so adding `call_indirect` alone doesn't promote them), the prereq is necessary-but-not-
sufficient.

**Lowest-cost test:** not cheap — it's implementation, not measurement. Defer until H4/H6 say dispatch
work is actually needed. ~hours. **Do not start before H6 resolves.**

---

## Execution sequence (cheapest decisive tests first)

| step | hypothesis | cost | what it decides |
|---|---|---|---|
| 1 | **H5** tuple-vs-map microbench | ~5 min | whether the externref ceiling is 3–5 s or meh (a 10× decision) |
| 2 | **H1** true dynamic op-split | ~15 min | gates the entire framing (churn-first vs not) |
| 3 | **H2** fusion-eligible temp fraction | ~20 min | whether fusion is the big lever or marginal |
| 4 | **H3** const value/repeat histogram | ~15 min | confirms/rejects the constant-pooling correction |
| 5 | **H4** property-access + addr-arith fraction | ~30 min | whether externref is worth the big swing |
| 6 | **H6** per-site polymorphism | ~30 min | whether dispatch work is subsumed by tuples |
| 7 | **H7** asm-lane call_indirect/br_table | hours | only if H4/H6 say dispatch work is needed |

**Decision tree:**
- H1 falsifies the framing → re-prioritize from scratch.
- H1 holds, H2 high → **fusion is the #1 build**, do it next, measure.
- H5 ~10× + H4 high → **externref+tuples is the #2 build**, after fusion.
- H5 ~10× + H4 low → fusion alone; skip externref.
- H6 monomorphic → dispatch plan shrinks to "fallback only"; skip H7 unless H4/H6 say otherwise.
- H6 polymorphic → H7 becomes a real prerequisite; build it.

---

## Measured results (H5 / H1 / H2 / H3) — and the re-ranking they force

All four cheap decisive probes were run on our own code. The results **overturn both the original brief's
framing and the external researcher's impact estimates.** The re-ranking is stark.

### H5 — `element/2` vs `Map.get` → FALSIFIED (1.4×, not 10×)

Self-contained microbench (`/tmp/h5_microbench.exs`), volatile-built 10-field node, tail-recursive fetch
loop, loop-overhead-subtracted:
- `element(3, tuple)` ≈ **7.9 ns/op**
- `Map.get(map, int key)` ≈ **11.6 ns/op**
- `Map.get(map, atom key)` ≈ **11.1 ns/op**
- **Ratio ≈ 1.4–1.5×, not 10×.**

BEAM small maps (≤~32 fields) are flat sorted arrays, so a 10-field `Map.get` is a tight ~3-4-comparison
binary search — only modestly slower than `element/2`'s single index + bounds check. **My own hypothesis
(and my critique of the researcher for "defaulting to maps") was wrong — measured.** The tuple-vs-map
choice is a ~1.4× refinement, not a 10× decision. The dominant cost in an externref property access is the
host-boundary `call_ext` (~7+ ns) wrapping either BIF, which swamps the 1.4×.

**Implication:** the externref ceiling is NOT determined by tuple-vs-map (H5 falsified that framing). It is
determined by what externref *eliminates* — which H1 then measured directly.

### H1 — true dynamic op-split → PARTIALLY CONFIRMED, with major corrections

Instrumented the recursive interpreter `run/4` with a per-op-type `:counters` histogram (then reverted;
`wasm.ex` diff clean, build green). 7-probe acorn subset, pure interp, 358,323,802 dynamic ops. Sub-bucketed
`{:op, opcode}` by inner opcode to decompose the arith/cmp mass.

True dynamic split (against 358M total):

| category | % of total | static×callcount had said |
|---|---|---|
| register/const churn (get/set/tee/const) | **44.7%** | ~73% |
| **dispatch (branches + dispatch-compares)** | **30.7%** | ~4% |
| address-arith (i32.add/sub) | 11.8% | (in "op") |
| loads (all i32/i64/f32/f64) | 6.0% | ~1.2s ✓ |
| global_get | 5.75% | (not flagged) |
| **real arithmetic (f64 add/sub/mul/div + real int)** | **0.37%** | (in "op") |
| trunc_sat | 0.1% | false lead ✓ |
| calls (call + call_indirect) | 0.13% | tiny |

Decomposition of the `op` bucket (24.6% of total, 88.2M ops):
- **i32.add = 47.7% of op (11.8% of total)** — address-arith for the `[f64,i8]` linear-memory model.
- **dispatch-compares (i32.eq/ne/eqz + i32 lt..ge + f64 cmps) = 50.3% of op (12.4% of total)** — the
  comparisons feeding the polymorphic if-chains.
- **REAL arithmetic = 1.5% of op (0.37% of total)** — f64.add is 0.07%. acorn does almost no math.

**The four corrections that change everything:**
1. **Real arithmetic is 0.37%.** The entire op-count wall is compiler-emitted *overhead* — materialization
   (churn), polymorphic dispatch, address-arith, loads — not JS computation. Definitive proof the op count
   is pathological, not that JS-on-WASM is inherently expensive. Even the `op` bucket is 98% overhead.
2. **Dispatch is 30.7%, not 4%** — 7.7× bigger than the static framing claimed. The researcher's dispatch
   focus was *right and under-credited*; the brief's "~4%, small" was wrong.
3. **`call_indirect` is 1009 dynamic calls (0.0003%).** The researcher's AOT-IC *via call_indirect* (their
   4.2) targets a near-zero cost. The real dispatch wall is the 20-branch type-tag if-chains, which
   **br_table** (their 4.1) addresses directly. So br_table is the right dispatch mechanism for *this*
   pattern; call_indirect-based IC is the wrong tool. **H7 deprioritized for perf** (it's a completeness
   fix, not a wall lever).
4. **externref's ceiling is ~54%+ of ops** (dispatch 30.7% + address-arith 11.8% + loads 6% + global_get
   5.75% + a churn chunk) — far bigger than H5's 1.4× suggested. **H5 falsified the tuple-vs-map
   sub-question but STRENGTHENS the externref recommendation.** externref is the dominant lever.

### H2 — fusion-eligible temp fraction → FALSIFIED (researcher's 60-70% claim)

Static scan of `mod.code` (full corpus, 2671 funcs, 3.1M instrs; `/tmp/h2h3_static.exs`):
- `local_get` 584k, `local_set` 401k, `local_tee` 21k (static).
- **Only 17.9% of `local_get`s are single-use temps** (set-once-get-once); 21.1% read-once.
- **Adjacent set→get (same local, same block) = 0.** Porffor never emits the canonical fusion pattern. The
  single-use temps have *intervening ops* between set and get, so the value can't trivially stay on the
  operand stack — fusion is structurally harder than the textbook case.
- Refcount distribution: rc=2 (single-use temps) = 113k locals; the multi-use locals (rc≥4) are fewer but
  carry the dynamic weight (hot loop pointers/indices re-read many times).

**Researcher's "destination-driven fusion eliminates 60-70% of register churn, ~0.3-0.4×" is falsified.**
Realistic fusion ceiling ≈ ~18% of gets → ~6-8% of total ops, likely less dynamically (single-use temps
tend to be cold; the hot multi-use local_gets are inherent register-machine traffic that neither fusion nor
externref removes). Fusion is a modest, low-cost, representation-agnostic win — worth doing, but not the
big lever.

### H3 — const value/repeat histogram → CONFIRMED (constant pooling is a false win)

Same static scan:
- `i32_const` 805k, `fconst` 467k. Distinct i32 values: 1,617; distinct f64: 10,517.
- **93.5% of `i32_const`s are small (|v|<1000)** → BEAM-immediate-cheap. Pooling replaces cheap immediates
  with y-reg moves (equal-or-worse per-op) AND *increases* op count by 2/const.
- Dominant const: `0` (343k = 42.6% of i32; `0.0` = 76.4% of f64) — the most foldable constant; pooling it
  is a loss.
- Type-tag consts (195/38/67, ~266k uses) are dispatch compares → eliminated by **br_table/externref**, not
  by pooling.
- Pooling math: N uses → (1 const + 1 set + N gets) = N+2 ops vs N consts → op count *rises*.

**Researcher's 2.3 (constant pooling, ~0.5× on const churn) is falsified.** And note the static-vs-dynamic
divergence: `i32_const` is 25.7% *static* but only 6.85% *dynamic* — consts live in cold big functions.
Even if pooling helped (it doesn't), the dynamic weight is only 6.85%. **Drop constant pooling.** (My
earlier correction is vindicated with data.)

### Revised ranking of the actual levers

| lever | dynamic share attacked | cost/risk | verdict |
|---|---|---|---|
| **externref / WasmGC → native BEAM terms** | ~54%+ (dispatch 30.7 + addr-arith 11.8 + loads 6 + global_get 5.75 + churn-chunk) | high cost/risk | **#1 by ceiling.** The dominant structural lever. H5's 1.4× tuple-vs-map is a minor sub-decision within it. |
| **br_table** (dense type-id remap → O(1) dispatch) | dispatch 30.7% | low–med | **#2 / fallback.** If externref is done, dispatch is largely subsumed (shape-index); if not, br_table is the standalone dispatch lever. Validated as a big lever (researcher was right, under-credited). |
| **fusion (destination-driven)** | ~6-8% of churn | low | **modest.** Do it (low-cost, representation-agnostic), but expect ≤~8%, not 60-70%. |
| **global_get hoisting** (read once per fn, not per op) | 5.75% | low | **cheap, orthogonal.** The researcher's "hoist :tl_mem reads" idea — real and easy. |
| constant pooling | — | — | **DROP.** Falsified (H3): 93.5% immediate-cheap; op count rises. |
| CSE on trunc_sat | 0.1% | — | **DROP.** Negligible (0.1%). |
| AOT-IC via call_indirect (H7) | 0.0003% | hours | **DEPRIORITIZE for perf.** call_indirect is 1009 dynamic calls; wrong mechanism for the if-chain dispatch wall. Keep as a completeness fix only. |

### What this means for the two open hypotheses

- **H4 (property-access + address-arith fraction): SUPERSEDED by H1.** H1's `op` decomposition already
  measured address-arith (11.8%) and dispatch (30.7%) directly. No need to run H4 separately — the
  externref ceiling (~54%+) is established.
- **H6 (per-site polymorphism): DEFERRED, not dropped.** Still useful *at implementation time* to decide
  whether externref/br_table can use a simple monomorphic shape-index (one check) or needs a polymorphic
  fallback. Run it when designing the dispatch/externref implementation, not now — H1 already justifies
  pursuing dispatch/externref as the #1–#2 levers.
- **H7 (call_indirect/br_table asm lowering): split.** br_table asm support is a real prerequisite for the
  #2 lever (cheap to add, verify it lowers). call_indirect asm support is a completeness fix only
  (negligible perf) — schedule but don't prioritize.

### The single most important takeaway

The wall is **~99.6% compiler-emitted overhead** (materialization + dispatch + address-arith + loads +
globals) and **0.37% real JS arithmetic.** The biggest actionable lever is not "optimize the codegen of
individual ops" (fusion, the researcher's #1) — it is **collapse the representation overhead itself**
(externref → native BEAM terms), which removes dispatch + address-arith + loads + globals in one stroke.
Fusion is a real but modest secondary. The researcher had the levers roughly right in *kind* but
drastically wrong in *magnitude* (fusion 4× overestimated, constant pooling a false win, dispatch 7.7×
underestimated, AOT-IC-via-call_indirect the wrong mechanism).

---

## Open questions we cannot resolve without the external researcher's data

- The **calibration floor** (is 19 M ops/token 10× or 10,000× too high vs V8/QuickJS/Javy) — **RESOLVED
  LOCALLY** (see Round 2 below). Node v25 available; no `qjs`/`deno`. Measured: op-count ratio vs V8 is
  ~10³× (3 orders), not 10⁷ (the researcher's typo) nor 10⁴ (my earlier table correction). The researcher's
  "2–3 orders" guess was closest; my "5 orders" was high.

---

## Round 2 — H6 + calibration floor + br_table asm-lane (the re-ranking they force)

Three follow-ups from the decision tree were executed. **H6 overturns H1's "dispatch 30.7%" claim and
re-ranks the levers a second time.** The calibration floor is now measured locally.

### Calibration floor — measured locally (Node v25, acorn-8.17.0, same 7-probe corpus)

`/tmp/cal_node.js`, `/tmp/cal_trace.js`, `/tmp/cal_7asm.exs`:

| tier | ns/token | source |
|---|---|---|
| V8 TurboFan (JITed) | **212** | `node` default, 1000 runs, loop-subtracted |
| V8 Ignition (`--jitless`, interpreter) | **1,766** | `node --jitless` |
| our eager-ASM (BeamAsm) | ~130 M (init-dominated for 7 probes) | `/tmp/cal_7asm.exs` |
| our pure-interp (with H1 counter) | ~354 M (44.2 s / 125 tok) | H1 run |

- **Our dynamic op-density: 2.87 M ops/token** (358 M / 125 tok, H1). V8's executed-bytecode density,
  estimated from Ignition 1,766 ns/token ÷ ~0.5–1.5 ns/bytecode threaded-dispatch throughput ≈
  **1,200–3,500 bytecodes/token**. (`--trace-ignition` is removed in V8 12; `--print-bytecode` emits
  ~7,602 bytecodes for the one-parse working set, a static floor.)
- **Op-count ratio ≈ 10³× (≈ 3 orders).** Not 10⁷ (researcher typo), not 10⁴ (my table correction) —
  the researcher's "2–3 orders" was closest. Measured settles it.
- **Wall-time ratio ≈ 10⁴–10⁵×** (≈ op-count gap × per-op cost gap; our per-op cost is also ~10¹–10²×
  V8's: a recursive-Elixir interpreter vs V8's assembly-generated Ignition, plus `call_ext` seams).
- **The floor for a WASM-compiled JS parser is ~1–3 k ops/token (V8 bytecodes); we sit ~10³× above it.**
  The gap is almost entirely compiler-emitted overhead (see H1), not JS computation.

### br_table asm-lane — already supported (prerequisite met, no implementation needed)

`lib/tiny_lasers/wasm/asm_ops/tables.ex`: `br_table` is **fully lowered** via BEAM `select_val` (the O(1)
jump-table instruction) — exactly the dense-index dispatch the researcher recommended. Scope: void
`br_table` (arity-0 targets), which is the type-dispatch case. `test/wasm/asm_tables_test.exs` passes
(4 tests, 0 failures) — oracle-correct.

**But Porffor emits almost no `br_table`** (static <1.3 k; dynamic 0.0% in H1). It emits 20-branch
if-chains. So the asm lane's `br_table` support is *unused* for dispatch. The real lever is one of:
(a) patch Porffor to emit `br_table` for type-dispatch, or (b) add a peephole in *our* WASM→BEAM
transpiler that folds the `if(i32.eq(type,K))` chain pattern to `select_val`. Route (b) is in our
control. **Which route — and whether it's worth it — is decided by H6 below.**

### H6 — per-site polymorphism → RUN, and it overturns "dispatch 30.7%"

Instrumented the interp `run/4` (then reverted; `wasm.ex` clean, build green) to record, for every `if`,
the class of the immediately-preceding instr, and for `if`s preceded by `i32.eq` (0x46) the branch
direction taken keyed by a stable site id (`phash2` of the if-instr). 7-probe acorn subset, pure interp
(`/tmp/h6.exs`):

**Global `if` split (44.36 M total `if` execs — matches H1's 44.4 M):**

| preceding instr | execs | % of `if`s | meaning |
|---|---|---|---|
| `i32.eq` (0x46) | 1,470,354 | **3.3%** | **true type-dispatch if-chains** |
| `local_get` | 159,706 | 0.4% | possible temp-routed dispatch (negligible) |
| **other** | **42,732,439** | **96.3%** | **real parser control flow** |

**Per-site dispatch polymorphism (1,700 distinct dispatch-if sites):**
- **monomorphic-direction sites: 1,647 (96.9%)** — only one branch ever taken.
- **polymorphic-direction sites: 53 (3.1%)** — both branches taken (site sees >1 type).
- But those 3.1% account for **84.3% of dispatch-if executions** — one megamorphic site = 843,769 execs
  (57% of all dispatch-if traffic). Top 20% of sites = 99.5% of executions.
- Classic IC profile: most sites monomorphic, hot sites megamorphic.

**The verdict that changes everything: type-dispatch is ~1% of ops, NOT 30.7%.**
- H1's "dispatch 30.7%" was an **overcount** — it lumped *all* branches (18.3%) + *all* comparisons
  (12.4%) as "dispatch." H6 shows **96.3% of `if`s are acorn's real parsing conditionals** (V8 executes
  them too), not Porffor's type-dispatch if-chains. True type-dispatch ≈ 1.47 M ifs (3.3% of ifs, ~0.4%
  of total ops) + the `i32.eq`s that feed them (~0.5%) + chain overhead ≈ **~1% of total ops.**
- Temp-routed dispatch is negligible (0.4%) — the dispatch is NOT hidden in eq→temp→if patterns; H6's
  count is the real dispatch-if count.

### Re-re-ranked levers (H6 forces a second re-ranking)

| lever | dynamic share attacked | verdict |
|---|---|---|
| **externref / WasmGC → native BEAM terms** | **~20–25%** (addr-arith 11.8 + object-loads ⊂6 + global_get 5.75 + type-tag churn-chunk + dispatch ~1) | **Still #1 by ceiling**, but corrected DOWN from ~54%. Removes the `[f64,i8]` linear-memory representation overhead. The churn that ISN'T representation-driven (~most of 44.7%) is not touched by externref. |
| **churn reduction (fusion + better Porffor codegen)** | ~44.7% churn; fusion ceiling ~6–8% (H2) | **#2.** The biggest *bucket* but mostly general temp traffic (value passing), not representation-specific. Realistic near-term ~6–8% via fusion; deeper gains need patching Porffor's codegen, not our transpiler. |
| **global_get hoisting** | 5.75% | **#3, cheap & orthogonal.** Read globals once per fn-entry, not per op. Low risk. |
| **br_table / dispatch fold** | **~1%** (was 30.7%) | **DROP for perf.** asm-lane already supports `br_table`; Porffor doesn't emit it; the if-chain→`select_val` fold targets only ~1% of ops. Build it only as a completeness/br_table-emit enablement, not a wall lever. |
| constant pooling | — | DROP (H3). |
| CSE on trunc_sat | 0.1% | DROP. |
| AOT-IC via call_indirect (H7) | 0.0003% | DEPRIORITIZE (completeness only). |

### What H6 changed in the story

1. **"Dispatch is the #2 lever" is dead.** It's ~1% of ops. The 30.7% was a measurement artifact (all
   branches≠dispatch). br_table/fold is marginal; the asm lane already supports it anyway.
2. **The ~10³× op-count gap is NOT in the branches.** 96.3% of branches are real parser logic (V8 pays
   them too). The gap lives in Porffor's *representation overhead*: addr-arith (11.8%), loads (6%),
   globals (5.75%), type-tag machinery, and the representation-driven slice of churn. externref attacks
   the representation-driven part (~20–25%); fusion attacks a slice of churn (~6–8%); the rest of churn
   (~35%+) is general temp traffic that needs Porffor-codegen work, not our runtime.
3. **The wall-time gap (~10⁴–10⁵×) is op-count (~10³) × per-op-cost (~10¹–10²).** Even a perfect op-count
   fix (externref + fusion + Porffor codegen → maybe ~3–5× op-count reduction) leaves a ~10²× wall-time
   gap from per-op cost (recursive-Elixir interp / `call_ext` seams vs V8 assembly interp). **Closing the
   wall-time gap needs the ASM lane to absorb the hot path WITHOUT `call_ext` seams** — i.e., the
   representation work (externref) must land in the *ASM* lane, not just the interp, so hot property
   access is a `gc_bif` (`element/2`) not a `call_ext`.
4. **externref spike is the right next build** — but scoped to the ASM lane, attacking the ~20–25%
   representation overhead, with a monomorphic shape-index (96.9% of sites) + megamorphic fallback for
   the hot polymorphic site. Not a full WasmGC rewrite; a minimal externref-for-objects demo first.

---

## Round 2b — externref spike: measured op-count collapse (end-to-end, oracle-identical)

A minimal end-to-end demo (`/tmp/externref_spike.exs`) proving the #1 lever works on our real runtime.
Hand-built two WASM modules (minimal byte encoder), ran each through `TinyLasers.Wasm.call_io` (pure
interp) with an exact op counter, N = 200,000 property accesses:

- **Module A — `[f64,i8]` (current representation):** object in linear memory (f64 value @ base+0, i8
  type tag @ base+8). Property access = load type tag + 20-branch `i32.eq` dispatch chain (re-loading
  the type tag from a local per branch, exactly as Porffor emits) + `f64.load` value. Matches the type
  at branch 7 (type=42). **74.0 ops/access.**
- **Module B — `externref` + host `prop`:** object is a 20-field BEAM tuple passed as an externref arg.
  Property access = `local.get ref` + `i32.const key` + `call host prop` where `prop(ref, key) =
  :erlang.element(key, ref)`. **14.0 ops/access.**
- **Results are bit-identical:** both return 628000.0000021884 (= 3.14 × 200,000). Oracle-true.
- **Delta: 60 ops/access fewer with externref. Ratio: 5.3× fewer ops/access total; ~11× on the access
  portion alone** (66 → 6 ops, the 14/74 totals include ~8 ops of shared loop overhead).

**What the spike proves (and doesn't):**
- externref → BEAM term is **end-to-end runnable on our runtime today** — the decoder accepts `0x6F`,
  `call_io` passes externref args as locals, `table.get/set` carry arbitrary BEAM terms, and the generic
  `call_host` resolves `:tl_imports` by `{mod,name}`. No new runtime machinery was needed for the demo.
- A JS object as a BEAM tuple accessed via `element/2` collapses the per-access op count ~5–11× vs the
  `[f64,i8]` 20-branch dispatch, with identical results. **The #1 lever is real and measurable.**
- The 14 ops/access for Module B still includes a `call` (host `prop`); in the **ASM lane**, if `prop`
  is inlined to a `gc_bif` `element/2` (no `call_ext`), the access drops to ~3 ops → the wall-time win
  compounds (1 BEAM op @ ~3ns vs 66 ops @ ~130ns). **The lever must land in the ASM lane, not just the
  interp, to close the wall-time gap** (per Round-2 point 3).
- Doesn't prove: the full Porffor integration (Porffor would need to emit externref/WasmGC instead of
  `[f64,i8]` — a Porffor patch, out of our control) or the megamorphic-site fallback shape. But it
  validates the runtime substrate and the per-access delta that motivates the investment.

**Net: the spike confirms externref → BEAM terms is the #1 lever (~5–11× per-access op collapse,
oracle-identical), runnable on our runtime today, and the next real build is wiring it into the ASM
lane with a monomorphic shape-index (H6: 96.9% of sites) + megamorphic fallback.**
