/* Closure-conversion output invariants — a STANDING checker, not a test by example.
 *
 * Philosophy (see the closure-conversion redesign notes): conformance testing detects that ASM ≠ oracle on
 * ONE input; it can't say why or where else. The recurring closure_convert bugs are all one violated
 * invariant on the binding/environment model. So instead of bisecting the next failing bundle, we encode the
 * invariants as static checks on the pass's OUTPUT AST. The pass either emits output satisfying them or this
 * errors loudly AT TRANSFORM TIME — before codegen, before washy, with no runtime input needed.
 *
 * Invariants checked (each maps to a real bug class this would have caught structurally):
 *
 *  INV-CAPTURE-BOUND  — every boxed fn `function b$..(__env[, __this]) {…}` that references a captured
 *    `__env_<id>` must bind it (`const __env_<id> = __env.e<id>`) AND list `e<id>` in the box's `env`
 *    literal; every `__this` reference must bind `const __this = __env.__this` (or be a method's `__this`
 *    param) AND have `__this` in env. Catches: nested-arrow `__this` not threaded (the "this is not defined"
 *    bug); param-default capture; any "env.N is not defined".
 *
 *  INV-LOOP-FRESH     — (HEURISTIC; over-reports → NON-BLOCKING WARNING) a per-iteration write
 *    `__env_<id>.name = …` inside a loop where `__env_<id>` is allocated only OUTSIDE the loop. This is the
 *    per-iteration body-const bug shape, BUT the output AST cannot distinguish a per-iteration block-scoped
 *    DECLARATION (bug) from a MUTATION of an outer `let` (correct — one shared cell IS the semantics). The
 *    SOUND version lives where binding provenance exists — closure_convert under `CC_INVARIANTS` asserts
 *    every captured `const`/`let` declared in a loop body is owned by a per-iteration loop env (decidable
 *    there via b.kind + b.declStmt) and THROWS at transform time. This heuristic is surfaced as a WARNING
 *    only (never blocks compilation) — blocking it false-positives correct programs (e.g. marked 4.3.0,
 *    byte-identical to node). Trust the construction-time assertion as the gate.
 *
 * Usage: node cc_invariants.cjs <file.js>   → prints violations, exit 1 if any.
 *        require('./cc_invariants').check(src) → { ok, violations: [{inv, where, detail}] }
 *
 * Conservative by design: only FLAGS shapes it positively recognizes as the closure_convert box form, so a
 * false positive is near-impossible; a missed case just isn't yet covered (extend the recognizers).
 */
const acorn = require('./node_modules/acorn');

function parse(src) {
  for (const t of ['module', 'script']) {
    try { return acorn.parse(src, { ecmaVersion: 2023, sourceType: t, allowReturnOutsideFunction: true }); }
    catch (_) {}
  }
  throw new Error('parse failed');
}

const isFunc = (n) => n && (n.type === 'FunctionExpression' || n.type === 'FunctionDeclaration' ||
  n.type === 'ArrowFunctionExpression');

// Walk with parent + a per-node "inside how many enclosing loops (within the current function)" depth.
function walk(node, visit, parent, loopDepth, fnNode) {
  if (!node || typeof node !== 'object') return;
  if (Array.isArray(node)) { for (const c of node) walk(c, visit, parent, loopDepth, fnNode); return; }
  if (typeof node.type !== 'string') return;
  visit(node, parent, loopDepth, fnNode);
  const entersFn = isFunc(node);
  const nextFn = entersFn ? node : fnNode;
  const nextLoop = entersFn ? 0 : loopDepth; // loop depth resets at a function boundary
  for (const k of Object.keys(node)) {
    if (k === 'type' || k === 'start' || k === 'end' || k[0] === '_') continue;
    const isLoopBody = !entersFn && k === 'body' &&
      (node.type === 'ForStatement' || node.type === 'ForOfStatement' || node.type === 'ForInStatement' ||
       node.type === 'WhileStatement' || node.type === 'DoWhileStatement');
    walk(node[k], visit, node, nextLoop + (isLoopBody ? 1 : 0), nextFn);
  }
}

