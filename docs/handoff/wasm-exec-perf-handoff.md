# Handoff: tiny-lasers WASM execution performance & Porffor conformance

**Date:** 2026-06-30  
**Repo:** `/Users/shinyobjectz/Apps/workbooks/tiny-lasers`  
**Last commit (verified wins):** `72e32a6c` — asm `call_indirect` multi-value, async tier queue, `INV-LOOP-FRESH` false-positive fix  
**Uncommitted WIP:** `compilers/js/porffor/compiler/codegen.js` — `brTable()` rewrite (still failing `wasm-tools validate`)

---

## 1. Goal

Run real JS (acorn parser → eventually Rollup) on the **Porffor → WASM → BEAM-asm** lane fast enough to iterate on conformance. Two levers:

1. **Compilation correctness** — invariant gates must not block valid programs; asm lane must match interpreter oracle.
2. **Execution performance** — warm steady-state asm execution (not one-time compile cost) is the bottleneck.

---

## 2. What was accomplished (committed, green)

### 2.1 `call_indirect` multi-value in asm lane (`t1`)

- **Problem:** Porffor returns JS values as `[f64, i32]` pairs → `call_indirect` needs 2 results. Asm lane only supported ≤1 → **474/486** functions bailed to interpreter.
- **Fix:** `lib/tiny_lasers/wasm/asm_ops/tables.ex` + public `unpack_result_list/3` in `transpile_asm.ex`.
- **Result:** Static bail count **486 → 13**. Oracle-green on asm/differential tests.

### 2.2 Async tier queue (hot functions no longer dropped)

- **Problem:** `compile_one_async` used `:atomics` with `@max_inflight_compiles = 2` and **silently dropped** excess hot functions. They stayed `:miss` in `JitCache` and ran interpreted forever. Probes passing `tier: {:sync, 1}` were a **no-op** — real knobs are `:tier_threshold` (default 20) and `:tier_async` (default true).
- **Fix:** `lib/tiny_lasers/wasm/transpile/async_compiler.ex` — bounded queue GenServer; `enqueue/2` dedups, drains on `:done`. Added to supervision tree in `application.ex`.
- **Result:** `gf360` interp invocations **12,082 → 0** on warm run. Warm wall **~15.6s** vs pure-interp **~37.9s** (**2.43×**).

### 2.3 Red-team: compilation gate false positives fixed

- **Problem:** `INV-LOOP-FRESH` in `cc_invariants.cjs` **over-reports** — output AST cannot distinguish per-iteration `let` declaration (bug) from mutation of outer `let` (correct JS). Blocked **marked 4.3.0** despite being byte-identical to node (16/16) when compiled with `skip_invariants: true`.
- **Fix:** Demote heuristic `INV-LOOP-FRESH` to **non-blocking warning**; sound gate remains `CC_INVARIANTS` in `closure_convert.cjs` (binding provenance). Updated `check_invariants.cjs` JSON to include `warnings`.
- **Result:** Full suite **253 tests, 0 failures** (was 3). Rollup gate frontier moved to **`INV-NO-NATIVE-CAPTURE`** (real gap — native unboxed functions capturing enclosing scope).

---

## 3. Measured numbers (trust these on warm runs)

| Scenario | Wall | Notes |
|---|---|---|
| Pure interpreter | ~37.9s | All funcs interpreted |
| Async-lazy @20 (old mislabeled "eager-asm") | ~18s | Partial asm + dropped hot funcs |
| True sync-eager (threshold 1, sync) | ~117s | All asm but ~80s inline compile |
| **Warm steady-state** (queue fix, threshold 100, max_inflight 8) | **~15.6s** | Production-relevant; `JitCache` populated |

**Warm probe script:** `/tmp/oneshot.exs` — cold run populates cache, warm run timed.

**Seams are NOT the bottleneck:** ~7% of wall on acorn; ~6.3B cheap BEAM ops dominate.

**externref ceiling (synthetic):** `/tmp/externref_time.exs` — `[f64,i8]` 20-branch dispatch vs `externref` + host `element/2`: **4.22×** (3626ms → 859ms for 2M property accesses). Runtime **already supports externref** end-to-end; work is Porffor **codegen**.

---

## 4. Active WIP: `--typeswitch-brtable` / `brTable()` (NOT DONE)

### 4.1 Why it matters

Porffor has `--typeswitch-brtable` (`Prefs.typeswitchBrtable`) that emits `br_table` instead of ~20-branch if-chains for type-tag dispatch (`typeSwitch` → `brTable()` at `compiler/codegen.js:3178`). This is the cheapest execution-pad win **if** emitted wasm validates. Asm lane already lowers void `br_table` (`asm_ops/tables.ex`); result-carrying `br_table` may still bail.

### 4.2 Original bugs (documented in codegen comments)

1. Treated `bc` as object (`Object.keys`, `bc[i]`) instead of array of `[key, value]` pairs from `Object.entries`.
2. Spread closure-valued bodies without calling them → empty case bodies.
3. Unstable `keys.sort((a,b) => b-a).reverse()` — `'default'` vs number → NaN → label/body misalignment.
4. Missing synthesized default (`number(0, returns)`) when no `default` key.

