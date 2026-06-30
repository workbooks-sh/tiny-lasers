# externref ABI conversion — full touch-point inventory

**Goal:** convert the Porffor JS-value representation from the dual-slot `[f64 value, i32 type-tag]`
model to a single `externref` (wasm reftype `0x6f`) handle. The BEAM asm lane already moves BEAM
terms as externref values transparently (proven: `/tmp/externref_spike.exs`, 4.01× on property-access
dispatch, 75% time saved). The work is **pure Porffor codegen + a host box/unbox import surface**.

**Constraint (CLAUDE.md non-negotiable #1):** green build at all times → land incrementally behind a
flag (`--externref-values` or similar) that flips to default only once the whole path is converted.

---

## 1. Value allocation / locals
- `compiler/codegen.js:8094` — `func.params = new Array(args.length*2)...` alternating f64/i32 pairs (every arg → 2 slots).
- `compiler/codegen.js:110-112` — indirect-call wrapper: `params.push(valtypeBinary, Valtype.i32)`, dual locals `#i` + `#i#type`, idx stepping by 2.
- `compiler/codegen.js:3478-3501` — **`allocVar()`**: when `type=true` ALWAYS creates two locals: value (`name`, f64/i32) + type (`name#type`, i32).
- `compiler/codegen.js:176` — `#array` parallel dual-local in rest-arg handling.
- `compiler/codegen.js:917` — `localTmp` defaults to valtypeBinary.

## 2. Function signatures
- `compiler/codegen.js:7447` — **DEFAULT** `returns: [valtypeBinary, Valtype.i32]` for every FunctionDeclaration/Expression/Arrow.
- `compiler/codegen.js:123, 153` — indirect wrappers return the pair.
- `compiler/assemble.js:143-163` — `getType(params, returns)` bakes pair arity into the wasm FuncType section (funcs + imports).
- `compiler/assemble.js:186, 197` — import/func sections encode pair-based type indices.
- `compiler/assemble.js:430-438` — `call_indirect` type encoding pushes `valtypeBinary, Valtype.i32`, returns the pair.
- `compiler/codegen.js:2936-2937, 3002` — param-slot indexing assumes pair stride (`i*2` when typedParams).

## 3. Type-tag production / consumption
- `compiler/codegen.js:1851-1877` — `getLastType()` / `setLastType()` / shared i32 `#last_type`.
- `compiler/codegen.js:745, 778, 995, 1008, 1372, 1435, 2449, 2457` — setLastType call sites.
- `compiler/codegen.js:1936, 1951, 2009, 2049, 2114` — getLastType reads (fallback inference).
- `compiler/codegen.js:3302-3465` — **`typeSwitch()`** core type dispatch on TYPES.* (the polymorphism hinge; brTable lives here).
- `compiler/codegen.js:2513, 2629` — getNodeType → typeSwitch (prototype/member dispatch).
- `compiler/codegen.js:6505-6533` — member eval captures property type in `#member_prop_type*` i32 temp.

## 4. Object & member ops
- `compiler/codegen.js:6321-6397` — `generateObject`: pushes `TYPES.object`, value-then-type per property, calls `__Porffor_object_expr_*`.
- `compiler/codegen.js:6451-6700+` — `generateMember`: `__Porffor_object_get`/`_withHash` take obj+key pairs, return a pair.
- `compiler/codegen.js:4566-4580, 6829-6831` — object get/set builtin call sites (all pairs).
- `compiler/builtins/_internal_object.ts:4-19` — object memory layout: `f64 value (8) + u16 type+flags (2)` per entry.
- `compiler/builtins/_internal_object.ts:22-665, 743-859` — `__Porffor_object_hash/writeKey/lookup/readValue/get/set/...` all assume `any` = pair.

## 5. Builtin signatures
- ~**379 of 626** exported builtins take `any` params (≈61% of surface) → re-lower from `.ts` with new signature.
- Hot files: `_internal_object.ts`, `array.ts`, `string.ts`, `object.ts`, `number.ts`, `json.ts`, `promise.ts`, `regexp.ts`.
- Registration: `includeBuiltin(scope, name)` resolves `.index`; callee `.params`/`.returns` already pair-shaped by codegen.

## 6. Elixir asm-lane bridge
- `lib/tiny_lasers/wasm.ex:649-656` — `call_fn` returns stack top; pair-returning funcs give 2-elem result `[value, type]`.
- `lib/tiny_lasers/wasm.ex:2124-2126` — interpreter explicitly handles `[value, type]` pairs (single-value form drops the type).
- `compiler/wrap.js:32-74` — `porfToJSValue({memory,funcs,pages}, value, type)` deserializes pair → JS; becomes `porfToJSValue(externref_handle)`.

## 7. Existing externref support
- `compiler/wasmSpec.js:50-52` — `Reftype = {funcref:0x70, externref:0x6f}` defined, **unused** for values.
- `lib/tiny_lasers/wasm.ex:1259-1306` — `guest_table_*` (get/set/size/grow/fill) + `guest_ref_is_null` exist for funcref; externref table would follow.
- `lib/tiny_lasers/wasm.ex:129-132` — table import parsing reads reftype byte but discards it (no funcref/externref distinction tracked).

### Minimal host-import surface to add
```
__Porffor_box_value   : [valtypeBinary, i32]      -> [externref]   # pair -> handle
__Porffor_unbox_value : [externref]               -> [valtypeBinary, i32]   # handle -> pair
__Porffor_externref_get : [externref, <key pair>] -> [<value>]     # element/2-style property read
```
None defined yet; wire through `lib/tiny_lasers/js/porffor_host.ex` `host_call/1` + the runtime import dispatch.

---

## REALIZATION DECISION (measured 2026-06-30)

Target refined to **objects-as-host-terms**, NOT a full value-ABI rewrite: heap objects live host-side
as BEAM terms; primitives (number/bool) keep the unboxed `[f64, i32]` pair so arithmetic stays fast.

Two realizations measured (`/tmp/handle_bench.exs`, 2M property accesses, real `call_io` lane):

| Realization | Wall | vs true-externref |
|---|---|---|
| True externref (object = externref slot, host `element/2`) | 840ms | 1.00× |
| **i32-handle + host object table** (value slot = i32 handle, host map lookup) | 861ms | **1.03×** |
| (baseline: `[f64,i8]` + 20-branch dispatch) | ~3440ms | 4.1× slower |

**Chosen: i32-handle + host object table.** It captures essentially the full 4× win while keeping the
pair ABI 100% intact — NO externref valtype, NO signature changes, NO 3-slot ABI. The object's "value"
slot holds an i32 handle into a host-resident object table (handle → BEAM map/tuple). This means the
externref valtype plumbing (Stage 1 below) is NOT on the critical path; the build collapses to swapping
the `__Porffor_object_*` builtins + object literal creation to host imports keyed by handle.

### Revised staged path (handle model) — STATUS
1. ✅ **Host object model** (`lib/tiny_lasers/js/host_objects.ex`): process-dict handle→`%{hash=>{val,type}}`
   table; imports `ho_new/ho_set/ho_get_value/ho_get_type/ho_has` (single-value returns). Keys = Porffor
   property hash (computed in-guest → closures never read guest memory). Commit `8c88793e`.
2. ✅ **codegen flag** `--host-objects` (`05f5b544` assemble named-imports, `152a6e78` Stage 3, `dab77934`
   Stage 4): `generateObject` literal → `ho_new`+`ho_set`; member read/write typeSwitch object case
   branches on the handle TAG BIT (HOST_OBJ_TAG=0x80000000) at runtime → tagged = `ho_*`, else memory.
   Runtime branch covers dynamically-typed receivers (loop vars, params) + property writes. Default off.
3. ⏳ **Identity/semantics**: computed-key `obj[k]`, compound assign `obj.x += v`, and object builtins
   (Object.keys/spread/JSON/`in`/`delete`/prototype) don't yet understand tagged handles — fall through
   to memory. Next sub-stages. Proxy → pair-ABI fallback.
4. ✅ **Gate**: oracle-matched vs the in-memory lane through `call_io` (host_objects_codegen_test 11/11,
   static + loop + param + write). Full suite 278/0 flag-off.

### PROVEN PERF (Stage 4, `dab77934`)
Hot property read+write loop (2M iters), production interpreter lane, oracle-identical results:
**default 114756ms vs host-objects 35743ms = 3.21×** (near the 4.1× synthetic ceiling; gap = shared
loop/arithmetic overhead). The objects-as-host-terms thesis is validated end-to-end on real compiled JS.

The original externref-valtype staged path below is retained for reference only (superseded by the
handle model unless a future need for true externref values—e.g. GC handoff—reappears).

## Staged conversion path — SUPERSEDED (externref-valtype, for reference)
1. **Spec + assemble:** externref valtype + type indices for externref returns (`wasmSpec.js`, `assemble.js`).
2. **Host imports:** `box_value`/`unbox_value`/`externref_get` in `porffor_host.ex` + runtime dispatch; reuse `:tl_imports` BEAM-term passthrough proven in the spike.
3. **codegen flag:** split `allocVar`, func signature init, call sites on `Prefs.externrefValues`; parallel path, default off.
4. **Builtins:** re-lower `any`-typed builtins to externref signatures (start with `_internal_object.ts`).
5. **Interpreter:** `wasm.ex` 1-result unpack path for externref-returning funcs; `wrap.js` single-handle deserialize.
6. **Cutover:** flip default once the corpus oracle-matches the pair ABI on the real lane.

## Risk notes
- typeSwitch (§3) is the polymorphism hinge — under externref, type reads become host dereferences; measure per-`typeSwitch` overhead vs the 4× dispatch win (net should stay strongly positive per spike, but verify on real corpus, not synthetic).
- Object memory layout (§4) is incompatible between models — needs box/unbox at the boundary during the parallel-path phase.
- Gate every stage on oracle-match through `call_io` (the production lane), never `wasm-tools validate` (it rejects benign Porffor builtin patterns the asm lane runs correctly — see brTable, commit `e7584e1e`).

## Stage 5 — empirical gap map + default-on roadmap (the "grind to default-on" path)

Probed real object ops under `--host-objects` vs the default oracle (`/tmp/ho_gaps.exs`). Only **1 of 10**
works; the rest **trap** (tagged handle flows into a memory builtin → out-of-bounds):

| op | status | why |
|---|---|---|
| static `.prop` read/write (+nested) | ✅ | the Stage 4 tag-branch paths |
| computed `o[k]` read/write | ❌ | need runtime hash `__Porffor_object_hash` (attempted — host branch fires but the hash-builtin call errors "bad argument in arithmetic"; the key value/type stack shape into the builtin needs debugging) |
| compound `o.x += v` | ❌ | write branch only handles `op === '='`; need ho_get + performOp + ho_set |
| `Object.keys`, `for-in`, `JSON.stringify`, spread `{...o}` | ❌ | **data-model wall**: ho_set stores by HASH, discards the key string → table can't enumerate |
| `'x' in o`, `delete o.x` | ❌ | the `in`/`delete` operator codegen isn't tag-aware |

**Default-on requires the whole object-operation surface to be tag-aware — multi-session. Order:**

1. **5a computed keys** — extend the member tag-branch to compute `__Porffor_object_hash(key)` at runtime
   into a temp (hash space matches ctHash). Debug the "bad argument in arithmetic" (likely the key
   value+type pair shape pushed into the builtin, or the builtin reading guest memory for the key string).
2. **5b compound assign** — in the set tag-branch, for `op !== '='`: ho_get_value/type → `performOp(op, …)`
   → ho_set. (Self-contained codegen.)
3. **5c DATA MODEL (keystone)** — store the ORIGINAL KEY in the host table, not just the hash. ho_set
   takes (handle, keyPtr, keyLen, value, type); the closure reads the key bytes via `Process.get(:tl_mem)`
   + `TinyLasers.Wasm.read_bytes/3` (confirmed reachable from a :tl_imports closure) and stores
   `hash => {key, value, type}`. Reads stay hash-keyed (fast — perf preserved). Add `ho_keys(handle) ->`
   (array/iterator), `ho_has(handle, hash)` (already present), `ho_delete(handle, hash)`.
4. **5d tag-aware builtins** — `in`/`delete` operator codegen + `Object.keys`/`Object.entries`/`for-in`/
   `JSON.stringify`/spread: branch on the tag bit → host op (ho_keys/ho_has/ho_delete) else memory. This
   is the big surface; each builtin's entry checks the tag.
5. **5e flip default** — once the corpus (acorn → rollup) oracle-matches host vs memory, make `--host-objects`
   default-on for the batch lane. Bound the per-run table (arena-on-exit already fits the build lane).

**Reminder (validated):** the 3.26× holds on the production asm lane; the win is the native BEAM map vs the
in-memory hash+dispatch. The risk is coherence across the host/memory two-world split, not perf.

## Stage 5 / Phase A+C progress (gap probe 6/10, was 1/10)

Committed, all oracle-matched vs the in-memory lane, full suite 293/0 flag-off:
- **Phase A computed keys** (`ef01078a`): `o[k]` read/write — runtime `toPropertyKey` + `__Porffor_object_hash`
  into a temp (matches ctHash), reused by ho_get_value/ho_get_type/ho_set.
- **Phase A compound assign** (`f56ef396`): `o.x += v` — `performOp(op, ho_get_value(old), rhs)` host-side, then ho_set.
- **Phase C hash-ops** (`<this batch>`): `key in obj` → ho_has; `delete obj.key` → ho_delete (new import).
  Both keyed by `__Porffor_object_hash`, no key storage needed (booleans). Caveat: in/delete re-eval the
  receiver on the memory branch (fine for identifier receivers; side-effecting receivers = edge case).

Still trapping (4): **Object.keys, for-in, JSON.stringify, spread** — the ENUMERATION set. All need:

### Phase B+C enumeration design (the remaining keystone work)
1. **Store keys (ordered)** — host table becomes `handle => %{entries: %{hash => {key, value, type}}, order: [hash,…]}`.
   `ho_set` ABI grows to `(handle, hash, keyPtr, keyType, value, type)`; the closure reads the Porffor string
   at keyPtr via `Process.get(:tl_mem)` + `read_bytes/3` (layout: i32 length prefix + chars — 1 byte/char
   bytestring, 2 bytes/char UTF-16 string). Codegen passes keyPtr: static keys `allocStr(scope, name)`;
   computed keys the toPropertyKey string pointer (tee'd). Reads stay hash-keyed (3.26× preserved).
2. **Host→guest marshalling protocol** — the hard part. Enumeration builtins must produce GUEST structures:
   - `ho_count(handle) -> i32`, `ho_key_at(handle, i, bufPtr, bufCap) -> len` (host writes key bytes into a
     guest buffer, à la __host_call), so the guest builtin builds the array/string with its own malloc.
   - Re-lower `__Object_keys`/`values`/`entries`, the `for-in` enumerator, `JSON.stringify`, and object
     spread to tag-check the receiver → host iteration protocol; else the in-memory path.
3. This is a coordinated host + `.ts`-builtin change; do it as a focused effort, oracle-gated per builtin.

After enumeration: Phase D coherence (fork/snapshot/identity/GC), Phase F corpus-clean + flip default, Phase G strings/arrays.

## Phase A + B COMPLETE; Phase C enumeration-builtins remain (foundation ready)

**Phase A complete** (read/write surface): static + computed `o[k]` read/write, compound `o.x += v`,
optional chaining `o?.x`/`o?.[k]`, numeric keys, deep nested writes `o.a.b.c = v`, 3-deep reads.
(Remaining exotic: symbol keys, `__proto__`, accessor getters/setters — deferred.)

**Phase C hash-ops complete**: `key in obj` → ho_has, `delete obj.key` → ho_delete.

**Phase B complete** (key storage / enumeration foundation, commits `3dc649d0`, `e7ff4477`):
- Host table per-handle `%{e: hash=>{value,type}, order: [hash], keys: hash=>key_string}`.
- `ho_regkey(handle, hash, keyPtr, keyType)` reads the Porffor string from `:tl_mem`; emitted by
  generateObject (literals) AND static member writes. Insertion order preserved (owned by ho_set).
- Marshalling primitives: `ho_count(handle) -> i32`, `ho_key_at(handle, idx, bufPtr) -> len` (writes the
  idx-th key as a Porffor bytestring at bufPtr — which IS a valid guest string, no extra construction).
- Reads stay hash-keyed; 3.26× preserved. Verified: literal + member-write keys enumerate in order.

### Phase C enumeration builtins — the remaining surface (all primitives ready)
Each needs a tag-branch at its entry → host loop over `ho_count`/`ho_key_at`; else the in-memory path:
- **for-in** (`generateForIn`, codegen): host branch loops `i in 0..ho_count`, `ho_key_at(h,i,buf)` →
  bind loop var to `buf` (bytestring pointer, type bytestring) → run body. Buffer = a malloc'd/page scratch.
- **Object.keys/values/entries** (builtin/codegen intercept): build a guest array by the same loop;
  values via `ho_get_value`/`ho_get_type(h, object_hash(key))`.
- **JSON.stringify**: walk keys host-loop, emit `"key":value` — reuse the keys + values.
- **spread `{...o}` / `Object.assign`**: loop keys, `ho_set`/`ho_regkey` into the target (host or memory).
- **prototype chain / instanceof / hasOwnProperty / defineProperty / Object.create / Reflect / Map-Set**:
  bigger semantic surface, after the core enumerators.
Approach choice: codegen interception (like in/delete) avoids regenerating builtins_precompiled.js; the
host-loop + ho_key_at buffer pattern is uniform across all four core enumerators.

## Phase C progress: 7/10 (for-in done) — final 3 enumeration builtins remain

Gap probe now 7/10 OK: static+computed read/write, compound assign, in, delete, **for-in**.
- **for-in** (`255c38f5`): generateForIn host path — tag-branch loops ho_count, ho_key_at(i) writes the
  i-th key as a Porffor bytestring into a scratch page (the buffer IS the guest string), binds loop var,
  runs body. Proves the host->guest marshalling primitive works.

Remaining 3 — **Object.keys, spread `{...o}`, JSON.stringify** — each must return a guest ARRAY/OBJECT/
STRING (heavier than for-in's loop-var binding). Unified approach (the keystone for all three):

### `hostMaterialize(scope, objWasm)` — host handle → in-memory Porffor object
Generate inline wasm: if the receiver is tagged → build a fresh memory object and copy every property in
(loop ho_count; ho_key_at(i)→key bytestring; hash=object_hash(key); val/type=ho_get_value/type(hash);
`__Porffor_object_set(memObj, key, bytestring, val, type)`); else pass the receiver through unchanged.
Then the EXISTING builtins work on the materialized object:
- `Object.keys/values/entries(o)` → `__Object_keys(materialize(o))` — intercept the CallExpression callee.
- spread `{...o}` → materialize before `__Porffor_object_spread`.
- `JSON.stringify(o)` → materialize before the stringify builtin.
One helper unblocks all three; reuse is the win. Materialize allocates a memory object per enumeration
call (NOT on the hot read/write path, so the 3.26× is unaffected). Intercept at the codegen call sites
(like in/delete) to avoid regenerating builtins_precompiled.js; guard against shadowed `Object`/`JSON`.

After these: Phase A exotic (symbol keys, __proto__, accessors), Phase D coherence (fork/snapshot/GC/
identity), Phase F corpus-clean + flip default, Phase G strings/arrays.

## Phase H — Web Platform / StarlingMonkey-class host APIs (appended goal)

Real-world JS (and the npm conformance ladder) depends on Web Platform APIs that aren't ECMAScript and
aren't in Porffor's builtin set. StarlingMonkey ships these on SpiderMonkey; tiny-lasers needs them as
SANDBOXED host imports (entropy/network/clock are host-mediated and gated per the sandbox policy — network
denied-or-gated, clock/rand controlled, no host exec). Mark each off as landed; verify Porffor's existing
`crypto.ts` for completeness first (it exists but may be partial).

- **Web Crypto** — `crypto.getRandomValues` (host CSPRNG), `crypto.randomUUID`, `crypto.subtle.*`
  (digest/HMAC/AES/ECDSA/RSA/deriveKey) — gates auth, hashing, JWT, many libs. Highest priority.
- **Encoding** — `TextEncoder`/`TextDecoder`, `btoa`/`atob`, `structuredClone`.
- **URL** — `URL`, `URLSearchParams`.
- **Timers** — `setTimeout`/`setInterval`/`clearTimeout` (map onto Nexus.Time/Scheduler-style host timers,
  cooperatively scheduled; fuel-bounded).
- **fetch stack** — `fetch`, `Headers`, `Request`, `Response` (network GATED by policy; off by default).
- **Streams** — `ReadableStream`/`WritableStream`/`TransformStream` (needed by fetch + modern bundlers).
- **Misc** — `performance.now`, `queueMicrotask`, `AbortController`/`AbortSignal`, `console.*` (exists).

Note: the **Phase A exotic** items (symbol keys, `__proto__`, accessor getters/setters) and the rest of
**Phase C** (Object.keys/values/entries/assign/defineProperty, JSON.stringify/parse, spread,
Object.create/prototype/instanceof/hasOwnProperty, Reflect, Map/Set) stay on the list — mark each off as
implemented. Phase H runs parallel to A–G; it's host-import surface (porffor_host.ex), not object-ABI work.