// Is this node the `fn:` FunctionExpression of a closure box `{ __clo:1, env:{…}, fn: <here> }`?
// Returns the box ObjectExpression, or null.
function boxOfFn(fnNode, parent) {
  if (!parent || parent.type !== 'Property' || parent.value !== fnNode) return null;
  return null; // caller resolves the box separately
}

function objHasClo(obj) {
  return obj && obj.type === 'ObjectExpression' &&
    obj.properties.some(p => p.type === 'Property' && p.key && (p.key.name === '__clo' || p.key.value === '__clo'));
}

// Collect, for a box ObjectExpression, its env-literal keys and its fn FunctionExpression.
function boxParts(obj) {
  let envKeys = null, fn = null;
  for (const p of obj.properties) {
    if (p.type !== 'Property' || !p.key) continue;
    const kn = p.key.name || p.key.value;
    if (kn === 'env' && p.value.type === 'ObjectExpression') {
      envKeys = new Set(p.value.properties.filter(q => q.type === 'Property' && q.key)
        .map(q => q.key.name || q.key.value));
    } else if (kn === 'fn' && isFunc(p.value)) {
      fn = p.value;
    }
  }
  return { envKeys, fn };
}

// Identifiers referenced lexically inside a function body (not descending into nested non-arrow fns for
// `this`/`__this`, but env-id refs are fine to gather across all nested scopes since they'd be rebound).
function refs(fnBody) {
  const envIds = new Set(); let usesThis = false;
  // Collect `__env_<id>` that are LOCALLY allocated inside a nested arrow (`const __env_<id> = {}` /
  // `var __env_<id> = {}` at the arrow's top level). A nested arrow is its own scope: its local env alloc
  // is NOT a free ref of the enclosing fn, so `refs` must not collect it (else INV-CAPTURE-BOUND fires as a
  // false positive — the enclosing fn's prelude can't bind an env that only exists inside the arrow). We
  // still descend into the arrow for lexical `__this` and for ANCESTOR `__env_<id>` refs (reads of envs the
  // enclosing fn genuinely must bind); only the arrow's OWN allocs are excluded.
  function localAllocsInArrow(arrowBody) {
    const loc = new Set();
    (function w(n){
      if (!n || typeof n !== 'object') return;
      if (Array.isArray(n)) { for (const c of n) w(c); return; }
      if (typeof n.type !== 'string') return;
      if (n.type === 'VariableDeclaration') {
        for (const d of n.declarations) {
          if (d.id && d.id.type === 'Identifier' && /^__env_\d+$/.test(d.id.name) &&
              d.init && d.init.type === 'ObjectExpression') loc.add(d.id.name);
        }
      }
      // don't descend into nested fns/boxes inside the arrow — only its own top-level allocs
      if (n.type === 'FunctionExpression' || n.type === 'FunctionDeclaration' ||
          n.type === 'ArrowFunctionExpression' || objHasClo(n)) return;
      for (const k of Object.keys(n)) { if (k === 'type' || k[0] === '_') continue; w(n[k]); }
    })(arrowBody);
    return loc;
  }
  function w(n, lexical, skipEnv) {
    if (!n || typeof n !== 'object') return;
    if (Array.isArray(n)) { for (const c of n) w(c, lexical, skipEnv); return; }
    if (typeof n.type !== 'string') return;
    if (n.type === 'Identifier') {
      if (/^__env_\d+$/.test(n.name) && !skipEnv.has(n.name)) envIds.add(n.name);
      if (n.name === '__this' && lexical) usesThis = true;
      return;
    }
    // A nested closure BOX `{__clo, env:{…}, fn}`: its `env` literal is built HERE (captures this fn's
    // __env_<id>/__this — collect those), but its `fn` body is a SEPARATE scope that rebinds `__env`/`__this`
    // — do NOT descend into it (else its own locals like `const __env_64 = {}` look like free vars here).
    if (objHasClo(n)) {
      for (const p of n.properties) {
        if (p.type !== 'Property') continue;
        const kn = p.key && (p.key.name || p.key.value);
        if (kn === 'fn') continue;
        w(p.value, lexical, skipEnv);
      }
      return;
    }
    // A nested non-box function (helper / pool accessor) is its own scope too — skip its body.
    if (n.type === 'FunctionExpression' || n.type === 'FunctionDeclaration') return;
    // A nested ARROW is its own scope for `__env_<id>` (its local allocs are NOT free vars here), but it
    // keeps LEXICAL `this`, so descend for `__this` and for ancestor `__env_<id>` refs — excluding the
    // arrow's own locally-allocated env ids.
    if (n.type === 'ArrowFunctionExpression') {
      const loc = localAllocsInArrow(n.body);
      const merged = new Set([...skipEnv, ...loc]);
      w(n.body, lexical, merged);
      return;
    }
    for (const k of Object.keys(n)) {
      if (k === 'type' || k[0] === '_') continue;
      w(n[k], lexical, skipEnv); // arrows keep lexical `this`
    }
  }
  w(fnBody, true, new Set());
  return { envIds, usesThis };
}

