/* Shared-environment closure conversion for the Porffor lane.
 *
 * COMPLEMENTS closure_promote.cjs — does NOT replace it. Handles the cases plain Porffor can't:
 * capturing closures, per-iteration `for(let i) ()=>i`, re-entrant factories, AND (the redesign)
 * sibling closures sharing ONE mutable variable + nested mutually-recursive functions.
 *
 * THE MODEL — per-scope shared environment records (textbook closure conversion):
 *   - Every function scope (and the module/top scope) gets a numeric scopeId.
 *   - A binding is CAPTURED if referenced from a function nested below its owner scope. The OWNER scope
 *     is where that binding's env-slot lives.
 *   - For each scope that owns >=1 captured binding we allocate ONE env object `__env_<id> = {}` at the
 *     TOP of that scope body, BEFORE any other statement — so forward / mutually-recursive references
 *     (`function g(){return h()..}` declared before h) resolve, and so every sibling closure created in
 *     that scope reads/writes the SAME slot (shared mutation).
 *   - Captured bindings are accessed as `__env_<id>.name` EVERYWHERE — owner scope and every nested
 *     closure, reads AND writes (`x=..`->`__env_N.x=..`, `++x`->`++__env_N.x`).
 *   - A closure capturing bindings owned by scopes {a,b,..} is boxed `{__clo:1, env:{ea:__env_a,..}, fn}`.
 *     Its fn gains a leading `__env` param and re-binds the envs locally at entry
 *     (`const __env_a=__env.ea, __env_b=__env.eb;`), so uniform `__env_<id>.name` access works inside.
 *   - Call sites route through fixed-arity dispatch helpers `__callN(f,a..)`:
 *       if f && f.__clo -> f.fn(f.env, a..) else f(a..). Fixed arity because Porffor's arguments-grow is
 *       broken; N from static arg count. `__callS` handles the single canonical spread form `fn(...arr)`.
 *
 * On ANY error / unsupported shape -> return source unchanged (never emit silently-wrong code).
 */
const acorn = require('acorn');
const { generate } = require('astring');

const GLOBALS = new Set(['console','Math','JSON','Object','Array','String','Number','Boolean','Symbol',
  'Map','Set','WeakMap','WeakSet','Promise','Error','TypeError','RangeError','SyntaxError','parseInt',
  'parseFloat','isNaN','isFinite','undefined','NaN','Infinity','globalThis','Function','RegExp','Date',
  'BigInt','encodeURIComponent','decodeURIComponent','structuredClone','arguments',
  '__porf_replace_fn','Porffor',
  // Typed-array / buffer intrinsic constructors: `new DataView(...)` etc. must stay NATIVE, not routed
  // through __cnew (which returns `any`). __cnew erases the static type tag, so Porffor can no longer
  // resolve instance methods (`dv.getFloat64`, `u8.subarray`) — they become `undefined`. These are global
  // intrinsics that can never hold a user box, so a direct `new`/member is always correct.
  'ArrayBuffer','SharedArrayBuffer','DataView','Uint8Array','Uint8ClampedArray','Int8Array','Uint16Array',
  'Int16Array','Uint32Array','Int32Array','Float32Array','Float64Array','BigInt64Array','BigUint64Array',
  // Porffor host-bridge import: it resolves in codegen's `name in importedFuncs` branch ONLY as a DIRECT
  // call. Routing it through __callN makes it an indirect call_indirect → the import is never marked used,
  // never emitted, and the call silently hits table slot 0. Keep it (and __host_call_async) direct.
  '__host_call','__host_call_async']);

// Native method names. Detecting a box at a member call requires READING the method as a value
// (`recv.m.__clo`); doing so on a primitive STRING corrupts the very next native call (Porffor type-directs
// string methods at the member node — the value-read drops that, so the following `recv.m(...)` returns
// wrong data / traps). Receiver type is unknown statically, so any name String OR Array exposes is
// probe-unsafe and must stay a plain native call (never dispatched). Object-ish / collection / promise
// names (get/set/has/then/…) are probe-SAFE (object receivers survive the read) and are common user-box
// method names, so they are deliberately LEFT OUT and DO get box dispatch.
const NATIVE_METHODS = new Set([
  // Array.prototype
  'push','pop','shift','unshift','slice','splice','concat','join','reverse','indexOf','lastIndexOf',
  'includes','fill','flat','flatMap','copyWithin','keys','values','entries','at','find','findIndex',
  'findLast','findLastIndex','map','filter','forEach','reduce','reduceRight','some','every','sort',
  // String.prototype
  'charAt','charCodeAt','codePointAt','substring','substr','toUpperCase','toLowerCase','trim',
  'trimStart','trimEnd','split','repeat','padStart','padEnd','startsWith',
  'endsWith','match','matchAll','search','normalize','localeCompare',
  // NOTE: 'replace'/'replaceAll' are deliberately OMITTED. A probe of `.replace` off a string/array
  // receiver is safe (returns the native method), and user objects commonly override `.replace` as a
  // boxed chain method (e.g. marked's edit() grammar builder). Box dispatch falls back to the native
  // method for real strings, so omitting them keeps string replace working while fixing object overrides.
]);

function parse(src) {
  for (const sourceType of ['module','script']) {
    try { return acorn.parse(src, { ecmaVersion: 2023, sourceType, allowReturnOutsideFunction: true }); }
    catch (_) {}
  }
  throw new Error('parse failed');
}

const isFunc = n => n && (n.type === 'FunctionDeclaration' || n.type === 'FunctionExpression' || n.type === 'ArrowFunctionExpression');

// Does a function body reference `super` anywhere? `super` is lexically bound to its class method, so a
// method using it CANNOT be moved into a box — bail those.
function usesSuper(fnNode) {
  let found = false;
  (function walk(n){
    if (found || !n || typeof n !== 'object') return;
    if (n.type === 'Super') { found = true; return; }
    for (const k in n) { if (k === 'type' || k[0] === '_') continue; const v = n[k];
      if (Array.isArray(v)) { for (const c of v) if (c && c.type) walk(c); }
      else if (v && v.type) walk(v); }
  })(fnNode.body);
  return found;
}

// Does a function use `this` lexically — at its own level or in nested arrows (which inherit it), but not
// inside nested regular functions (their own `this`)? Used to decide if a boxed arrow must capture `this`.
function usesThisLexically(fnNode) {
  let found = false;
  (function walk(n, lexical){
    if (found || !n || typeof n !== 'object') return;
    if (n.type === 'ThisExpression') { if (lexical) found = true; return; }
    const each = c => { if (!c || !c.type) return;
      if (c.type === 'ArrowFunctionExpression') walk(c, lexical);
      else if (isFunc(c)) walk(c, false);
      else walk(c, lexical); };
    for (const k in n) { if (k === 'type' || k[0] === '_') continue; const v = n[k];
      if (Array.isArray(v)) v.forEach(each); else each(v); }
  })(fnNode.body, true);
  return found;
}

// Does a function lexically reference an ALREADY-rewritten `__this` identifier (at its own level or in a
// nested arrow)? `rewriteMethodThis` rewrites `this`→`__this` through nested arrows, so an inner boxed
// continuation (e.g. chained `.then` arrows from the async desugar) ends up referencing `__this` with no
// `ThisExpression` left — `usesThisLexically` then misses it and the box neither captures nor binds
// `__this`, throwing `__this is not defined` (Porffor reports it as `this`). Detect that case here so the
// box captures the enclosing `__this` from its env.
function usesEnvThisLexically(fnNode) {
  let found = false;
  (function walk(n, lexical){
    if (found || !n || typeof n !== 'object') return;
    if (n.type === 'Identifier' && n.name === '__this') { if (lexical) found = true; return; }
    const each = c => { if (!c || !c.type) return;
      if (c.type === 'ArrowFunctionExpression') walk(c, lexical);
      else if (isFunc(c)) walk(c, false);
      else walk(c, lexical); };
    for (const k in n) { if (k === 'type' || k[0] === '_') continue; const v = n[k];
      if (Array.isArray(v)) v.forEach(each); else each(v); }
  })(fnNode.body, true);
  return found;
}

// Rewrite `this`→`__this` at the method's own level and inside nested ARROWS (which inherit the method's
// `this` lexically), but NOT inside nested regular functions (those rebind `this`). A non-boxed nested
// arrow reads `__this` lexically from the method's param; boxed arrows are gated out by methodThisOk.
function rewriteMethodThis(node) {
  if (!node || typeof node !== 'object') return;
  if (isFunc(node) && node.type !== 'ArrowFunctionExpression') return;
  for (const k in node) { if (k === 'type' || k[0] === '_') continue; const v = node[k];
    if (Array.isArray(v)) { for (let i = 0; i < v.length; i++) {
      if (v[i] && v[i].type === 'ThisExpression') v[i] = { type:'Identifier', name:'__this' };
      else rewriteMethodThis(v[i]); } }
    else if (v && v.type === 'ThisExpression') node[k] = { type:'Identifier', name:'__this' };
    else rewriteMethodThis(v); }
}

function patternNames(node, out) {
  if (!node) return;
  switch (node.type) {
    case 'Identifier': out.push(node.name); break;
    case 'RestElement': patternNames(node.argument, out); break;
    case 'AssignmentPattern': patternNames(node.left, out); break;
    case 'ArrayPattern': node.elements.forEach(e => patternNames(e, out)); break;
    case 'ObjectPattern': node.properties.forEach(p => patternNames(p.type === 'RestElement' ? p.argument : p.value, out)); break;
  }
}
function patternIdentNodes(node, set) {
  if (!node) return;
  switch (node.type) {
    case 'Identifier': set.add(node); break;
    case 'RestElement': patternIdentNodes(node.argument, set); break;
    case 'AssignmentPattern': patternIdentNodes(node.left, set); break;
    case 'ArrayPattern': node.elements.forEach(e => patternIdentNodes(e, set)); break;
    case 'ObjectPattern': node.properties.forEach(p => patternIdentNodes(p.type === 'RestElement' ? p.argument : p.value, set)); break;
  }
}
function children(node) {
  const out = [];
  for (const k in node) {
    if (k === 'type' || k[0] === '_') continue;
    const v = node[k];
    if (Array.isArray(v)) { for (const c of v) if (c && c.type) out.push(c); }
    else if (v && v.type) out.push(v);
  }
  return out;
}