### 4.3 WIP fix attempted (uncommitted in `codegen.js`)

Rewrote `brTable()` to:

- Parse array-form `bc`, stable default-first label map.
- **Defer case bodies** via `[null, () => ...]` thunks (expanded at end of `codegen()` ~line 8273) — case closures are **not idempotent** (allocate locals, mutate scope); eager invocation of all cases was breaking codegen.
- Filter cases by `usedTypes` (match if-chain gate).

### 4.4 Current validation status (still RED)

```bash
cd tiny-lasers
node compilers/js/porffor/runtime/index.js wasm /tmp/brtest.js /tmp/brtest.wasm --typeswitch-brtable
wasm-tools validate /tmp/brtest.wasm
# → error: func 25: type mismatch: expected f64, found i32 (offset 0x1736)

# Without --typeswitch-brtable, brtest also fails (pre-existing Porffor issue):
wasm-tools validate /tmp/brtest_no.wasm
# → func 10: expected f64, found i32

# Acorn + brtable (via mix run /tmp/dump_brtable.exs):
wasm-tools validate /tmp/acorn_brtable.wasm
# → func 14: expected f64 but nothing on stack (offset 0x1e83c)
```

**Interpretation:**

- `"nothing on stack"` — case body still empty or `br` lands at wrong block depth after deferred expansion.
- `"expected f64, found i32"` — case body leaves **type tag (i32)** on stack inside `(block (result f64))`; typeSwitch blocks are typed for **value only** (`returns = valtypeBinary`); `setLastType` stores tag in `#last_type` local but some paths may leave i32 on stack.

### 4.5 Suggested next steps for `brTable`

1. **Validate instrument:** `wasm-tools validate` after every change; minimal repro is `/tmp/brtest.js` (`function g(o) { return o.p; } g({p:1});`).
2. **Disassemble failing func:** `wasm-tools print /tmp/brtest.wasm > /tmp/brtest.wat`, find func 25, locate offset `0x1736`.
3. **Compare if-chain vs br_table output** for the same `typeSwitch` site — compile same JS with/without flag, diff WAT around member-access dispatch.
4. **Verify block/br depth math** — nested `(block (result f64))` + `(block)` × (n-1) + dispatch block; `br_table` label L exits L+1 blocks; body `br (n-1-k)` must target outer result block. See research brief §10.7.
5. **Check deferred callback expansion order** — end-of-codegen loop at `codegen.js:8273` splices `[null, fn]` inline; ensure br_table skeleton + callbacks produce same structure as if-chain after expansion.
6. **Consider `returns === Blocktype.void` vs f64** — some `typeSwitch` calls pass `Valtype.i32` as returns (truthiness); br_table path must respect `returns` param throughout.
7. After Porffor emits valid wasm, check **asm lane** doesn't bail on result-carrying `br_table` (`tables.ex:121` void-only gate).

---

## 5. Execution-pad roadmap (priority order)

| Priority | Task | Status | Ceiling |
|---|---|---|---|
| **A** | Fix `brTable()` → valid wasm with `--typeswitch-brtable` | WIP, RED | Near-term dispatch win on `[f64,i8]` path |
| **B** | **externref** for JS values in Porffor (`t2`) | Not started | **~4×** on dispatch; cuts ~73% register/const churn |
| **C** | Asm lane result-carrying `br_table` | Not started | Needed if br_table bodies carry f64 results |
| **D** | Close `INV-NO-NATIVE-CAPTURE` (rollup frontier) | Not started | Rollup compile blocked; acorn not blocked |

### externref vertical slice map (Porffor codegen)

See research brief §10.8. Key files:

- Value model: `compiler/types.js` (~42 type tags), `allocVar` dual locals (`name` + `name#type`) at `codegen.js:3442`
- Object literals: `generateObject` `codegen.js:6285` → `__Porffor_malloc` + `__Porffor_object_expr_*`
- Property access: `generateMember` → `typeSwitch` `codegen.js:6581` → default `__Porffor_object_get`
- `externref` defined in `wasmSpec.js` Reftype `0x6f` but **unused for values** (only `funcref` for indirect calls)
- Minimal slice: `{x:1}; obj.x` with host externref constructor + `element/2`-style import; ABI knob touching `generateFunc.returns/params`, `assemble.getType`

Spike proving runtime works: `/tmp/externref_spike.exs`, `/tmp/externref_time.exs`

---

## 6. Key files reference