// What `__env_<id>` / `__this` bindings exist anywhere in this fn's body (not nested fns)?
//   boundCaptured  — `const __env_<id> = __env.e<id>` (captured from the box env; so e<id> must be in env)
//   boundLocal     — `const __env_<id> = {…}` / any other local declaration (a per-iteration/own env alloc)
//   boundThis      — `const __this = __env.__this`
function preludeBinds(fnNode) {
  const boundCaptured = new Set(), boundLocal = new Set(); let boundThis = false;
  (function w(n) {
    if (!n || typeof n !== 'object') return;
    if (Array.isArray(n)) { for (const c of n) w(c); return; }
    if (typeof n.type !== 'string') return;
    if (isFunc(n) && n !== fnNode) return; // a nested fn rebinds its own __env
    if (n.type === 'VariableDeclarator' && n.id && n.id.type === 'Identifier') {
      const nm = n.id.name, init = n.init;
      const fromEnv = init && init.type === 'MemberExpression' && init.object &&
        init.object.type === 'Identifier' && init.object.name === '__env';
      if (/^__env_\d+$/.test(nm)) { if (fromEnv) boundCaptured.add(nm); else boundLocal.add(nm); }
      if (nm === '__this' && fromEnv) boundThis = true;
    }
    for (const k of Object.keys(n)) { if (k === 'type' || k[0] === '_') continue; w(n[k]); }
  })(fnNode.body);
  return { boundCaptured, boundLocal, boundThis };
}