function transform(src) {
  const ast = parse(src);

  let nextId = 0;
  let boxNameCounter = 0;
  let nextScope = 0;
  const bindings = new Map();
  const bindingNodes = new Set();
  // Identifier ref-node -> scopeId whose env is NOT yet built when this ref evaluates (a param
  // default value runs before its own function body, where `const __env_<sid> = {}` lives). Such a
  // ref must stay a RAW identifier, not be rewritten to `__env_<sid>.name`. Only refs owned by THAT
  // same scope are unsafe; refs to outer (already-initialized) envs rewrite normally.
  const paramDefaultRefs = new Map();
  function collectIdentNodes(node, out) {
    if (!node || typeof node.type !== 'string') return;
    if (node.type === 'Identifier') { out.push(node); return; }
    for (const c of children(node)) collectIdentNodes(c, out);
  }
  // Identifier refs in a PARAMETER that evaluate at call/param-binding time — i.e. BEFORE the function
  // body (and its `const __env_<sid> = __env.e<sid>` rebind) runs. These are default values
  // (`a = expr`) AND computed destructuring keys (`{[expr]: x}`), at any nesting depth. Binding targets
  // themselves are skipped (they're in bindingNodes). Such refs must reach the env via the `__env` PARAM,
  // not the not-yet-bound body-local `__env_<sid>`.
  function collectParamPreBodyRefs(node, out) {
    if (!node || typeof node.type !== 'string') return;
    switch (node.type) {
      case 'AssignmentPattern':
        collectIdentNodes(node.right, out);
        collectParamPreBodyRefs(node.left, out);
        break;
      case 'ArrayPattern':
        node.elements.forEach(e => collectParamPreBodyRefs(e, out));
        break;
      case 'ObjectPattern':
        node.properties.forEach(p => {
          if (p.type === 'RestElement') { collectParamPreBodyRefs(p.argument, out); return; }
          if (p.computed) collectIdentNodes(p.key, out);
          collectParamPreBodyRefs(p.value, out);
        });
        break;
      case 'RestElement':
        collectParamPreBodyRefs(node.argument, out);
        break;
    }
  }
  const funcMeta = new Map();   // funcNode -> { node, parentFunc, scopeId, capturedScopes:Set }
  const scopeMeta = new Map();  // scopeId -> { scopeId, funcNode, ownsCaptured }

  const scopeParent = new Map();   // scopeId -> parent scopeId (null for top)
  const scopeFuncById = new Map(); // scopeId -> funcNode
  function makeScope(funcNode, parent) {
    const scopeId = nextScope++;
    scopeMeta.set(scopeId, { scopeId, funcNode, ownsCaptured: false });
    scopeParent.set(scopeId, parent ? parent.scopeId : null);
    scopeFuncById.set(scopeId, funcNode);
    return { funcNode, parent, vars: new Map(), scopeId };
  }
  function declare(scope, name, declNode, kind) {
    const b = { id: nextId++, name, declNode, ownerScopeId: scope.scopeId, kind, captured: false };
    scope.vars.set(name, b);
    bindings.set(b.id, b);
    return b;
  }
  function resolve(scope, name) {
    for (let s = scope; s; s = s.parent) if (s.vars.has(name)) return s.vars.get(name);
    return null;
  }
  function collectDecls(node, scope) {
    for (const c of children(node)) {
      if (c.type === 'FunctionDeclaration' && c.id) {
        bindingNodes.add(c.id);
        if (!scope.vars.has(c.id.name)) declare(scope, c.id.name, c, 'var');
      }
      if (isFunc(c)) continue;
      if (c.type === 'VariableDeclaration') {
        for (const d of c.declarations) {
          patternIdentNodes(d.id, bindingNodes);
          const names = []; patternNames(d.id, names);
          for (const nm of names) if (!scope.vars.has(nm)) { const b = declare(scope, nm, d, c.kind); b.declStmt = c; b._forLet = !!c._forLet; }
        }
      }
      collectDecls(c, scope);
    }
  }

  function walk(node, scope, fscope) {
    if (isFunc(node)) {
      const child = makeScope(node, scope);
      funcMeta.set(node, { node, parentFunc: fscope ? fscope.funcNode : null,
        scopeId: child.scopeId, capturedScopes: new Set() });
      const pnames = [];
      for (const p of node.params) { patternNames(p, pnames); patternIdentNodes(p, bindingNodes); }
      for (const nm of pnames) declare(child, nm, node, 'param');
      // Record identifier refs in param default values AND computed destructuring keys — they evaluate
      // before this func's env exists (e.g. `function f(__env, name, {[__env_728.key]: x}) { const
      // __env_728 = __env.e728; ... }` — the computed key reads __env_728 before the body rebind).
      for (const p of node.params) {
        const ids = []; collectParamPreBodyRefs(p, ids);
        for (const id of ids) paramDefaultRefs.set(id, child.scopeId);
      }
      collectDecls(node.body, child);
      if (node.id) bindingNodes.add(node.id);
      for (const c of children(node)) walk(c, child, child);
      return;
    }
    if (node.type === 'Identifier') {
      if (bindingNodes.has(node)) return;
      const b = resolve(scope, node.name);
      if (b) {
        (b.refs || (b.refs = [])).push(node);   // every read/write reference (for uniform rewrite)
        const ownerIsTop = scopeMeta.get(b.ownerScopeId).funcNode == null;
        if (fscope && fscope.scopeId !== b.ownerScopeId && (!ownerIsTop || b._forLet)) {
          b.captured = true;
          scopeMeta.get(b.ownerScopeId).ownsCaptured = true;
          (b._usingScopeIds || (b._usingScopeIds = new Set())).add(fscope.scopeId);
          // every function from fscope UP TO (not including) owner scope threads this env.
          for (let s = fscope; s && s.scopeId !== b.ownerScopeId; s = s.parent) {
            if (s.funcNode) funcMeta.get(s.funcNode).capturedScopes.add(b.ownerScopeId);
          }
        }
      }
      return;
    }
    if (node.type === 'MemberExpression') {
      walk(node.object, scope, fscope);
      if (node.computed) walk(node.property, scope, fscope);
      return;
    }
    if (node.type === 'Property' && !node.computed && node.key && node.key.type === 'Identifier') {
      walk(node.value, scope, fscope); return;
    }
    // Class member NAMES (`toString() {}`, `x = …`) are not references — skip the key (walk it only when
    // computed `[expr]() {}`), so a captured binding sharing a method/field name isn't mis-rewritten.
    if (node.type === 'MethodDefinition' || node.type === 'PropertyDefinition') {
      if (node.computed && node.key) walk(node.key, scope, fscope);
      if (node.value) walk(node.value, scope, fscope);
      return;
    }
    for (const c of children(node)) walk(c, scope, fscope);
  }

  (function tagForInits(node){
    if(!node||typeof node!=='object') return;
    if(node.type==='ForStatement' && node.init && node.init.type==='VariableDeclaration' && node.init.kind!=='var')
      node.init._forLet=true;
    if((node.type==='ForOfStatement'||node.type==='ForInStatement') && node.left && node.left.type==='VariableDeclaration' && node.left.kind!=='var')
      node.left._forLet=true;
    for(const c of children(node)) tagForInits(c);
  })(ast);

  const top = makeScope(null, null);   // scopeId 0
  collectDecls(ast, top);
  for (const c of children(ast)) walk(c, top, null);

  // A Promise executor/withResolvers hands user code a resolver that is a closure_convert BOX (per-promise
  // binding — builtins can't capture, so the runtime builds `{__clo,env,fn}` by hand). Those boxes are only
  // callable through the `__callN` call-site dispatch this pass emits. So even with no *source* closures we
  // must NOT early-return when the program constructs a Promise — otherwise `new Promise(r => r(x))` leaves
  // `r(x)` an un-wrapped direct call on a box object and the promise silently never settles.
  const usesResolvers = /new\s+Promise\b|withResolvers/.test(src);
  // The uncurry-this idiom `Function.prototype.call.bind(method)` (test262 propertyHelper.js, included by
  // most tests) is rewritten to an UNCURRY box + `__callN` dispatch below — same as a Promise resolver, it
  // needs the member-rewrite to run EVEN with no source closures, else the bind stays a no-op and the call
  // routes through the broken indirect FP.call path.
  const usesUncurry = /Function\.prototype\.(call|apply)\.bind/.test(src);
  // An arrow that uses `this` lexically (e.g. `items.map(x => this.go(x))` inside a class method) must be
  // boxed even when it captures NO enclosing locals: a bare Porffor arrow loses its lexical `this`, so
  // `this.go` reads off undefined and throws "undefined is not a function". boxExpr captures `this` into the
  // env (arrowThis), so route these through the same closure path. (var self=this; self.go(x) sidesteps it,
  // but real code — e.g. rollup's moduleLoader — calls `this.method` directly inside such arrows.)
  const needsThisCapture = (m) => m.node.type === 'ArrowFunctionExpression' &&
    (usesThisLexically(m.node) || usesEnvThisLexically(m.node));
  if (!usesResolvers && !usesUncurry && [...funcMeta.values()].every(m => m.capturedScopes.size === 0 && !needsThisCapture(m))) return src;

  // ── Per-iteration `for(let i) ()=>i`: each loop turn needs a FRESH env (JS let-per-iteration). The
  // shared-scope env model would give every closure the loop-final value. Fix: give each captured for-let
  // binding its OWN synthetic scope id (a per-loop env `__env_<L>`), reseeded at the TOP of every loop body
  // iteration from the live loop-control variable — so each closure created that turn captures its own copy.
  const forLetLoops = [];   // { loopNode, kind:'c'|'inof'|'while', envId, names:[..], bodyNames:[..], declStmt, bs, bodyBs }
  {
    // The invariant: every binding lives in ONE env scoped to its lexical block, allocated fresh each time
    // that block is entered. For a loop that means a FRESH per-iteration env for EVERY captured binding that
    // is per-iteration — the loop-control var AND any `const`/`let` declared in the loop body. The old model
    // built a per-loop env only when the CONTROL var was captured, which left body-const captures in the
    // once-allocated function env (every closure sees the last value). Make it binding-driven instead: a loop
    // gets a per-iteration env iff it owns ≥1 captured per-iteration binding (control or body), covering
    // while/do-while (no control var) too.
    const declToBindings = new Map();   // loop-control decl node -> captured control bindings
    for (const b of bindings.values()) {
      if (b.captured && b._forLet && b.declStmt) {
        if (!declToBindings.has(b.declStmt)) declToBindings.set(b.declStmt, []);
        declToBindings.get(b.declStmt).push(b);
      }
    }
    // captured per-iteration body bindings (const/let, NOT the loop control) — assigned to their innermost loop
    const bodyBindings = [...bindings.values()].filter(b =>
      b.captured && !b._forLet && b.declStmt && (b.kind === 'const' || b.kind === 'let'));
    const isLoopType = t => t === 'ForStatement' || t === 'ForInStatement' || t === 'ForOfStatement' ||
      t === 'WhileStatement' || t === 'DoWhileStatement';
    // does `root`'s subtree contain `target`, without crossing a function or a NESTED loop's body (so each
    // body binding is claimed by its innermost enclosing loop)?
    const containsStmt = (root, target) => {
      let found = false;
      (function w(n) {
        if (found || !n || typeof n !== 'object') return;
        if (n === target) { found = true; return; }
        if (isFunc(n) && n !== root) return;
        if (n !== root && isLoopType(n.type)) return;
        for (const k in n) { if (k === 'type' || k[0] === '_') continue; const v = n[k];
          if (Array.isArray(v)) { for (const c of v) if (c && c.type) w(c); } else if (v && v.type) w(v); }
      })(root);
      return found;
    };
    if (declToBindings.size || bodyBindings.length) {
      (function findLoops(node){
        if (!node || typeof node !== 'object') return;
        if (isLoopType(node.type)) {
          const controlDecl = node.type === 'ForStatement' ? node.init
            : ((node.type === 'ForInStatement' || node.type === 'ForOfStatement') ? node.left : null);
          const bs = (controlDecl && declToBindings.get(controlDecl)) || [];
          const body = node.body;
          const bodyBs = body ? bodyBindings.filter(b => containsStmt(body, b.declStmt)) : [];
          if (bs.length || bodyBs.length) {
            const kind = node.type === 'ForStatement' ? 'c'
              : ((node.type === 'ForInStatement' || node.type === 'ForOfStatement') ? 'inof' : 'while');
            forLetLoops.push({ loopNode: node, kind, declStmt: controlDecl, bs, bodyBs });
          }
        }
        for (const k in node){ if(k==='type'||k[0]==='_')continue; const v=node[k];
          if(Array.isArray(v)){ for(const c of v) if(c&&c.type) findLoops(c); }
          else if(v&&v.type) findLoops(v); }
      })(ast);

      // Assign each loop a fresh synthetic env scope id; move its captured bindings onto it and recompute
      // every closure's capturedScopes so the new per-loop scope is threaded.
      // env-id -> the FUNCTION scope that lexically contains the loop. The per-iteration `var __env_L` is
      // SEEDED in that function, so it must NOT also be threaded into it as a captured scope (that would
      // emit a second `const __env_L = __env.eL` prelude in the same function → duplicate declaration). The
      // loop var's ownerScopeId BEFORE we move it to the synthetic env IS that containing function scope.
      const forLetStop = new Map();
      for (const L of forLetLoops) {
        L.envId = nextScope++;
        // the containing function scope (before we move owners to the synthetic env). For a loop with no
        // captured control var (while / control-not-captured) fall back to a body binding's owner.
        const ownerRef = L.bs[0] || (L.bodyBs && L.bodyBs[0]);
        forLetStop.set(L.envId, ownerRef ? ownerRef.ownerScopeId : null);
        scopeMeta.set(L.envId, { scopeId: L.envId, funcNode: null, ownsCaptured: true });
        scopeParent.set(L.envId, null);   // synthetic env scope, not in the function chain
        scopeFuncById.set(L.envId, null);
        L.names = L.bs.map(b => b.name);                 // loop-control names — seeded from the live var
        L.bodyNames = (L.bodyBs || []).map(b => b.name);  // loop-body consts — assigned by decl-rewrite, NOT seeded
        for (const b of L.bs) b.ownerScopeId = L.envId;
        for (const b of (L.bodyBs || [])) b.ownerScopeId = L.envId;
      }
      // recompute capturedScopes for every closure now that some owners moved to per-loop env scopes.
      for (const m of funcMeta.values()) m.capturedScopes = new Set();
      for (const b of bindings.values()) {
        if (!b.captured || !b._usingScopeIds) continue;
        // For a for-let env, stop at the containing function (which seeds the env locally); else at the owner.
        const stop = forLetStop.has(b.ownerScopeId) ? forLetStop.get(b.ownerScopeId) : b.ownerScopeId;
        for (const usid of b._usingScopeIds) {
          // walk function-scope chain from the using scope up to (not incl) the stop, threading the env.
          for (let sid = usid; sid != null && sid !== stop && sid !== b.ownerScopeId; sid = scopeParent.get(sid)) {
            const fn = scopeFuncById.get(sid);
            if (fn) funcMeta.get(fn).capturedScopes.add(b.ownerScopeId);
          }
        }
      }

      // ── CONSTRUCTION-TIME INVARIANT (sound — uses binding PROVENANCE that the output-AST checker lacks) ──
      // INV-LOOP-FRESH, stated where it can be decided correctly: every CAPTURED block-scoped (const/let)
      // binding DECLARED inside a loop body must now be owned by a per-iteration loop env. The output-AST
      // check can't tell a per-iteration declaration from a mutation of an outer `let` (both become
      // `__env_N.x = …`); here we have b.kind + b.declStmt + the loop set, so the check is exact. Gated by
      // CC_INVARIANTS so it's a loud CI/test gate (throws, surfacing the exact binding) without affecting
      // production builds, which trust the binding-driven construction above.
      if (process.env.CC_INVARIANTS) {
        const loopEnvIds = new Set(forLetLoops.map(L => L.envId));
        for (const L of forLetLoops) {
          const body = L.loopNode.body;
          if (!body) continue;
          for (const b of bindings.values()) {
            if (!b.captured || b._forLet || !b.declStmt) continue;
            if ((b.kind !== 'const' && b.kind !== 'let')) continue;
            if (!containsStmt(body, b.declStmt)) continue;
            if (!loopEnvIds.has(b.ownerScopeId)) {
              throw new Error(`cc invariant INV-LOOP-FRESH violated: captured ${b.kind} \`${b.name}\` declared in ` +
                `a loop body is owned by scope ${b.ownerScopeId}, not a per-iteration loop env — every closure ` +
                `made in the loop would share one cell across iterations`);
            }
          }
        }
      }
    }
  }

  const closures = [...funcMeta.values()].filter(m => m.capturedScopes.size > 0 || needsThisCapture(m));
  // No source closures, but a Promise resolver box still needs `__callN` call-site dispatch (see above), so
  // fall through to wrapCalls. The boxing/env machinery below is a no-op when nothing is captured.
  if (closures.length === 0 && !usesResolvers && !usesUncurry) return src;
  const closureSet = new Set(closures.map(m => m.node));

  // CONSTRUCTOR detection. A function used with `new X` or whose binding is `X.prototype`-accessed is a
  // constructor: when boxed it's built via Reflect.construct(box.fn, ...) which supplies a native `this`
  // (the new instance), so its `this` must NOT be rewritten to `__this`. Conversely a capturing function
  // that uses `this` and is NOT a constructor is a METHOD (called as `obj.m()`); its `this` must be
  // threaded as `__this` via the member-call dispatch. Mark constructor function nodes here.
  {
    const ctorNames = new Set();
    (function scan(n){
      if (!n || typeof n !== 'object') return;
      if (n.type === 'NewExpression' && n.callee && n.callee.type === 'Identifier') ctorNames.add(n.callee.name);
      if (n.type === 'MemberExpression' && !n.computed && n.object && n.object.type === 'Identifier' &&
          n.property && n.property.name === 'prototype') ctorNames.add(n.object.name);
      for (const k in n) { if (k === 'type' || k[0] === '_') continue; const v = n[k];
        if (Array.isArray(v)) { for (const c of v) if (c && c.type) scan(c); }
        else if (v && v.type) scan(v); }
    })(ast);
    (function mark(n){
      if (!n || typeof n !== 'object') return;
      // `var X = function(){}` / `function X(){}` where X is constructed/prototyped.
      if (n.type === 'VariableDeclarator' && n.id && n.id.type === 'Identifier' && ctorNames.has(n.id.name) &&
          n.init && isFunc(n.init)) n.init._isConstructor = true;
      if (n.type === 'FunctionDeclaration' && n.id && ctorNames.has(n.id.name)) n._isConstructor = true;
      for (const k in n) { if (k === 'type' || k[0] === '_') continue; const v = n[k];
        if (Array.isArray(v)) { for (const c of v) if (c && c.type) mark(c); }
        else if (v && v.type) mark(v); }
    })(ast);
  }

  // A method is box-eligible (this-wise) unless `this` reaches a BOXED nested arrow — that arrow would need
  // `this` captured through the env, which we don't do. `this` at the method's own level or in a NON-boxed
  // arrow is fine (the non-boxed arrow reads the method's `__this` param lexically); `this` inside a nested
  // regular function is that function's own receiver and is irrelevant to the method.
  function methodThisOk(fnNode) {
    let ok = true;
    (function walk(n, lexical, inBoxedArrow){
      if (!ok || !n || typeof n !== 'object') return;
      if (n.type === 'ThisExpression') { if (lexical && inBoxedArrow) ok = false; return; }
      const each = c => {
        if (!c || !c.type) return;
        if (c.type === 'ArrowFunctionExpression') walk(c, lexical, inBoxedArrow || closureSet.has(c));
        else if (isFunc(c)) walk(c, false, false);   // regular function: own `this`, leaves lexical region
        else walk(c, lexical, inBoxedArrow);
      };
      for (const k in n) { if (k === 'type' || k[0] === '_') continue; const v = n[k];
        if (Array.isArray(v)) v.forEach(each); else each(v); }
    })(fnNode.body, true, false);
    return ok;
  }

  // ── SAFETY BAILOUTS ──
  let bail = false;
  // Native method names that actually have a closure box stored under them as an object property (e.g.
  // marked's `{ replace: <box> }`). ONLY calls to these names get the guarded probe in memberCallDispatch —
  // every other native call stays a plain native call, so the transform doesn't balloon a big bundle.
  const boxedNativeNames = new Set();
  (function scanUnsupported(node, parent){
    if(!node||typeof node!=='object') return;
    if(closureSet.has(node)){
      if(parent && parent.type==='Property' && !parent.computed && parent.key &&
         parent.key.type==='Identifier' && NATIVE_METHODS.has(parent.key.name)) boxedNativeNames.add(parent.key.name);
      // Object-literal property VALUES are boxed in place + dispatched via the inline member-call ternary.
      // Shorthand-method properties (`{ foo() {} }`) and class MethodDefinitions carry `this` — we now BOX
      // them too: a `__this` param + a flat this→__this rewrite, with the receiver threaded at dispatch.
      // That only works when `this` stays at the method's own level; a `this` inside a nested function would
      // need this captured through the env (out of scope) → bail the file for that shape only.
      // Object shorthand methods (`{ foo() {} }`) become a plain `{ foo: <box> }` property. Class
      // MethodDefinitions can't (class syntax forbids a non-function value), so they're TRAMPOLINED: the
      // method body becomes a thin call into a hoisted box. Both need `__this` + flat this-rewrite.
      // Capturing class methods stay NATIVE in the class (super/this/params/getters all work natively); a
      // post-pass redirects their captured-var refs to a `static __cap` field. Only computed method keys
      // bail (can't reliably pair with a sibling static field).
      if(parent && parent.type==='MethodDefinition'){
        if(parent.computed) bail = true;
        else node._nativeClassMethod = true;
      }
      // Object-literal getters/setters can't become a box VALUE (a getter returns the value), so they're
      // trampolined: the box is stashed as a sibling property and the accessor delegates to it via `this`.
      else if(parent && parent.type==='Property' && (parent.kind==='get' || parent.kind==='set')){
        node._isMethod = true; node._isObjAccessor = true;
      }
      // Object shorthand methods become `{ foo: <box> }` with a `__this` param; the dispatch threads the
      // receiver. (this-in-a-boxed-arrow inside is handled by arrow this-capture in boxExpr.)
      else if(parent && parent.type==='Property' && parent.method){
        node._isMethod = true;
      }
      // A box stored under a NATIVE method name on a plain object is now dispatched via the guarded probe in
      // memberCallDispatch (typeof==='object' && !Array.isArray over a side-effect-free receiver), so no
      // whole-file bail is needed here.
    }
    for(const k in node){ if(k==='type'||k[0]==='_') continue; const v=node[k];
      if(Array.isArray(v)){ for(const c of v) if(c&&c.type) scanUnsupported(c,node); }
      else if(v&&v.type) scanUnsupported(v,node); }
  })(ast, null);
  if(bail) return src;

  // For-let header references (init/test/update for C-style, left/right for for-of/in) keep using the REAL
  // loop-control variable — only references inside the loop BODY are rewritten to the per-iteration env, so
  // the loop still advances normally while each turn's closures capture a fresh seeded copy.
  const forLetHeaderRefs = new Set();
  for (const L of forLetLoops) {
    const collect = n => { if(!n||typeof n!=='object')return;
      if(n.type==='Identifier'){forLetHeaderRefs.add(n);return;}
      for(const k in n){ if(k==='type'||k[0]==='_')continue; const v=n[k];
        if(Array.isArray(v)){for(const c of v)if(c&&c.type)collect(c);} else if(v&&v.type)collect(v); } };
    if (L.kind==='c') { collect(L.loopNode.init); collect(L.loopNode.test); collect(L.loopNode.update); }
    else { collect(L.loopNode.left); collect(L.loopNode.right); }
  }

  // A shorthand object property `{ parse }` shares ONE Identifier node for key AND value. If that value is
  // a captured binding it's about to become `__env_N.parse` — which would corrupt the KEY too (→ invalid
  // `{ __env_N.parse }`). Un-shorthand those first: give the key its own Identifier so only the value rewrites.
  const capturedRefNodes = new Set();
  for (const b of bindings.values()) if (b.captured && b.refs) for (const r of b.refs) capturedRefNodes.add(r);
  (function unshorthand(node){
    if (!node || typeof node !== 'object') return;
    if (node.type === 'Property' && node.shorthand && node.value && capturedRefNodes.has(node.value)) {
      node.shorthand = false;
      node.key = { type:'Identifier', name: node.value.name };
    }
    for (const k in node){ if(k==='type'||k[0]==='_')continue; const v=node[k];
      if(Array.isArray(v)){ for(const c of v) if(c&&c.type) unshorthand(c); }
      else if(v&&v.type) unshorthand(v); }
  })(ast);

  // ── Rewrite EVERY reference of a captured binding -> __env_<ownerScopeId>.name ──
  // (owner-scope uses AND nested-closure uses both — the var now lives only in the env record.)
  for (const b of bindings.values()) {
    if (!b.captured || !b.refs) continue;
    for (const node of b.refs) {
      if (forLetHeaderRefs.has(node)) continue;
      // A param-default ref owned by its own function's scope must stay raw (env not built yet).
      if (paramDefaultRefs.get(node) === b.ownerScopeId) continue;
      node.type = 'MemberExpression';
      node.computed = false;
      node.optional = false;
      if (paramDefaultRefs.has(node)) {
        // A captured ENCLOSING-scope var referenced in a PARAMETER DEFAULT: the body-local rebinding
        // `const __env_<sid> = __env.e<sid>` runs AFTER param defaults are evaluated, so `__env_<sid>` is
        // not yet bound there. Reach the env record through the `__env` PARAM instead (param 0, in scope for
        // every later param default) → `__env.e<sid>.name`. Without this the default throws "__env_<sid> is
        // not defined" (e.g. `enabled = isColorSupported` captured from an outer scope in picocolors/rollup).
        node.object = { type: 'MemberExpression', computed: false, optional: false,
          object: { type: 'Identifier', name: '__env' },
          property: { type: 'Identifier', name: 'e' + b.ownerScopeId } };
      } else {
        node.object = { type: 'Identifier', name: '__env_' + b.ownerScopeId };
      }
      node.property = { type: 'Identifier', name: b.name };
      delete node.name;
    }
  }

  // captured names grouped by owner scope
  const capturedByScope = new Map();
  for (const b of bindings.values()) {
    if (!b.captured) continue;
    if (!capturedByScope.has(b.ownerScopeId)) capturedByScope.set(b.ownerScopeId, new Set());
    capturedByScope.get(b.ownerScopeId).add(b.name);
  }

  function isOwnedHere(name, sid){
    for (const b of bindings.values()) if (b.name===name && b.ownerScopeId===sid && b.captured) return b.kind!=='param';
    return false;
  }
  function isParamOwnedHere(name, sid){
    for (const b of bindings.values()) if (b.name===name && b.ownerScopeId===sid && b.captured) return b.kind==='param';
    return false;
  }

  function envPrelude(scopeIds) {
    if (!scopeIds.length) return null;
    return { type:'VariableDeclaration', kind:'const',
      declarations: scopeIds.map(sid => ({
        type:'VariableDeclarator',
        id:{type:'Identifier',name:'__env_'+sid},
        init:{type:'MemberExpression',computed:false,optional:false,
          object:{type:'Identifier',name:'__env'},
          property:{type:'Identifier',name:'e'+sid}} })) };
  }
  function envLiteral(scopeIds) {
    return { type:'ObjectExpression', properties: scopeIds.map(sid => ({
      type:'Property',kind:'init',method:false,shorthand:false,computed:false,
      key:{type:'Identifier',name:'e'+sid},
      value:{type:'Identifier',name:'__env_'+sid} })) };
  }

  function boxExpr(fnNode, m) {
    if (fnNode.body.type !== 'BlockStatement') {
      fnNode.body = { type: 'BlockStatement', body: [{ type: 'ReturnStatement', argument: fnNode.body }] };
      fnNode.expression = false;
    }
    // A capturing non-arrow function that uses `this` and is NOT a constructor is a method (called as
    // `obj.m()`): its `this` is the receiver at call time, threaded via `__this`. (Constructors keep native
    // `this` from Reflect.construct; arrows capture `this` lexically below.)
    const methodThis = fnNode.type !== 'ArrowFunctionExpression' && !fnNode._isConstructor && usesThisLexically(fnNode);
    const isMethod = !!fnNode._isMethod || methodThis;
    // A boxed METHOD gets a leading `__this` param (after __env) and its `this` flat-rewritten to it; the
    // member-call dispatch passes the receiver there. So fn(__env, __this, ...origParams).
    if (isMethod) { rewriteMethodThis(fnNode.body); fnNode.params.unshift({ type:'Identifier', name:'__this' }); }
    // A boxed ARROW that uses `this` lexically (e.g. inside a native class method) loses it once boxed, so
    // CAPTURE `this` into the env: rewrite this→__this, stash the receiver at creation, rebind in the fn.
    // `rawThis` = the arrow still has its own `ThisExpression` (a top-level method arrow). `envThis` = it
    // only references an already-rewritten `__this` (a NESTED continuation whose `this` an outer pass turned
    // into `__this`). Both must capture the receiver; they differ only in what to stash at the creation site:
    // a raw `this` (valid where a top-level arrow is created) vs the enclosing `__this` binding.
    const rawThis = !isMethod && fnNode.type === 'ArrowFunctionExpression' && usesThisLexically(fnNode);
    const arrowThis = rawThis ||
      (!isMethod && fnNode.type === 'ArrowFunctionExpression' && usesEnvThisLexically(fnNode));
    if (rawThis) rewriteMethodThis(fnNode.body);
    fnNode.params.unshift({ type: 'Identifier', name: '__env' });
    const scopeIds = [...m.capturedScopes].sort((a,b)=>a-b);
    const prelude = envPrelude(scopeIds);
    if (prelude) fnNode.body.body.unshift(prelude);
    if (arrowThis) fnNode.body.body.unshift({ type:'VariableDeclaration', kind:'const',
      declarations:[{ type:'VariableDeclarator', id:{type:'Identifier',name:'__this'},
        init:{ type:'MemberExpression',computed:false,optional:false,
          object:{type:'Identifier',name:'__env'}, property:{type:'Identifier',name:'__this'} } }] });
    // Name the boxed FunctionExpression from source context (method/property/var name) so it shows up in
    // Porffor's `-d` name section as `b$<hint>$<N>` instead of an anonymous `fn` — every boxed-method trace
    // then localizes instantly. The name is a function-expression self-binding (body-scoped only) and the
    // `b$` prefix + counter keep it unique and collision-free with user identifiers.
    const hint = (fnNode._nameHint || (fnNode.id && fnNode.id.name) || 'fn').replace(/[^A-Za-z0-9_]/g, '');
    const boxName = 'b$' + hint + '$' + (boxNameCounter++);
    const fnExpr = { type: 'FunctionExpression', id: { type:'Identifier', name: boxName }, params: fnNode.params, body: fnNode.body,
      generator: !!fnNode.generator, async: !!fnNode.async, expression: false };
    const envObj = envLiteral(scopeIds);
    if (arrowThis) envObj.properties.push({ type:'Property',kind:'init',method:false,shorthand:false,computed:false,
      key:{type:'Identifier',name:'__this'},
      // raw-this arrow: capture the creation-site `this`. nested continuation: capture the enclosing `__this`.
      value: rawThis ? {type:'ThisExpression'} : {type:'Identifier',name:'__this'} });
    const props = [
      { type:'Property',kind:'init',method:false,shorthand:false,computed:false,
        key:{type:'Identifier',name:'__clo'}, value:{type:'Literal',value:1} },
      { type:'Property',kind:'init',method:false,shorthand:false,computed:false,
        key:{type:'Identifier',name:'env'}, value: envObj },
      { type:'Property',kind:'init',method:false,shorthand:false,computed:false,
        key:{type:'Identifier',name:'fn'}, value: fnExpr },
    ];
    if (isMethod) props.push(
      { type:'Property',kind:'init',method:false,shorthand:false,computed:false,
        key:{type:'Identifier',name:'__method'}, value:{type:'Literal',value:1} });
    return { type: 'ObjectExpression', properties: props };
  }

  function replaceFuncs(node, parent, key, index, encClass, encObj) {
    if (!node || typeof node !== 'object') return;
    if (node.type === 'ClassBody') encClass = node;
    if (node.type === 'ObjectExpression') encObj = node;
    // A native class method captures but is NOT boxed — leave it in the class and recurse to box any nested
    // closures inside it (the post-pass redirects its captured-var refs to the static __cap field).
    if (isFunc(node) && closureSet.has(node) && !node._nativeClassMethod) {
      const m = funcMeta.get(node);
      // source-context name hint for the boxed fn (-d localization): method/property/var/assigned name.
      if (!node._nameHint) {
        let h = null;
        if (node.id && node.id.name) h = node.id.name;
        else if (parent && (parent.type === 'MethodDefinition' || parent.type === 'Property') && parent.key && parent.key.name) h = parent.key.name;
        else if (parent && parent.type === 'VariableDeclarator' && parent.id && parent.id.type === 'Identifier') h = parent.id.name;
        else if (parent && parent.type === 'AssignmentExpression' && parent.left && parent.left.type === 'MemberExpression' && parent.left.property && parent.left.property.name) h = parent.left.property.name;
        if (h) node._nameHint = h;
      }

      // OBJECT-LITERAL getter/setter → trampoline: stash the box as a sibling property `__acc_K` and make
      // the accessor delegate to it via `this` (the object). No enclosing-local capture.
      if (node._isObjAccessor && parent && parent.type === 'Property' && encObj) {
        const isSetter = parent.kind === 'set';
        const paramNames = node.params.filter(p => p.type === 'Identifier').map(p => p.name);
        const box = boxExpr(node, m);
        replaceFuncs(box.properties[2].value.body, box.properties[2], 'value', null, encClass, encObj);
        const boxName = '__acc_' + (nextId++);
        encObj.properties.push({ type:'Property',kind:'init',method:false,shorthand:false,computed:false,
          key:{type:'Identifier',name:boxName}, value: box });
        const ref = (prop) => ({ type:'MemberExpression',computed:false,optional:false,
          object:{ type:'MemberExpression',computed:false,optional:false,
            object:{type:'ThisExpression'}, property:{type:'Identifier',name:boxName} },
          property:{type:'Identifier',name:prop} });
        const call = { type:'CallExpression', optional:false, _skipWrap:true, callee: ref('fn'),
          arguments:[ ref('env'), {type:'ThisExpression'}, ...paramNames.map(n=>({type:'Identifier',name:n})) ] };
        parent.value = { type:'FunctionExpression', id:null,
          params: paramNames.map(n=>({type:'Identifier',name:n})),
          body:{ type:'BlockStatement', body:[ isSetter
            ? { type:'ExpressionStatement', expression: call }
            : { type:'ReturnStatement', argument: call } ] },
          generator:false, async:false, expression:false };
        return;
      }

      if (node.type === 'FunctionDeclaration') {
        const box = boxExpr(node, m);
        const fname = node.id ? node.id.name : ('__anon' + (nextId++));
        const decl = { type:'VariableDeclaration', kind:'var',
          declarations:[{ type:'VariableDeclarator', id:{type:'Identifier',name:fname}, init:box }] };
        decl._wasFuncDecl = fname;
        if (Array.isArray(parent[key])) parent[key][index] = decl;
        else parent[key] = decl;
        replaceFuncs(box.properties[2].value.body, box.properties[2], 'value', null);
        return;
      } else {
        const box = boxExpr(node, m);
        // A shorthand method `{ foo() {} }` becomes a plain data property `{ foo: <box> }`.
        if (parent && parent.type === 'Property' && parent.method) { parent.method = false; parent.shorthand = false; }
        if (index != null && Array.isArray(parent[key])) parent[key][index] = box;
        else parent[key] = box;
        replaceFuncs(box.properties[2].value.body, box.properties[2], 'value', null);
        return;
      }
    }
    for (const k in node) {
      if (k === 'type' || k[0] === '_') continue;
      const v = node[k];
      if (Array.isArray(v)) { for (let i = 0; i < v.length; i++) if (v[i] && v[i].type) replaceFuncs(v[i], node, k, i, encClass, encObj); }
      else if (v && v.type) replaceFuncs(v, node, k, null, encClass, encObj);
    }
  }
  replaceFuncs(ast, null, null, null, null, null);

  function bodyArrayOf(funcNode) {
    if (funcNode == null) return ast.body;
    let b = funcNode.body;
    if (b && b.type !== 'BlockStatement') {
      // arrow with expression body that must host an env -> convert to block `{ return <expr>; }`
      funcNode.body = { type:'BlockStatement', body:[{ type:'ReturnStatement', argument: b }] };
      funcNode.expression = false;
      b = funcNode.body;
    }
    if (b && b.type === 'BlockStatement') return b.body;
    return null;
  }
  const scopeFunc = new Map();
  for (const [sid, sm] of scopeMeta) scopeFunc.set(sid, sm.funcNode);

  const forLetEnvIds = new Set(forLetLoops.map(L => L.envId));

  // Insert per-scope env allocation + captured-slot init at the top of each owning scope body.
  for (const [sid, names] of capturedByScope) {
    if (forLetEnvIds.has(sid)) continue;   // per-loop envs are seeded inside the loop body (below)
    const funcNode = scopeFunc.get(sid);
    const arr = bodyArrayOf(funcNode);
    if (arr == null) { bail = true; break; }

    // 1. Rewrite declarations of captured locals so the name lives only in env. Recurses into nested
    // BLOCKS (if/else, loops, try, switch, bare `{}`) — a captured `const`/`let` declared in a block was
    // otherwise left as a block-local decl while its refs became `__env_N.name` (never assigned → undefined,
    // e.g. rollup's getAstBuffer `const textDecoder` in an else-branch captured by `convertString`). Stops at
    // function boundaries (nested funcs are a separate scope handled by their own sid iteration).
    const childContainers = st => {
      const out = [];
      if (!st || typeof st !== 'object' || isFunc(st)) return out;
      const push = b => { if (b && b.type === 'BlockStatement') out.push(b.body); };
      switch (st.type) {
        case 'BlockStatement': out.push(st.body); break;
        case 'IfStatement': push(st.consequent); push(st.alternate); break;
        case 'ForStatement': case 'ForInStatement': case 'ForOfStatement':
        case 'WhileStatement': case 'DoWhileStatement': case 'LabeledStatement': push(st.body); break;
        case 'TryStatement':
          push(st.block);
          if (st.handler && st.handler.body) out.push(st.handler.body.body);
          push(st.finalizer); break;
        case 'SwitchStatement': for (const c of st.cases) out.push(c.consequent); break;
      }
      return out;
    };
    (function rewriteDecls(container){
      for (let i=0;i<container.length;i++){
        const st = container[i];
        if (!st) continue;
        for (const childArr of childContainers(st)) rewriteDecls(childArr);
        if (st.type==='VariableDeclaration' && !st._envInit && st._wasFuncDecl) {
          const nm = st._wasFuncDecl;
          if (names.has(nm) && isOwnedHere(nm, sid)) {
            // A CAPTURED boxed function declaration: its name lives in env, so `var z = <box>` becomes
            // `__env_sid.z = <box>`. Keep the _wasFuncDecl marker so the hoisting pass moves it to scope top
            // (a function declaration hoists; a use before the textual decl — bignumber's `__env.z.prototype=`
            // before `function z(){}` — must see the bound function, not undefined).
            container[i] = { type:'ExpressionStatement', _wasFuncDecl: nm, expression:{
              type:'AssignmentExpression', operator:'=',
              left:{type:'MemberExpression',computed:false,optional:false,
                object:{type:'Identifier',name:'__env_'+sid},
                property:{type:'Identifier',name:nm}},
              right: st.declarations[0].init }};
          }
        } else if (st.type==='VariableDeclaration' && !st._envInit) {
          const keepers=[]; const assigns=[];
          for (const d of st.declarations) {
            if (d.id && d.id.type==='Identifier' && names.has(d.id.name) && isOwnedHere(d.id.name, sid)) {
              if (d.init) {
                assigns.push({ type:'ExpressionStatement', expression:{
                  type:'AssignmentExpression', operator:'=',
                  left:{type:'MemberExpression',computed:false,optional:false,
                    object:{type:'Identifier',name:'__env_'+sid},
                    property:{type:'Identifier',name:d.id.name}},
                  right:d.init }});
              }
            } else {
              keepers.push(d);
            }
          }
          if (assigns.length) {
            const repl=[];
            if (keepers.length) repl.push({ type:'VariableDeclaration', kind:st.kind, declarations:keepers });
            repl.push(...assigns);
            container.splice(i,1,...repl);
            i += repl.length-1;
          }
        }
      }
    })(arr);
    if (bail) break;

    // 2. Seed captured PARAMS into env.
    const paramAssigns = [];
    if (funcNode) {
      const pnames=[]; for(const p of funcNode.params) patternNames(p,pnames);
      for (const pn of pnames) if (names.has(pn) && isParamOwnedHere(pn, sid)) {
        paramAssigns.push({ type:'ExpressionStatement', expression:{
          type:'AssignmentExpression', operator:'=',
          left:{type:'MemberExpression',computed:false,optional:false,
            object:{type:'Identifier',name:'__env_'+sid},
            property:{type:'Identifier',name:pn}},
          right:{type:'Identifier',name:pn} }});
      }
    }

    // 2b. Seed captured FUNCTION DECLARATIONS that were NOT boxed (a fn that is captured but doesn't itself
    // capture stays a hoisted `function name(){}` declaration). Its references were rewritten to
    // `__env_sid.name`, so the slot must be filled — `__env_sid.name = name` (hoisting makes `name` available).
    const funcDeclAssigns = [];
    for (const st of arr) {
      if (st && st.type === 'FunctionDeclaration' && st.id && names.has(st.id.name) && isOwnedHere(st.id.name, sid)) {
        funcDeclAssigns.push({ type:'ExpressionStatement', expression:{
          type:'AssignmentExpression', operator:'=',
          left:{type:'MemberExpression',computed:false,optional:false,
            object:{type:'Identifier',name:'__env_'+sid},
            property:{type:'Identifier',name:st.id.name}},
          right:{type:'Identifier',name:st.id.name} }});
      }
    }

    // 3. Prepend `const __env_sid = {};` then param + captured-function-declaration seeds.
    const envDecl = { type:'VariableDeclaration', kind:'const', _envInit:true,
      declarations:[{ type:'VariableDeclarator', id:{type:'Identifier',name:'__env_'+sid},
        init:{type:'ObjectExpression',properties:[]} }] };
    arr.unshift(envDecl, ...paramAssigns, ...funcDeclAssigns);
  }
  if (bail) return src;

  // ── Function-declaration hoisting for BOXED inner functions ──
  // A `function z(){}` that captured enclosing scope was rewritten by replaceFuncs into `var z = <box>` left
  // at its ORIGINAL position. But a function declaration HOISTS to the top of its scope, so a use BEFORE the
  // textual declaration must see the bound function — a plain `var` leaves it `undefined` until the line runs.
  // (bignumber's clone(): `var ...,P=z.prototype={constructor:z,...}; ...; function z(){...}` reads z 300
  // chars before its decl.) Move each `_wasFuncDecl` var to just after the leading env preludes — its box only
  // references the `__env_N` OBJECT those create (the captured slots are read lazily when z is called), so this
  // is safe and restores exactly the hoisting the plain (unboxed) path keeps.
  const hoistBoxedFuncDecls = (arr) => {
    if (!Array.isArray(arr)) return;
    const hoisted = [];
    for (let i = 0; i < arr.length; i++) {
      const st = arr[i];
      // Both forms of a boxed function declaration: `var z = <box>` (non-captured name) and
      // `__env_sid.z = <box>` (captured name, an ExpressionStatement marked _wasFuncDecl above).
      if (st && !st._envInit && st._wasFuncDecl &&
          (st.type === 'VariableDeclaration' || st.type === 'ExpressionStatement')) {
        hoisted.push(st);
        arr.splice(i, 1);
        i--;
      }
    }
    if (!hoisted.length) return;
    // Insert AFTER every leading env prelude, because the hoisted box references the __env_N objects those
    // bind. The leading region (boxed fn) is: `const __env_N = {}` (owning, _envInit), param/funcdecl seeds
    // `__env_N.x = <identifier>`, and `const __env_N = __env.eN` rebindings — in some order. A box must follow
    // ALL of them (esp. the rebindings, which may sit AFTER the param seeds → the TDZ this skip prevents).
    const startsEnv = (id) => id && id.type === 'Identifier' && id.name.startsWith('__env_');
    const isEnvPrelude = (st) => {
      if (!st) return false;
      if (st._envInit) return true;
      // const __env_N = ... (owning {} or rebinding __env.eN)
      if (st.type === 'VariableDeclaration' && st.declarations.length > 0 &&
          st.declarations.every((d) => startsEnv(d.id))) return true;
      // __env_N.x = <Identifier> — a param/captured-funcdecl seed (bare-name RHS, no env dependency); a
      // hoisted box assignment (object/box RHS, or _wasFuncDecl) is NOT this, so it won't be skipped over.
      if (st.type === 'ExpressionStatement' && !st._wasFuncDecl && st.expression &&
          st.expression.type === 'AssignmentExpression' &&
          st.expression.left && st.expression.left.type === 'MemberExpression' &&
          startsEnv(st.expression.left.object) &&
          st.expression.right && st.expression.right.type === 'Identifier') return true;
      return false;
    };
    let at = 0;
    while (at < arr.length && isEnvPrelude(arr[at])) at++;
    arr.splice(at, 0, ...hoisted);
  };
  for (const sm of scopeMeta.values()) {
    const b = bodyArrayOf(sm.funcNode);
    if (b) hoistBoxedFuncDecls(b);
  }

  // ── Per-iteration for-let env seeding ──
  // At the TOP of every loop body: `var __env_L = { i: i, ... }` (fresh object each turn, seeded from the
  // real loop-control var). For C-style `for`, also write back `i = __env_L.i` at body end so a body that
  // mutates the loop var still advances the header's real var. Body refs already point at `__env_L.i`.
  for (const L of forLetLoops) {
    let body = L.loopNode.body;
    if (!body || body.type !== 'BlockStatement') {
      body = { type:'BlockStatement', body: body ? [body] : [] };
      L.loopNode.body = body;
    }
    const seed = { type:'VariableDeclaration', kind:'var', _envInit:true,
      declarations:[{ type:'VariableDeclarator', id:{type:'Identifier',name:'__env_'+L.envId},
        init:{ type:'ObjectExpression', properties: L.names.map(nm => ({
          type:'Property',kind:'init',method:false,shorthand:false,computed:false,
          key:{type:'Identifier',name:nm}, value:{type:'Identifier',name:nm} })) } }] };
    body.body.unshift(seed);

    // Loop-BODY captured consts live on this same per-iteration env but aren't seeded from a same-named var
    // (they don't exist at body top). Their REFS were already rewritten to `__env_L.name` by the main capture
    // pass; rewrite their DECLARATION `const name = init` → `__env_L.name = init` (the main rewriteDecls skips
    // per-loop envs). Recurse through plain blocks/if/try/switch but NOT nested functions or nested loops
    // (separate scopes), matching the `containsStmt` membership used to collect them.
    if (L.bodyNames && L.bodyNames.length) {
      const bodySet = new Set(L.bodyNames);
      const rewriteBodyConsts = (arr) => {
        for (let i = 0; i < arr.length; i++) {
          const st = arr[i];
          if (!st || typeof st !== 'object') continue;
          if (st._envInit) continue;
          // recurse into non-function, non-loop child statement lists
          if (!isFunc(st) && st.type !== 'ForStatement' && st.type !== 'ForInStatement' &&
              st.type !== 'ForOfStatement' && st.type !== 'WhileStatement' && st.type !== 'DoWhileStatement') {
            const kids = [];
            const pushBlk = b => { if (b && b.type === 'BlockStatement') kids.push(b.body); };
            switch (st.type) {
              case 'BlockStatement': kids.push(st.body); break;
              case 'IfStatement': pushBlk(st.consequent); pushBlk(st.alternate); break;
              case 'LabeledStatement': pushBlk(st.body); break;
              case 'TryStatement': pushBlk(st.block); if (st.handler && st.handler.body) kids.push(st.handler.body.body); pushBlk(st.finalizer); break;
              case 'SwitchStatement': for (const c of st.cases) kids.push(c.consequent); break;
            }
            for (const kk of kids) rewriteBodyConsts(kk);
          }
          if (st.type === 'VariableDeclaration' && !st._envInit &&
              st.declarations.some(d => d.id && d.id.type === 'Identifier' && bodySet.has(d.id.name))) {
            const repl = [];
            for (const d of st.declarations) {
              if (d.id && d.id.type === 'Identifier' && bodySet.has(d.id.name) && d.init) {
                repl.push({ type:'ExpressionStatement', expression:{ type:'AssignmentExpression', operator:'=',
                  left:{ type:'MemberExpression',computed:false,optional:false,
                    object:{type:'Identifier',name:'__env_'+L.envId}, property:{type:'Identifier',name:d.id.name} },
                  right: d.init } });
              } else {
                repl.push({ type:'VariableDeclaration', kind: st.kind, declarations:[d] });
              }
            }
            arr.splice(i, 1, ...repl); i += repl.length - 1;
          }
        }
      };
      rewriteBodyConsts(body.body);
    }

    if (L.kind === 'c') {
      for (const nm of L.names) {
        body.body.push({ type:'ExpressionStatement', _envInit:true, expression:{
          type:'AssignmentExpression', operator:'=',
          left:{type:'Identifier',name:nm},
          right:{type:'MemberExpression',computed:false,optional:false,
            object:{type:'Identifier',name:'__env_'+L.envId},
            property:{type:'Identifier',name:nm}} }});
      }
    }
  }

  // ── lower `<arr>.<hof>(<box>[, init])` to a helper call that dispatches the box correctly. ──
  // Works in BOTH statement and expression position (map/filter/reduce return a value). Porffor lacks
  // working closure args to native HOFs, so when the callback is a boxed capturing closure we route the
  // whole call to `__hof_<name>(arr, box[, init])`, which iterates with static arity via box.fn(box.env,…).
  const isBoxNode = n => n && n.type === 'ObjectExpression' && n.properties[0] &&
    n.properties[0].key && n.properties[0].key.name === '__clo';
  const HOFS = new Set(['map','filter','forEach','reduce','find','findIndex','some','every','sort']);
  const usedHofs = new Set();
  function lowerHofCall(node){
    if (!node || node.type !== 'CallExpression') return node;
    const c = node.callee;
    if (!c || c.type !== 'MemberExpression' || c.computed || !c.property) return node;
    const name = c.property.name;
    if (!HOFS.has(name)) return node;
    if (node.arguments.length < 1 || !isBoxNode(node.arguments[0])) return node;
    const box = node.arguments[0];
    const arr = c.object;
    usedHofs.add(name);
    const args = [arr, box];
    let helperName = '__hof_' + name;
    if (name === 'reduce') {
      if (node.arguments.length >= 2) args.push(node.arguments[1]);
      else { helperName = '__hof_reduce1'; usedHofs.add('reduce1'); }   // no-init: seed acc from arr[0]
    }
    return { type:'CallExpression', optional:false, _skipWrap:true,
      callee:{ type:'Identifier', name: helperName }, arguments: args };
  }
  (function lowerHof(node){
    if (!node || typeof node !== 'object') return;
    for (const k in node) {
      if (k === 'type' || k[0] === '_') continue;
      let v = node[k];
      if (Array.isArray(v)) {
        for (let i=0;i<v.length;i++){ if (v[i] && v[i].type) { lowerHof(v[i]); v[i] = lowerHofCall(v[i]); } }
      } else if (v && v.type) { lowerHof(v); node[k] = lowerHofCall(v); }
    }
  })(ast);

  // ── route call sites through fixed-arity dispatch helpers. ──
  const usedArities = new Set();
  let needCallS = false;
  let needCnew = false, needCproto = false, needDefprop = false, needCinst = false;
  // a callee `__env_N.name` is a closure value stored in an env record — it must be dispatched, not
  // treated as a native method call. Any OTHER member callee (obj.method) we leave alone.
  const isEnvMember = c => c && c.type==='MemberExpression' && !c.computed && c.object &&
    c.object.type==='Identifier' && /^__env_/.test(c.object.name);
  function isGlobalMemberCallee(callee) { return callee.type === 'MemberExpression' && !isEnvMember(callee); }

  // Dispatch a COMPUTED-element call `obj[key](args)`: evaluate obj→__mo, key→__mk, element→__mv once;
  // if __mv is a box dispatch through `__mv.fn` (env first, +__mo as `__this` when it's a __method), else
  // call `__mo[__mk](args)` natively (preserves `this` = obj). Skips optional/spread (left native).
  function computedMemberCallDispatch(node) {
    const callee = node.callee;
    if (node.optional || callee.optional) return null;
    if (node.arguments.some(a => a.type === 'SpreadElement')) return null;
    const a = '__mr' + (nextMtmp++), b = '__mr' + (nextMtmp++), v = '__mr' + (nextMtmp++);
    const id = n => ({ type:'Identifier', name:n });
    const elemNative = { type:'MemberExpression', computed:true, optional:false, object:id(a), property:id(b) };
    const assignA = { type:'AssignmentExpression', operator:'=', left:id(a), right: callee.object };
    const assignB = { type:'AssignmentExpression', operator:'=', left:id(b), right: callee.property };
    const seededElem = { type:'MemberExpression', computed:true, optional:false, object: assignA, property: assignB };
    const assignV = { type:'AssignmentExpression', operator:'=', left:id(v), right: seededElem };
    const vDot = k => ({ type:'MemberExpression', computed:false, optional:false, object:id(v), property:id(k) });
    const test = { type:'LogicalExpression', operator:'&&', left: assignV, right: vDot('__clo') };
    const methodCall = { type:'CallExpression', optional:false, _skipWrap:true, callee: vDot('fn'),
      arguments:[ vDot('env'), id(a), ...node.arguments ] };
    const plainCall = { type:'CallExpression', optional:false, _skipWrap:true, callee: vDot('fn'),
      arguments:[ vDot('env'), ...node.arguments ] };
    const boxCall = { type:'ConditionalExpression', test: vDot('__method'), consequent: methodCall, alternate: plainCall };
    const nativeCall = { type:'CallExpression', optional:false, _skipWrap:true, callee: elemNative, arguments: node.arguments };
    return { type:'ConditionalExpression', test, consequent: boxCall, alternate: nativeCall };
  }

  // ── Member-call box/native dispatch ──
  // A non-computed member call `recv.name(args)` may hit a BOX stored as an object-literal property
  // (`{ red: <box> }`) OR an ordinary/native method (`arr.push`, `s.indexOf`, `Math.max`). Porffor cannot
  // do a computed/dynamic method call (`recv[name](...)` yields a non-function), so a generic runtime
  // helper is impossible. Instead we emit an INLINE ternary that keeps STATIC member access on both
  // branches and binds the receiver to a hoisted temp (evaluated once):
  //   ((__mrK = recv).name && __mrK.name.__clo)
  //     ? __mrK.name.fn(__mrK.name.env, ...args)   // box dispatch
  //     : __mrK.name(...args)                       // native method, `this` = __mrK
  // Native methods keep correct `this` because the call stays a static member on the temp. Names on the
  // module-level NATIVE_METHODS denylist are NEVER probed (the value-read corrupts primitive-string calls);
  // they stay direct native calls.
  let nextMtmp = 0;
  function memberCallDispatch(node) {
    const callee = node.callee;
    // skip optional-chaining, spreads, super, computed (already excluded by caller for computed).
    if (node.optional || callee.optional) return null;
    if (callee.object && callee.object.type === 'Super') return null;

    // `fn.call(thisArg, ...args)` / `fn.apply(thisArg, argsArr)` where `fn` may be a boxed closure: a box
    // isn't natively callable, so route through `box.fn` (threading the env). Native functions (`__clo`
    // undefined) keep their native .call/.apply. Receiver evaluated once into a temp.
    if ((callee.property.name === 'call' || callee.property.name === 'apply') && !rootedAtGlobal(callee.object)) {
      const isApply = callee.property.name === 'apply';
      const ct = '__mr' + (nextMtmp++);
      const ctId = () => ({ type:'Identifier', name: ct });
      const ctDot = (k) => ({ type:'MemberExpression', computed:false, optional:false, object: ctId(), property:{ type:'Identifier', name: k } });
      const assign = { type:'AssignmentExpression', operator:'=', left: ctId(), right: callee.object };
      const test = { type:'LogicalExpression', operator:'&&', left: assign,
        right:{ type:'MemberExpression', computed:false, object: ctId(), property:{ type:'Identifier', name:'__clo' } } };
      const thisArg = node.arguments[0];
      const restArgs = node.arguments.slice(1); // drop thisArg (plain boxed closures don't use `this`)
      // A METHOD box (tagged `__method`) takes the receiver as `__this` after env, so `.call(thisArg, …)`
      // / `.apply(thisArg, […])` MUST thread thisArg into that slot — dropping it (the plain-box path) loses
      // `this` and shifts every real arg by one (acorn's `update.call(this, prevType)` broke here: the parser
      // method box got `prevType` as `__this` and lost its real arg). Branch on the tag at runtime.
      let methodBoxCall, plainBoxCall;
      if (isApply) {
        const argsArr = node.arguments[1] || { type:'ArrayExpression', elements: [] };
        const argsArrSafe = { type:'LogicalExpression', operator:'||', left: argsArr, right:{ type:'ArrayExpression', elements: [] } };
        const methodArr = { type:'CallExpression', optional:false, _skipWrap:true,
          callee:{ type:'MemberExpression', computed:false, object:{ type:'ArrayExpression', elements:[ ctDot('env'), thisArg ] }, property:{ type:'Identifier', name:'concat' } },
          arguments:[ argsArrSafe ] };
        const plainArr = { type:'CallExpression', optional:false, _skipWrap:true,
          callee:{ type:'MemberExpression', computed:false, object:{ type:'ArrayExpression', elements:[ ctDot('env') ] }, property:{ type:'Identifier', name:'concat' } },
          arguments:[ argsArrSafe ] };
        const applyCallee = { type:'MemberExpression', computed:false, object: ctDot('fn'), property:{ type:'Identifier', name:'apply' } };
        methodBoxCall = { type:'CallExpression', optional:false, _skipWrap:true, callee: applyCallee,
          arguments:[ { type:'Identifier', name:'undefined' }, methodArr ] };
        plainBoxCall = { type:'CallExpression', optional:false, _skipWrap:true,
          callee:{ type:'MemberExpression', computed:false, object: ctDot('fn'), property:{ type:'Identifier', name:'apply' } },
          arguments:[ { type:'Identifier', name:'undefined' }, plainArr ] };
      } else {
        methodBoxCall = { type:'CallExpression', optional:false, _skipWrap:true,
          callee: ctDot('fn'), arguments:[ ctDot('env'), thisArg, ...restArgs ] };
        plainBoxCall = { type:'CallExpression', optional:false, _skipWrap:true,
          callee: ctDot('fn'), arguments:[ ctDot('env'), ...restArgs ] };
      }
      const boxCall = { type:'ConditionalExpression',
        test: ctDot('__method'), consequent: methodBoxCall, alternate: plainBoxCall };
      const nativeCall = { type:'CallExpression', optional:false, _skipWrap:true,
        callee:{ type:'MemberExpression', computed:false, object: ctId(), property:{ type:'Identifier', name: callee.property.name } },
        arguments: node.arguments };
      return { type:'ConditionalExpression', test, consequent: boxCall, alternate: nativeCall };
    }

    // uncurry-this idiom: `Function.prototype.call.bind(METHOD)`. Called as `u(recv, ...args)` it means
    // `METHOD.call(recv, ...args)` = `METHOD.apply(recv, [args])`. Routing it through the generic bound box
    // (`FP.call.apply(METHOD, …)`) hits a deep indirect-builtin arg-packing bug (FP.call is a method builtin
    // whose own spread args mis-pack when invoked indirectly). Instead emit an UNCURRY box
    // {__clo,__uncurry,fn:METHOD}; the call-site dispatch invokes it directly as `METHOD.apply(firstArg,
    // [restArgs])` — the proven-working path. Unblocks test262 propertyHelper.js (included by most tests).
    const isFnProtoCall = n => n && n.type === 'MemberExpression' && !n.computed && n.property && n.property.name === 'call'
      && n.object && n.object.type === 'MemberExpression' && !n.object.computed && n.object.property && n.object.property.name === 'prototype'
      && n.object.object && n.object.object.type === 'Identifier' && n.object.object.name === 'Function';
    if (callee.property.name === 'bind' && node.arguments.length === 1 && isFnProtoCall(callee.object)) {
      const lit = (nm, v) => ({ type:'Property', kind:'init', method:false, shorthand:false, computed:false,
        key:{ type:'Identifier', name:nm }, value:{ type:'Literal', value:v } });
      const propV = (nm, val) => ({ type:'Property', kind:'init', method:false, shorthand:false, computed:false,
        key:{ type:'Identifier', name:nm }, value: val });
      return { type:'ObjectExpression', _skipWrap:true, properties:[
        lit('__clo', 1), lit('__uncurry', 1), propV('fn', node.arguments[0]) ] };
    }

    // `fn.bind(thisArg)` where `fn` may be a boxed closure: boxes are arrows/capturing fns that ignore a
    // dynamic `this` (consistent with the .call/.apply handling above, which drops thisArg), so binding a
    // box to a thisArg with NO curried args is identity — the box is already callable and routes through
    // __callN later. Native functions keep their real .bind. We only rewrite the no-curry form (`bind(t)`
    // or `bind()`); a box bound WITH curried args is rarer and left to the native path. Receiver evaluated
    // once into a temp so an arrow-method receiver (e.g. `this.fe.emitFile`) isn't re-read.
    if (callee.property.name === 'bind' && node.arguments.length <= 1) {
      const ct = '__mr' + (nextMtmp++);
      const ctId = () => ({ type:'Identifier', name: ct });
      const assign = { type:'AssignmentExpression', operator:'=', left: ctId(), right: callee.object };
      const test = { type:'LogicalExpression', operator:'&&', left: assign,
        right:{ type:'MemberExpression', computed:false, object: ctId(), property:{ type:'Identifier', name:'__clo' } } };
      const nativeCall = { type:'CallExpression', optional:false, _skipWrap:true,
        callee:{ type:'MemberExpression', computed:false, object: ctId(), property:{ type:'Identifier', name:'bind' } },
        arguments: node.arguments };
      // box → the box itself (identity, boxes ignore dynamic `this`). Native fn bound to a thisArg → a
      // BOUND BOX `{__clo,__bound,bthis,fn}`: Porffor's native Function.prototype.bind is a no-op stub
      // (drops thisArg), so we synthesize a box that the call-site dispatch re-invokes as `fn.apply(bthis,
      // args)`, preserving the bound receiver. Only the no-curry `bind(t)` form (one thisArg, no extra
      // bound args) is rewritten; `bind()` / curried binds keep the native (identity) path.
      let nativeAlt = nativeCall;
      if (node.arguments.length === 1) {
        const lit = (n, v) => ({ type:'Property', kind:'init', method:false, shorthand:false, computed:false,
          key:{ type:'Identifier', name:n }, value:{ type:'Literal', value:v } });
        const propV = (n, val) => ({ type:'Property', kind:'init', method:false, shorthand:false, computed:false,
          key:{ type:'Identifier', name:n }, value: val });
        nativeAlt = { type:'ObjectExpression', _skipWrap:true, properties:[
          lit('__clo', 1), lit('__bound', 1), propV('bthis', node.arguments[0]), propV('fn', ctId()) ] };
      }
      return { type:'ConditionalExpression', test, consequent: ctId(), alternate: nativeAlt };
    }

    // Native built-in method name: string/array receivers are probe-UNSAFE (reading recv.name as a value
    // corrupts the next native call) but a user closure box can still live under such a name on a PLAIN
    // OBJECT (e.g. marked's `{ replace: <box> }`). Emit a guarded probe that re-uses the ORIGINAL receiver
    // in every branch (no temp alias — aliasing drops Porffor's string/array method type-direction), so the
    // native path stays byte-identical. Only for a side-effect-free receiver (safe to evaluate repeatedly);
    // anything else keeps the plain native call.
    if (NATIVE_METHODS.has(callee.property.name)) {
      // Only names that actually hold a box somewhere in this file need the guarded probe; everything else
      // stays a plain native call (no expansion → big bundles still compile within the lane's stack).
      if (!boxedNativeNames.has(callee.property.name)) return null;
      if (rootedAtGlobal(callee.object)) return null;
      if (node.arguments.some(a => a.type === 'SpreadElement')) return null;
      // Receiver evaluated once into a temp (handles call receivers like marked's `edit(rx).replace(a,b)`).
      // The typeof guard short-circuits BEFORE any member read on string/array receivers (probe-unsafe), so
      // they fall through to a plain native call; only a plain object holding a box is dispatched.
      const nt = '__mr' + (nextMtmp++);
      const pn = callee.property.name;
      const ntId = () => ({ type:'Identifier', name: nt });
      const nMember = () => ({ type:'MemberExpression', computed:false, optional:false, object: ntId(), property:{ type:'Identifier', name: pn } });
      const nDot = (k) => ({ type:'MemberExpression', computed:false, optional:false, object: nMember(), property:{ type:'Identifier', name: k } });
      const and = (a, b) => ({ type:'LogicalExpression', operator:'&&', left:a, right:b });
      const assignTmp = { type:'AssignmentExpression', operator:'=', left: ntId(), right: callee.object };
      const typeofObj = { type:'BinaryExpression', operator:'===',
        left:{ type:'UnaryExpression', operator:'typeof', prefix:true, argument: assignTmp }, right:{ type:'Literal', value:'object' } };
      const notNull = { type:'BinaryExpression', operator:'!==', left: ntId(), right:{ type:'Literal', value:null } };
      const notArr = { type:'UnaryExpression', operator:'!', prefix:true, argument:{ type:'CallExpression', optional:false,
        callee:{ type:'MemberExpression', computed:false, object:{ type:'Identifier', name:'Array' }, property:{ type:'Identifier', name:'isArray' } }, arguments:[ ntId() ] } };
      const test = and(and(and(and(typeofObj, notNull), notArr), nMember()), nDot('__clo'));
      const methodCall = { type:'CallExpression', optional:false, _skipWrap:true, callee: nDot('fn'), arguments:[ nDot('env'), ntId(), ...node.arguments ] };
      const plainBoxCall = { type:'CallExpression', optional:false, _skipWrap:true, callee: nDot('fn'), arguments:[ nDot('env'), ...node.arguments ] };
      const boxCall = { type:'ConditionalExpression', test: nDot('__method'), consequent: methodCall, alternate: plainBoxCall };
      const nativeCall = { type:'CallExpression', optional:false, _skipWrap:true, callee: nMember(), arguments: node.arguments };
      return { type:'ConditionalExpression', test, consequent: boxCall, alternate: nativeCall };
    }
    // Known special globals (console/Math/JSON/Object/…) are intrinsics in Porffor codegen: their methods
    // ONLY resolve as the literal static `Global.method` — aliasing the receiver to a temp breaks them.
    // `rootedAtGlobal` also covers member CHAINS into an intrinsic namespace (`Porffor.wasm.i32.load8_u`),
    // whose receiver `Porffor.wasm.i32` is not a bare Identifier but must equally never be aliased.
    if (rootedAtGlobal(callee.object)) return null;
    if (node.arguments.some(a => a.type === 'SpreadElement')) return null;
    const tmp = '__mr' + (nextMtmp++);
    const propName = callee.property.name;
    const tmpId = () => ({ type:'Identifier', name: tmp });
    const member = () => ({ type:'MemberExpression', computed:false, optional:false,
      object: tmpId(), property:{ type:'Identifier', name: propName } });
    const memberDot = (k) => ({ type:'MemberExpression', computed:false, optional:false,
      object: member(), property:{ type:'Identifier', name:k } });
    // (__mrK = recv).name   — assignment-then-member, evaluates recv once
    const seededMember = { type:'MemberExpression', computed:false, optional:false,
      object: { type:'AssignmentExpression', operator:'=', left: tmpId(), right: callee.object },
      property:{ type:'Identifier', name: propName } };
    const test = { type:'LogicalExpression', operator:'&&',
      left: seededMember, right: memberDot('__clo') };
    // A METHOD box (tagged `__method`) takes the receiver as `__this` after env; a plain closure box does
    // not. Branch on the tag at runtime so both shapes dispatch through the same member call.
    const methodCall = { type:'CallExpression', optional:false, _skipWrap:true,
      callee: memberDot('fn'), arguments: [ memberDot('env'), tmpId(), ...node.arguments ] };
    const plainBoxCall = { type:'CallExpression', optional:false, _skipWrap:true,
      callee: memberDot('fn'), arguments: [ memberDot('env'), ...node.arguments ] };
    // A BOUND box (from `fn.bind(thisArg)`) re-invokes the bound funcref as `fn.apply(bthis, [args])`.
    const boundCall = { type:'CallExpression', optional:false, _skipWrap:true,
      callee:{ type:'MemberExpression', computed:false, object: memberDot('fn'), property:{ type:'Identifier', name:'apply' } },
      arguments:[ memberDot('bthis'), { type:'ArrayExpression', elements: node.arguments } ] };
    const boxCall = { type:'ConditionalExpression',
      test: memberDot('__bound'), consequent: boundCall,
      alternate: { type:'ConditionalExpression',
        test: memberDot('__method'), consequent: methodCall, alternate: plainBoxCall } };
    const nativeCall = { type:'CallExpression', optional:false, _skipWrap:true,
      callee: member(), arguments: node.arguments };
    return { type:'ConditionalExpression', test, consequent: boxCall, alternate: nativeCall };
  }
  function wrapCalls(node) {
    if (!node || typeof node !== 'object') return;
    // `X.prototype` in a WRITE position (`X.prototype = v`, `++X.prototype`) must not become `__cproto(X)`
    // (can't assign to a call). Mark the direct target member so maybeWrap leaves it native; reads elsewhere
    // (incl. `X.prototype.m = v`, where `X.prototype` is an object sub-expression) still get rewritten.
    if (node.type === 'AssignmentExpression' && node.left) node.left._writeTarget = true;
    if (node.type === 'UpdateExpression' && node.argument) node.argument._writeTarget = true;
    for (const k in node) {
      if (k === 'type' || k[0] === '_') continue;
      const v = node[k];
      if (Array.isArray(v)) { for (let i = 0; i < v.length; i++) { wrapCalls(v[i]); v[i] = maybeWrap(v[i]); } }
      else if (v && typeof v === 'object' && v.type) { wrapCalls(v); node[k] = maybeWrap(v); }
    }
  }
  // A receiver/callee that can never hold a user box: a known global identifier.
  const isGlobalIdent = n => n && n.type === 'Identifier' && GLOBALS.has(n.name);
  // Is an expression rooted at a global identifier (e.g. `Math`, `Math.max`, `Object.prototype.x`)? Such
  // intrinsics resolve specially in Porffor codegen and must never be aliased to a temp.
  const rootedAtGlobal = n => !n ? false : n.type === 'Identifier' ? GLOBALS.has(n.name)
    : n.type === 'MemberExpression' ? rootedAtGlobal(n.object) : false;
  function maybeWrap(node) {
    if (!node || node._skipWrap) return node;
    // `X instanceof Y` where Y may be a BOXED constructor: a box `{__clo,env,fn}` is an object, not a
    // function, so native `instanceof` throws "right-hand side is not a function". Route through __cinst,
    // which unwraps a box to its real constructor `Y.fn` (native functions/globals pass straight through).
    if (node.type === 'BinaryExpression' && node.operator === 'instanceof' && node.right && !isGlobalIdent(node.right)) {
      needCinst = true;
      return { type:'CallExpression', optional:false, _skipWrap:true,
        callee:{ type:'Identifier', name:'__cinst' }, arguments:[ node.left, node.right ] };
    }
    // `new X(args)` where X may be a boxed constructor: a box `{__clo,env,fn}` can't be `new`'d, but its `fn`
    // is a real function. Route through __cnew, which constructs `fn` with the env threaded as first arg.
    if (node.type === 'NewExpression' && node.callee && !isGlobalIdent(node.callee)) {
      needCnew = true;
      return { type:'CallExpression', optional:false, _skipWrap:true,
        callee:{ type:'Identifier', name:'__cnew' },
        arguments:[ node.callee, { type:'ArrayExpression', elements: node.arguments } ] };
    }
    // `X.prototype` (read) where X may be a boxed constructor → __cproto(X) (returns X.fn.prototype for a box).
    if (node.type === 'MemberExpression' && !node.computed && !node._writeTarget &&
        node.property && node.property.type === 'Identifier' && node.property.name === 'prototype' &&
        node.object && !isGlobalIdent(node.object)) {
      needCproto = true;
      return { type:'CallExpression', optional:false, _skipWrap:true,
        callee:{ type:'Identifier', name:'__cproto' }, arguments:[ node.object ] };
    }
    if (node.type !== 'CallExpression') return node;
    if (node._skipWrap) return node;
    const callee = node.callee;
    if (!callee) return node;
    // `Object.defineProperty(o, k, desc)` with a BOXED get/set: a box isn't a function so defineProperty
    // rejects it. Route through __defprop, which stamps the box onto `o` and installs a closure-free,
    // `this`-based accessor (Porffor can't synthesize a capturing wrapper).
    if (callee.type === 'MemberExpression' && !callee.computed && callee.object &&
        callee.object.type === 'Identifier' && callee.object.name === 'Object' &&
        callee.property && callee.property.name === 'defineProperty' && node.arguments.length === 3 &&
        !node.arguments.some(a => a.type === 'SpreadElement')) {
      needDefprop = true;
      return { type:'CallExpression', optional:false, _skipWrap:true,
        callee:{ type:'Identifier', name:'__defprop' }, arguments: node.arguments };
    }
    // `super(...)` / `super.m(...)` are special forms — never a box, can't be passed as a value. Leave native.
    if (callee.type === 'Super' || (callee.object && callee.object.type === 'Super')) return node;
    if (isGlobalMemberCallee(callee)) {
      // Only non-computed `recv.name(...)` can be box-or-native ambiguous. Route through the inline
      // ternary dispatch. Computed/spread/optional member calls fall through unchanged (native only).
      // Only non-computed `recv.name(...)` can be box-or-native ambiguous. Route through the inline
      // ternary dispatch. Computed/spread/optional member calls fall through unchanged (native only) —
      // a computed callee may be ordinary indexing (`s[i]`, `arr[x]`) whose value-routing Porffor mangles.
      if (!callee.computed && callee.property && callee.property.type === 'Identifier') {
        const d = memberCallDispatch(node);
        if (d) return d;
      }
      // A COMPUTED-element call `obj[key](args)` may hit a BOXED closure stored in an array/object slot
      // (e.g. Rollup's `bufferParsers[nodeType](...)` — a table of boxed parser fns). A box isn't natively
      // callable, so dispatch through `box.fn` (threading env, and the receiver as `__this` for a __method);
      // a native element keeps `obj[key](...)` so `this` = obj is preserved.
      if (callee.computed && callee.property) {
        const d = computedMemberCallDispatch(node);
        if (d) return d;
      }
      return node;
    }
    if (callee.type === 'Identifier' && GLOBALS.has(callee.name)) return node;
    if (node.arguments.length === 1 && node.arguments[0].type === 'SpreadElement') {
      needCallS = true;
      return { type:'CallExpression', optional:false,
        callee:{type:'Identifier',name:'__callS'},
        arguments:[callee, node.arguments[0].argument] };
    }
    if (node.arguments.some(a => a.type === 'SpreadElement')) return node;
    // Cap at 15: a boxed dispatch becomes `f.fn(f.env, a0..a{N-1})` = N+1 args through call_indirect, which
    // Porffor truncates at wrapperArgc (16) — so N+1 must stay <= 16. Above 15, leave a direct call (Porffor
    // can't pass >16 args indirectly anyway). Was 8, which dropped real 9..15-arg boxed calls (e.g. rollup's
    // 12-arg `resolveId(...)`, a boxed top-level async fn) back to an uncallable direct box invocation.
    if (node.arguments.length > 15) return node;
    // A call to a KNOWN top-level function declaration that can never hold a closure box stays a DIRECT call
    // — never routed through __callN. Porffor miscompiles an indirectly-called plain top-level function when
    // another function is present (the function's body silently doesn't run); a box's `.fn` indirect call is
    // unaffected, so only these provably-not-a-box callees need the direct path. Always semantically correct:
    // the name resolves to exactly that function.
    if (callee.type === 'Identifier' && directCallable.has(callee.name)) return node;
    const N = node.arguments.length;
    usedArities.add(N);
    return { type: 'CallExpression', optional:false,
      callee: { type:'Identifier', name:'__call'+N },
      arguments: [callee, ...node.arguments] };
  }

  // Names safe to call directly: a TOP-LEVEL `function f(){}` declaration that is never reassigned, never
  // captured into an env (so never boxed), and not shadowed by any other binding in any scope. For these,
  // `f(...)` is unambiguously that function — skip the __callN box-dispatch (and dodge the Porffor
  // indirect-plain-function bug). Conservative: any ambiguity (assignment, capture, same name elsewhere)
  // drops the name from the set and it keeps the safe __callN path.
  const directCallable = new Set();
  {
    const nameCounts = new Map();           // name -> number of distinct bindings (any scope)
    const topFuncDecls = new Set();         // names declared by a top-level FunctionDeclaration
    const assigned = new Set();             // names ever on the LHS of `=`/update
    const captured = new Set();             // names captured into an env (=> boxed)
    for (const b of bindings.values()) {
      nameCounts.set(b.name, (nameCounts.get(b.name) || 0) + 1);
      if (b.captured) captured.add(b.name);
      if (b.ownerScopeId === 0 && b.declNode && b.declNode.type === 'FunctionDeclaration') topFuncDecls.add(b.name);
    }
    (function findAssigns(node) {
      if (!node || typeof node !== 'object') return;
      if (node.type === 'AssignmentExpression' && node.left && node.left.type === 'Identifier') assigned.add(node.left.name);
      if (node.type === 'UpdateExpression' && node.argument && node.argument.type === 'Identifier') assigned.add(node.argument.name);
      for (const k in node) {
        if (k === 'type' || k[0] === '_') continue;
        const v = node[k];
        if (Array.isArray(v)) { for (const e of v) if (e && e.type) findAssigns(e); }
        else if (v && v.type) findAssigns(v);
      }
    })(ast);
    for (const name of topFuncDecls) {
      if (nameCounts.get(name) === 1 && !assigned.has(name) && !captured.has(name)) directCallable.add(name);
    }

    // Intrinsic-bridge functions: a function whose body uses the `Porffor.wasm` dialect (e.g. the host-call
    // marshalling helper `hostCall`) ONLY compiles correctly when called DIRECTLY — Porffor resolves
    // `Porffor.wasm`local.get ${param}`` / `Porffor.wasm.i32.load8_u` against the function's real param
    // positions, which a `__callN`/`call_indirect` wrapper shifts (argc/new.target/this prepended), breaking
    // the intrinsic at runtime. So force-mark such a named function directCallable even when it's captured
    // (referenced from a boxed scope) — it captures nothing, so a direct call is always correct.
    const usesPorfforWasm = (fn) => {
      let found = false;
      (function w(n, top) {
        if (found || !n || typeof n !== 'object') return;
        if (!top && isFunc(n)) return; // don't descend into nested functions
        if (n.type === 'MemberExpression' && n.object && n.object.type === 'Identifier' && n.object.name === 'Porffor'
            && n.property && n.property.name === 'wasm') { found = true; return; }
        for (const k in n) { if (k === 'type' || k[0] === '_') continue; const v = n[k];
          if (Array.isArray(v)) { for (const c of v) if (c && c.type) w(c, false); }
          else if (v && v.type) w(v, false); }
      })(fn.body, true);
      return found;
    };
    (function scanWasm(node) {
      if (!node || typeof node !== 'object') return;
      if (node.type === 'FunctionDeclaration' && node.id && usesPorfforWasm(node)) directCallable.add(node.id.name);
      if (node.type === 'VariableDeclarator' && node.id && node.id.type === 'Identifier'
          && node.init && isFunc(node.init) && usesPorfforWasm(node.init)) directCallable.add(node.id.name);
      for (const k in node) { if (k === 'type' || k[0] === '_') continue; const v = node[k];
        if (Array.isArray(v)) { for (const c of v) if (c && c.type) scanWasm(c); }
        else if (v && v.type) scanWasm(v); }
    })(ast);
  }
  wrapCalls(ast);

  const helpers = [];
  for (const N of [...usedArities].sort((a,b)=>a-b)) {
    const params = ['f']; for (let i=0;i<N;i++) params.push('a'+i);
    const passArgs = params.slice(1).map(p => p);
    helpers.push(
      `function __call${N}(${params.join(',')}){ if(f&&typeof f==='object'&&f.__clo){ if(f.__uncurry)return f.fn.call(${passArgs.join(',')}); if(f.__bound)return f.fn.apply(f.bthis,[${passArgs.join(',')}]); return f.fn(${['f.env',...passArgs].join(',')}); } return f(${passArgs.join(',')}); }`);
  }
  if (needCnew) {
    // Construct a possibly-boxed constructor: a box's `fn` is the real constructor; thread its env first.
    helpers.push(
      `function __cnew(f, a){ return f && typeof f==='object' && f.__clo ? Reflect.construct(f.fn, [f.env].concat(a)) : Reflect.construct(f, a); }`);
  }
  if (needCproto) {
    helpers.push(
      `function __cproto(o){ return o && typeof o==='object' && o.__clo ? o.fn.prototype : o.prototype; }`);
  }
  if (needCinst) {
    helpers.push(
      `function __cinst(x, y){ return x instanceof (y && typeof y==='object' && y.__clo ? y.fn : y); }`);
  }
  if (needDefprop) {
    // A boxed get/set can't be a defineProperty accessor (a box isn't a function), and Porffor can't
    // synthesize a capturing wrapper. Stamp the box's fn/env onto the target object and install a
    // closure-free `this`-based accessor that reads them. Porffor can't synthesize a getter that CAPTURES
    // the property key, so we can't key the slot by `k` at runtime. Instead keep a PER-OBJECT index counter
    // and a fixed POOL of pre-generated non-capturing accessors: pool entry `i` reads the literal slots
    // `this.__gbf<i>`/`this.__gbe<i>`. defineProperty grabs the next free index, stashes the box's fn/env in
    // those slots, and installs the matching pool accessor. This supports up to __DP_POOL boxed getters AND
    // setters per object (rollup's cacheObjectGetters installs several lazy getters on one `module.info`).
    const DP_POOL = 32;
    const gpool = Array.from({ length: DP_POOL }, (_, i) =>
      `function(){ return this.__gbf${i}(this.__gbe${i}); }`).join(',');
    const spool = Array.from({ length: DP_POOL }, (_, i) =>
      `function(v){ return this.__sbf${i}(this.__sbe${i}, v); }`).join(',');
    helpers.push(
      `var __gpool = [${gpool}];\nvar __spool = [${spool}];\n` +
      `function __defprop(o, k, d){ if (d) { var g = d.get, s = d.set;` +
      ` if (g && g.__clo) { var i = o.__gn | 0; if (i >= ${DP_POOL}) throw new TypeError('too many boxed getters per object'); o.__gn = i + 1; o['__gbf' + i] = g.fn; o['__gbe' + i] = g.env; d.get = __gpool[i]; }` +
      ` if (s && s.__clo) { var j = o.__sn | 0; if (j >= ${DP_POOL}) throw new TypeError('too many boxed setters per object'); o.__sn = j + 1; o['__sbf' + j] = s.fn; o['__sbe' + j] = s.env; d.set = __spool[j]; } }` +
      ` return Object.defineProperty(o, k, d); }`);
  }
  if (needCallS) {
    helpers.push(
      `function __callS(f, arr){ var n = arr.length;` +
      ` if (f && typeof f==='object' && f.__clo) { if (f.__uncurry) return f.fn.call.apply(f.fn, arr); if (f.__bound) return f.fn.apply(f.bthis, arr); var e = f.env; if(n===0)return f.fn(e); if(n===1)return f.fn(e,arr[0]); if(n===2)return f.fn(e,arr[0],arr[1]); if(n===3)return f.fn(e,arr[0],arr[1],arr[2]); return f.fn(e,arr[0],arr[1],arr[2],arr[3]); }` +
      ` if(n===0)return f(); if(n===1)return f(arr[0]); if(n===2)return f(arr[0],arr[1]); if(n===3)return f(arr[0],arr[1],arr[2]); return f(arr[0],arr[1],arr[2],arr[3]); }`);
  }
  // HOF helpers: invoke the callback (box or plain fn) with static arity per element.
  // NOTE: helper-local names are deliberately mangled (__be/__bf/__hi/__hr/__hx/__hj/__hcmp). Porffor has a
  // scoping bug where a `var` inside a function that shadows a top-level `function NAME` recurses infinitely;
  // mangled names avoid colliding with any user binding.
  // Shared callback invoker: dispatches a plain fn, a closure box `fn(env,…)`, or a BOUND box
  // `fn.apply(bthis,[…])`. Used by every HOF so a `fn.bind(this)` callback keeps its bound receiver.
  const hofInvoke = `function __hcb3(__cb,a,b,c){ if(__cb&&__cb.__clo){ if(__cb.__uncurry)return __cb.fn.call(a,b,c); if(__cb.__bound)return __cb.fn.apply(__cb.bthis,[a,b,c]); return __cb.fn(__cb.env,a,b,c); } return __cb(a,b,c); }` +
    `\nfunction __hcb4(__cb,a,b,c,d){ if(__cb&&__cb.__clo){ if(__cb.__uncurry)return __cb.fn.call(a,b,c,d); if(__cb.__bound)return __cb.fn.apply(__cb.bthis,[a,b,c,d]); return __cb.fn(__cb.env,a,b,c,d); } return __cb(a,b,c,d); }` +
    `\nfunction __hcb2(__cb,a,b){ if(__cb&&__cb.__clo){ if(__cb.__uncurry)return __cb.fn.call(a,b); if(__cb.__bound)return __cb.fn.apply(__cb.bthis,[a,b]); return __cb.fn(__cb.env,a,b); } return __cb(a,b); }`;
  const hofDefs = {
    __hcb:  hofInvoke,
    map:    `function __hof_map(arr,__cb){ var __hr=[]; for(var __hi=0;__hi<arr.length;__hi++)__hr.push(__hcb3(__cb,arr[__hi],__hi,arr)); return __hr; }`,
    filter: `function __hof_filter(arr,__cb){ var __hr=[]; for(var __hi=0;__hi<arr.length;__hi++){if(__hcb3(__cb,arr[__hi],__hi,arr))__hr.push(arr[__hi]);} return __hr; }`,
    forEach:`function __hof_forEach(arr,__cb){ for(var __hi=0;__hi<arr.length;__hi++)__hcb3(__cb,arr[__hi],__hi,arr); }`,
    reduce: `function __hof_reduce(arr,__cb,__hacc){ for(var __hi=0;__hi<arr.length;__hi++)__hacc=__hcb4(__cb,__hacc,arr[__hi],__hi,arr); return __hacc; }`,
    reduce1:`function __hof_reduce1(arr,__cb){ var __hacc=arr[0]; for(var __hi=1;__hi<arr.length;__hi++)__hacc=__hcb4(__cb,__hacc,arr[__hi],__hi,arr); return __hacc; }`,
    find:   `function __hof_find(arr,__cb){ for(var __hi=0;__hi<arr.length;__hi++){if(__hcb3(__cb,arr[__hi],__hi,arr))return arr[__hi];} return undefined; }`,
    findIndex:`function __hof_findIndex(arr,__cb){ for(var __hi=0;__hi<arr.length;__hi++){if(__hcb3(__cb,arr[__hi],__hi,arr))return __hi;} return -1; }`,
    some:   `function __hof_some(arr,__cb){ for(var __hi=0;__hi<arr.length;__hi++){if(__hcb3(__cb,arr[__hi],__hi,arr))return true;} return false; }`,
    every:  `function __hof_every(arr,__cb){ for(var __hi=0;__hi<arr.length;__hi++){if(!__hcb3(__cb,arr[__hi],__hi,arr))return false;} return true; }`,
    sort:   `function __hof_sort(arr,__cb){ var __ha=arr.slice(); for(var __hi=1;__hi<__ha.length;__hi++){ var __hx=__ha[__hi]; var __hj=__hi-1; while(__hj>=0){ var __hcmp=__hcb2(__cb,__ha[__hj],__hx); if(__hcmp>0){__ha[__hj+1]=__ha[__hj];__hj--;} else break; } __ha[__hj+1]=__hx; } for(var __hi=0;__hi<__ha.length;__hi++)arr[__hi]=__ha[__hi]; return arr; }`,
  };
  if (usedHofs.size) helpers.push(hofDefs.__hcb);
  for (const name of usedHofs) helpers.push(hofDefs[name]);

  // ── Post-pass: native class methods can't capture an enclosing local, so redirect their `__env_N.x`
  // refs to a `static __cap = { eN: __env_N }` field, reached via `this.constructor.__cap.eN` (instance/
  // getter/setter/ctor) or `this.__cap.eN` (static). The replacement stops at nested function boundaries
  // (a boxed inner closure rebinds `__env_N` from its `__env` param) but DOES rewrite a box's `env: {eN:
  // __env_N}` literal, which sits at the method's own level. ──
  (function lowerClassCaptures(node) {
    if (!node || typeof node !== 'object') return;
    if (node.type === 'ClassBody') {
      const used = new Set();
      const holderOf = isStatic => isStatic ? { type:'ThisExpression' }
        : { type:'MemberExpression',computed:false,optional:false,object:{type:'ThisExpression'},
            property:{type:'Identifier',name:'constructor'} };
      const capRef = (sid, isStatic) => ({ type:'MemberExpression',computed:false,optional:false,
        object:{ type:'MemberExpression',computed:false,optional:false, object: holderOf(isStatic),
          property:{type:'Identifier',name:'__cap'} }, property:{type:'Identifier',name:'e'+sid} });
      // __env_N DECLARED inside the method (an env alloc / per-loop env for the method's OWN scope) stays a
      // real local — only __env_N captured from an ENCLOSING scope is redirected to the static field.
      const localEnvs = body => {
        const set = new Set();
        (function w(n){ if (!n || typeof n !== 'object') return;
          if (isFunc(n)) return;
          if (n.type === 'VariableDeclaration') for (const d of n.declarations)
            if (d.id && d.id.type === 'Identifier' && /^__env_\d+$/.test(d.id.name)) set.add(d.id.name);
          for (const k in n) { if (k === 'type' || k[0] === '_') continue; const v = n[k];
            if (Array.isArray(v)) { for (const c of v) if (c && c.type) w(c); }
            else if (v && v.type) w(v); } })(body);
        return set;
      };
      const rewrite = (n, isStatic, local) => {
        const repl = c => {
          if (!c || !c.type) return c;
          if (c.type === 'Identifier' && /^__env_\d+$/.test(c.name) && !local.has(c.name)) {
            const sid = c.name.slice(6); used.add(sid); return capRef(sid, isStatic);
          }
          // A captured ref in a PARAMETER DEFAULT was emitted as the member form `__env.e<sid>` (reaching the
          // box's `__env` param). A native class method has NO `__env` param, so that ref is unbound (throws
          // "env is not defined"). Redirect it to the same static `__cap` field as body refs. Param defaults
          // are evaluated with `this` bound, so `this.constructor.__cap.e<sid>` (or `this.__cap` static) works.
          if (c.type === 'MemberExpression' && !c.computed && c.object && c.object.type === 'Identifier'
              && c.object.name === '__env' && c.property && c.property.type === 'Identifier'
              && /^e\d+$/.test(c.property.name)) {
            const sid = c.property.name.slice(1); used.add(sid); return capRef(sid, isStatic);
          }
          if (isFunc(c)) return c;           // don't descend into nested function bodies
          rewrite(c, isStatic, local); return c;
        };
        for (const k in n) { if (k === 'type' || k[0] === '_') continue; const v = n[k];
          if (Array.isArray(v)) { for (let i = 0; i < v.length; i++) v[i] = repl(v[i]); }
          else if (v && typeof v === 'object') n[k] = repl(v); }
      };
      for (const el of node.body)
        if (el.type === 'MethodDefinition' && el.value && el.value.body) {
          const local = localEnvs(el.value.body);
          rewrite(el.value.body, !!el.static, local);
          // ALSO process param defaults — their captured refs are the `__env.e<sid>` member form above.
          for (const p of el.value.params) rewrite(p, !!el.static, local);
        }
      if (used.size) node.body.unshift({ type:'PropertyDefinition', static:true, computed:false,
        key:{type:'Identifier',name:'__cap'},
        value:{ type:'ObjectExpression', properties:[...used].sort().map(sid => ({
          type:'Property',kind:'init',method:false,shorthand:false,computed:false,
          key:{type:'Identifier',name:'e'+sid}, value:{type:'Identifier',name:'__env_'+sid} })) } });
    }
    for (const k in node) { if (k === 'type' || k[0] === '_') continue; const v = node[k];
      if (Array.isArray(v)) { for (const c of v) if (c && c.type) lowerClassCaptures(c); }
      else if (v && v.type) lowerClassCaptures(v); }
  })(ast);

  // ── `typeof X === "function"` must be TRUE for a closure box `{__clo,env,fn}`. A box is a plain object,
  // so native `typeof` reports "object" — code that gates calling a value on `typeof f === "function"`
  // (e.g. rollup's plugin-hook driver: `if (typeof handler !== "function") return handler;`) then treats a
  // boxed callback as a non-callable value. Rewrite `typeof X (==|===) "function"` → `__isFn(X)` (and the
  // negated forms → `!__isFn(X)`), where __isFn also accepts boxes. Runs before helper injection so the
  // injected helpers (which test `typeof f === 'object'`) are untouched.
  let usesIsFn = false;
  let usesIsFnHelper = false; // only the non-identifier path needs the __isFn helper (identifiers inline)
  const isTypeofFn = (n) => n && n.type === 'BinaryExpression' &&
    (n.operator === '===' || n.operator === '==' || n.operator === '!==' || n.operator === '!=') &&
    (() => {
      const a = n.left, b = n.right;
      const typof = (x) => x && x.type === 'UnaryExpression' && x.operator === 'typeof';
      const fnLit = (x) => x && x.type === 'Literal' && x.value === 'function';
      return (typof(a) && fnLit(b)) || (typof(b) && fnLit(a));
    })();
  const mkIsFn = (n) => {
    const typof = (x) => x && x.type === 'UnaryExpression' && x.operator === 'typeof';
    const arg = typof(n.left) ? n.left.argument : n.right.argument;
    const negated = (n.operator === '!==' || n.operator === '!=');
    let expr;
    if (arg.type === 'Identifier') {
      // A BARE identifier may be an UNDEFINED GLOBAL (UMD: `typeof define`/`typeof module`). `__isFn(arg)`
      // would evaluate arg as a call argument → ReferenceError; native `typeof` never throws on an undefined
      // identifier. Inline a typeof-FIRST check so arg is only read as a value once typeof confirms it's an
      // object:  typeof X === 'function' || (typeof X === 'object' && X !== null && X.__clo === 1)
      const A = () => ({ type: 'Identifier', name: arg.name });
      const tof = (lit) => ({ type: 'BinaryExpression', operator: '===',
        left: { type: 'UnaryExpression', operator: 'typeof', prefix: true, argument: A() },
        right: { type: 'Literal', value: lit } });
      expr = { type: 'LogicalExpression', operator: '||', left: tof('function'),
        right: { type: 'LogicalExpression', operator: '&&',
          left: { type: 'LogicalExpression', operator: '&&', left: tof('object'),
            right: { type: 'BinaryExpression', operator: '!==', left: A(), right: { type: 'Literal', value: null } } },
          right: { type: 'BinaryExpression', operator: '===',
            left: { type: 'MemberExpression', computed: false, optional: false, object: A(),
              property: { type: 'Identifier', name: '__clo' } },
            right: { type: 'Literal', value: 1 } } } };
    } else {
      usesIsFnHelper = true;
      expr = { type: 'CallExpression', optional: false,
        callee: { type: 'Identifier', name: '__isFn' }, arguments: [ arg ] };
    }
    return negated ? { type: 'UnaryExpression', operator: '!', prefix: true, argument: expr } : expr;
  };
  (function rewriteTypeofFn(node) {
    if (!node || typeof node !== 'object') return;
    for (const k in node) {
      if (k === 'type' || k[0] === '_') continue;
      const v = node[k];
      if (Array.isArray(v)) {
        for (let i = 0; i < v.length; i++) {
          if (isTypeofFn(v[i])) { v[i] = mkIsFn(v[i]); usesIsFn = true; } else rewriteTypeofFn(v[i]);
        }
      } else if (isTypeofFn(v)) { node[k] = mkIsFn(v); usesIsFn = true; }
      else rewriteTypeofFn(v);
    }
  })(ast);
  if (usesIsFnHelper) helpers.push(
    `function __isFn(x){ return typeof x === 'function' || (x != null && typeof x === 'object' && x.__clo === 1); }`);

  const helperAst = parse(helpers.join('\n'));
  ast.body.unshift(...helperAst.body);

  // Hoist receiver temps used by inline member-call dispatch (one shared `var __mr0,__mr1,…;`).
  if (nextMtmp > 0) {
    ast.body.unshift({ type:'VariableDeclaration', kind:'var',
      declarations: Array.from({length: nextMtmp}, (_,i) => ({
        type:'VariableDeclarator', id:{type:'Identifier', name:'__mr'+i}, init:null })) });
  }

  return generate(ast);
}

function main() {
  const fs = require('fs');
  const path = process.argv[2];
  let src;
  try { src = path ? fs.readFileSync(path, 'utf8') : fs.readFileSync(0, 'utf8'); } catch (e) { process.exit(2); }
  let out;
  try { out = transform(src); } catch (_) { out = src; }
  process.stdout.write(out);
}
if (require.main === module) main();
module.exports = { transform };