| Area | Path |
|---|---|
| Porffor codegen / `brTable` | `compilers/js/porffor/compiler/codegen.js` |
| Porffor CLI / flags | `compilers/js/porffor/runtime/index.js`, `compiler/prefs.js` (`--typeswitch-brtable`) |
| Closure invariants | `compilers/js/porffor/cc_invariants.cjs`, `closure_convert.cjs`, `check_invariants.cjs` |
| Elixir compile gate | `lib/tiny_lasers/js/porffor.ex` (`check_invariants`, `invariant_gate`, `flags:` passthrough) |
| Asm transpile | `lib/tiny_lasers/wasm/transpile_asm.ex`, `asm_ops/tables.ex` |
| Async tier queue | `lib/tiny_lasers/wasm/transpile/async_compiler.ex` |
| Tier knobs | `lib/tiny_lasers/wasm.ex` lines ~615–775 (`tier_threshold`, `tier_async`) |
| Tests | `test/wasm/asm_tables_test.exs`, `pkg_corpus_test.exs`, `acorn_corpus_test.exs`, `rollup_bundle_gate_test.exs` |
| Research notes (gitignored) | `docs/research/js-wasm-beam-perf-research-brief.md` §10 |

---

## 7. Probes & scripts (`/tmp/`)

| Script | Purpose |
|---|---|
| `oneshot.exs` | Cold+warm acorn wall, gf360 interp counts, JitCache chunk summary |
| `dump_brtable.exs` | Compile acorn with `--typeswitch-brtable` → `/tmp/acorn_brtable.wasm` |
| `brtest.js` | Minimal `{ return o.p }` br_table repro |
| `externref_time.exs` | 4.22× dispatch ceiling measurement |
| `marked_skip.exs` | Proved `INV-LOOP-FRESH` false positive on marked |

**Compile acorn with flags from Elixir:**

```elixir
Porffor.compile(src, root, skip_invariants: true, debug: true, flags: ["--typeswitch-brtable"])
```

**Run with correct tier knobs:**

```elixir
TinyLasers.Wasm.Transpile.AsyncCompiler.set_max(8)
TinyLasers.Wasm.call_io(mod, "m", [], [
  transpile: true,
  tier_threshold: 100,
  fuel: 5_000_000_000,
  max_pages: 16_384
])
```

---

## 8. Test commands

```bash
cd tiny-lasers
mix compile
mix test                                    # full suite — should be 253/0 after commit
mix test test/wasm/pkg_corpus_test.exs      # marked byte-identical gate
mix test test/wasm/asm_tables_test.exs      # br_table asm lowering
mix test test/wasm/acorn_corpus_test.exs    # ~30s, known tokenizer ERR: baseline

# Porffor wasm validity (external)
wasm-tools validate /tmp/brtest.wasm
wasm-tools validate /tmp/acorn_brtable.wasm
```

---

## 9. Known pre-existing issues (not caused by recent work)

- **acorn corpus test:** compiles and completes but tokenizer probes return `ERR:` on asm lane (documented KNOWN GAP in test).
- **bignumber.js / dayjs:** known Porffor gaps in `pkg_corpus_test.exs`.
- **Rollup:** blocked at compile by `INV-NO-NATIVE-CAPTURE` — native closures must be boxed by `closure_convert`.
- **`undefined_label` BEAM compile error:** pre-existing in some multi-function asm chunks; asm lane catches and falls back to interp (does not fail tests).
- **Some Porffor output fails `wasm-tools validate` even without `--typeswitch-brtable`** (e.g. brtest func 10) — separate from brTable work but worth knowing.

---

## 10. Architecture reminders (from `CLAUDE.md`)

- Untrusted JS → WASM (Porffor) → BEAM asm or interpreter. Everything emulated; no native guest execution.
- **Do not trust perf probes** that skip production path stages or use wrong tier options.
- **Validate the instrument first:** if basic cases fail, suspect harness before engine.
- Warm **`JitCache`** steady-state is the production-relevant execution metric; cold compile is one-time.
- Configuration via `.work` / `Nexus.Config` — no JSON sidecars.

---

## 11. Suggested first actions for incoming agent

1. Read this doc + `docs/research/js-wasm-beam-perf-research-brief.md` §10 (if present locally).
2. `git diff compilers/js/porffor/compiler/codegen.js` — review uncommitted `brTable()` rewrite.
3. Fix `brTable` until `wasm-tools validate` passes on `/tmp/brtest.js` with `--typeswitch-brtable`, then acorn.
4. Add a **Porffor regression test** (node script or ExUnit gate) that runs `wasm-tools validate` on a small typeswitch corpus — lock the fix in.
5. Re-bench warm acorn with `--typeswitch-brtable` vs if-chain (expect dispatch op reduction; wall may be modest until asm lane handles result-carrying br_table).
6. If br_table ceiling is insufficient, start **externref** vertical slice per §5B.

---

## 12. Agent transcript

Full prior conversation:  
`/Users/shinyobjectz/.cursor/projects/Users-shinyobjectz-Apps-workbooks/agent-transcripts/0bd20f9a-a600-4891-8354-f47bc00a4f69/0bd20f9a-a600-4891-8354-f47bc00a4f69.jsonl`

Search keywords: `call_indirect`, `AsyncCompiler`, `INV-LOOP-FRESH`, `brTable`, `typeswitch-brtable`, `externref`, `oneshot`, `gf360`.