function check(src) {
  const ast = parse(src);
  const violations = [];
  // WARNINGS: non-blocking signals. INV-LOOP-FRESH lives here because the output AST CANNOT distinguish a
  // per-iteration block-scoped DECLARATION (real bug) from a MUTATION of an outer `let` (correct JS — one
  // shared cell IS the semantics). The SOUND, decidable version is the construction-time assertion in
  // closure_convert.cjs (CC_INVARIANTS), which uses binding provenance (b.kind + b.declStmt) and fires
  // during the transform. This heuristic OVER-REPORTS (e.g. marked's correct shared-`let`-in-loop-closure
  // pattern, which is byte-identical to node), so it must NOT block compilation — surface it as a warning
  // and trust the construction-time gate for the real bug class.
  const warnings = [];

  // ── INV-CAPTURE-BOUND ──
  walk(ast, (node) => {
    if (!objHasClo(node)) return;
    const { envKeys, fn } = boxParts(node);
    if (!fn || envKeys == null) return;
    const fnId = (fn.id && fn.id.name) || '<anon box fn>';
    const { envIds, usesThis } = refs(fn.body);
    const { boundCaptured, boundLocal, boundThis } = preludeBinds(fn);
    const params = new Set((fn.params || []).map(p => p.type === 'Identifier' ? p.name : null));

    for (const eid of envIds) {
      const key = 'e' + eid.slice('__env_'.length);
      if (boundLocal.has(eid) || params.has(eid)) continue; // own/per-iteration env alloc — fine
      if (!boundCaptured.has(eid)) violations.push({ inv: 'INV-CAPTURE-BOUND', where: fnId,
        detail: `references ${eid} but no \`const ${eid} = __env.${key}\` prelude (and no local alloc / param)` });
      else if (!envKeys.has(key) && !envKeys.has(eid)) violations.push({ inv: 'INV-CAPTURE-BOUND', where: fnId,
        detail: `binds ${eid} from __env.${key} but the box env literal has no \`${key}\`` });
    }
    if (usesThis && !params.has('__this')) {
      if (!boundThis) violations.push({ inv: 'INV-CAPTURE-BOUND', where: fnId,
        detail: `references __this but no \`const __this = __env.__this\` prelude and not a __this param` });
      else if (!envKeys.has('__this')) violations.push({ inv: 'INV-CAPTURE-BOUND', where: fnId,
        detail: `binds __this from __env.__this but env literal has no \`__this\`` });
    }
  });

  // ── INV-LOOP-FRESH ──
  // The real last-value-wins bug: a closure BOX created INSIDE a loop captures an env `__env_N` (via env
  // literal `eN: __env_N`) that is ALLOCATED ONLY OUTSIDE any loop. Each iteration's box then shares one
  // cell, so every closure observes the final value. The earlier "per-iteration write" heuristic over-reported
  // function-level envs that are written inside a loop but never captured by a loop-created closure (e.g. a
  // shared accumulator correctly hoisted). This precise form fires ONLY when such a box actually exists.
  const allocDepths = new Map(); // envId -> Set(depth)
  walk(ast, (node, _parent, loopDepth) => {
    let id = null, isObjInit = false;
    if (node.type === 'VariableDeclaration') {
      for (const d of node.declarations) {
        if (d.id && d.id.type === 'Identifier' && /^__env_\d+$/.test(d.id.name) &&
            d.init && d.init.type === 'ObjectExpression') { id = d.id.name; isObjInit = true; }
      }
    } else if (node.type === 'AssignmentExpression' && node.operator === '=' &&
               node.left.type === 'Identifier' && /^__env_\d+$/.test(node.left.name) &&
               node.right && node.right.type === 'ObjectExpression') { id = node.left.name; isObjInit = true; }
    if (id && isObjInit) {
      if (!allocDepths.has(id)) allocDepths.set(id, new Set());
      allocDepths.get(id).add(loopDepth);
    }
  });
  // Find box env literals built inside a loop and check each captured env's alloc depths.
  // Also map per-iteration WRITES into each env (a write `__env_N.prop = …` at loopDepth>0). The real
  // last-value-wins bug requires BOTH: a loop-created box captures `__env_N` AND `__env_N` is per-iteration
  // written inside a loop AND `__env_N` is allocated only outside any loop. Capturing a function-level env
  // that is only set up OUTSIDE the loop is fine (every closure correctly sees the same state).
  const loopWrites = new Set(); // envIds with at least one in-loop `.prop = …` write
  walk(ast, (node, _parent, loopDepth) => {
    if (loopDepth === 0) return;
    if (node.type !== 'AssignmentExpression' || node.operator !== '=') return;
    const lhs = node.left;
    if (!lhs || lhs.type !== 'MemberExpression' || lhs.computed) return;
    if (lhs.object && lhs.object.type === 'Identifier' && /^__env_\d+$/.test(lhs.object.name))
      loopWrites.add(lhs.object.name);
  });
  walk(ast, (node, _parent, loopDepth) => {
    if (loopDepth === 0) return;
    if (!objHasClo(node)) return;
    const { envKeys, fn } = boxParts(node);
    if (!fn || envKeys == null) return;
    for (const key of envKeys) {
      // env literal keys are `e<id>` (captured scope id) or `__this`.
      if (key === '__this' || !key.startsWith('e')) continue;
      const env = '__env_' + key.slice(1);
      const depths = allocDepths.get(env);
      // only flag if this env is allocated ONLY outside any loop AND is per-iteration written inside a loop.
      if (loopWrites.has(env) && depths && depths.size > 0 && ![...depths].some(d => d > 0)) {
        // WARNING, not a violation — see the `warnings` doc above. The output AST can't tell a per-iteration
        // declaration (bug) from an outer-`let` mutation (correct); the sound CC_INVARIANTS check in
        // closure_convert.cjs is the real gate. Blocking here false-positives correct programs (e.g. marked).
        warnings.push({ inv: 'INV-LOOP-FRESH', where: env,
          detail: `a closure box created inside a loop captures ${env}, but ${env} is allocated only outside ` +
                  "any loop and is per-iteration written inside a loop → every iteration's closure shares one " +
                  "cell (capture not fresh)" });
      }
    }
  });

  // ── INV-NO-NATIVE-CAPTURE ──
  // Porffor's native closures are incomplete, so closure_convert MUST box every function that captures a
  // binding from an enclosing FUNCTION scope or from an enclosing LOOP BODY (per-iteration block scope). A
  // function left NATIVE (not the `fn:` of a `__clo` box, not a helper) that references such a free variable
  // is a latent miscompile: cross-function captures read garbage; loop-body captures share one cell across
  // iterations (e.g. `for(const x of a){const t=x; f.push(()=>t)}` → every closure returns the last value).
  // Module/top-level bindings are fine (Porffor backs them with wasm globals) UNLESS they are block-scoped
  // inside a loop, which still needs per-iteration freshness.
  //
  // Build a scope chain: each function (and the Program) is a scope with its declared names; we also note,
  // per binding, the nearest enclosing loop body (if any). A free var of a native fn that resolves to a
  // non-global binding, or to a loop-body binding whose loop encloses the fn, is a violation.
  const HELPER = /^(__call\d+|__callS|__cnew|__cproto|__cinst|__defprop|__isFn|__hcb\d|__hof_\w+|__gpool|__spool|__porfIter|__destr_\d+|__cpsThis\d+|__cont\d+|__mr\d+|__av\d+|__rv\d+|__loop\d+|__arr\d+|__i\d+|__env(_\d+)?|__this)$/;
  const boxedFns = new Set();
  walk(ast, (node) => { if (objHasClo(node)) { const { fn } = boxParts(node); if (fn) boxedFns.add(fn); } });

  // collect declarations per function scope, with loop-body marking. Also track CLASS-declared names: a
  // native fn capturing a class CONSTRUCTOR from an enclosing scope is fine in Porffor (classes are hoisted
  // as wasm globals / native class refs resolve across scopes), so those captures must NOT be flagged — the
  // NO-NATIVE-CAPTURE check is about Porffor's broken native closures for ORDINARY bindings, not class refs.
  function declaredNames(fnNode) {
    const names = new Set();
    const classNames = new Set();
    const body = fnNode.type === 'Program' ? fnNode.body : (fnNode.body && fnNode.body.type === 'BlockStatement' ? fnNode.body.body : [fnNode.body]);
    if (fnNode.params) for (const p of fnNode.params) collectPatternNames(p, names);
    (function w(n) {
      if (!n || typeof n !== 'object') return;
      if (Array.isArray(n)) { for (const c of n) w(c); return; }
      if (typeof n.type !== 'string') return;
      if (isFunc(n) && n !== fnNode) { if (n.id && n.id.name) names.add(n.id.name); return; } // nested fn name only
      if (n.type === 'VariableDeclarator' && n.id) collectPatternNames(n.id, names);
      if (n.type === 'FunctionDeclaration' && n.id) names.add(n.id.name);
      if (n.type === 'ClassDeclaration' && n.id) { names.add(n.id.name); classNames.add(n.id.name); }
      if (n.type === 'CatchClause' && n.param) collectPatternNames(n.param, names);
      for (const k of Object.keys(n)) { if (k === 'type' || k[0] === '_') continue; w(n[k]); }
    })({ type: 'Block', body });
    return { names, classNames };
  }
  function collectPatternNames(p, out) {
    if (!p) return;
    if (p.type === 'Identifier') out.add(p.name);
    else if (p.type === 'ObjectPattern') for (const pr of p.properties) collectPatternNames(pr.type === 'RestElement' ? pr.argument : pr.value, out);
    else if (p.type === 'ArrayPattern') for (const e of p.elements) e && collectPatternNames(e.type === 'RestElement' ? e.argument : e, out);
    else if (p.type === 'AssignmentPattern') collectPatternNames(p.left, out);
    else if (p.type === 'RestElement') collectPatternNames(p.argument, out);
  }

  // For each native function, resolve free vars against the enclosing function-scope chain.
  function fnScopes(node, chain) {
    if (!node || typeof node !== 'object') return;
    if (Array.isArray(node)) { for (const c of node) fnScopes(c, chain); return; }
    if (typeof node.type !== 'string') return;
    const isScope = isFunc(node) || node.type === 'Program';
    if (isScope) {
      const { names: myNames, classNames: myClassNames } = declaredNames(node);
      const newChain = [...chain, { node, names: myNames, classNames: myClassNames, isProgram: node.type === 'Program' }];
      if (isFunc(node) && !boxedFns.has(node)) {
        // gather identifiers referenced in this fn's body (not descending into nested fns)
        const free = new Set();
        (function refw(n) {
          if (!n || typeof n !== 'object') return;
          if (Array.isArray(n)) { for (const c of n) refw(c); return; }
          if (typeof n.type !== 'string') return;
          if (isFunc(n) && n !== node) return; // nested fn: its own refs handled when we recurse below
          if (n.type === 'MemberExpression' && !n.computed) { refw(n.object); return; }
          if (n.type === 'Property' && !n.computed && n.key && n.key.type === 'Identifier' && n.key === n.key) { /* still walk value */ }
          if (n.type === 'Identifier') { free.add(n.name); return; }
          for (const k of Object.keys(n)) { if (k === 'type' || k[0] === '_') continue;
            if (n.type === 'Property' && k === 'key' && !n.computed) continue; refw(n[k]); }
        })(node.body);
        const myDecl = myNames;
        for (const v of free) {
          if (myDecl.has(v) || HELPER.test(v) || v === 'undefined' || v === 'arguments') continue;
          // resolve v in enclosing scopes (excluding this fn)
          for (let i = chain.length - 1; i >= 0; i--) {
            const sc = chain[i];
            if (!sc.names.has(v)) continue;
            // A class CONSTRUCTOR captured natively is fine (Porffor resolves class refs across scopes); skip.
            if (sc.classNames && sc.classNames.has(v)) break; // resolved as class ref = ok
            if (!sc.isProgram) {
              violations.push({ inv: 'INV-NO-NATIVE-CAPTURE', where: (node.id && node.id.name) || '<anon fn>',
                detail: `native (unboxed) function captures \`${v}\` from an enclosing function scope — Porffor ` +
                        `native closures are broken, closure_convert must box it` });
            }
            break; // resolved (program-scope = global = ok)
          }
        }
      }
      for (const k of Object.keys(node)) { if (k === 'type' || k[0] === '_') continue; fnScopes(node[k], newChain); }
      return;
    }
    for (const k of Object.keys(node)) { if (k === 'type' || k[0] === '_') continue; fnScopes(node[k], chain); }
  }
  fnScopes(ast, []);

  // de-dup (violations block; warnings surface but never block — see `warnings` doc in check()).
  const seen = new Set(); const uniq = [];
  for (const v of violations) { const k = v.inv + '|' + v.where + '|' + v.detail; if (!seen.has(k)) { seen.add(k); uniq.push(v); } }
  const wseen = new Set(); const wuniq = [];
  for (const w of warnings) { const k = w.inv + '|' + w.where + '|' + w.detail; if (!wseen.has(k)) { wseen.add(k); wuniq.push(w); } }
  return { ok: uniq.length === 0, violations: uniq, warnings: wuniq };
}

function run() {
  const src = require('fs').readFileSync(process.argv[2], 'utf8');
  let res;
  try { res = check(src); } catch (e) { console.error('cc_invariants: ' + e.message); process.exit(2); }
  for (const w of res.warnings) console.error(`[warn ${w.inv}] ${w.where}: ${w.detail}`);
  if (res.warnings.length) console.error(`cc_invariants: ${res.warnings.length} warning(s) (non-blocking — trust CC_INVARIANTS construction-time gate)`);
  if (res.ok) { console.log('cc_invariants: OK (no violations)'); return; }
  for (const v of res.violations) console.error(`[${v.inv}] ${v.where}: ${v.detail}`);
  console.error(`cc_invariants: ${res.violations.length} violation(s)`);
  process.exit(1);
}

if (require.main === module) run();
module.exports = { check };
