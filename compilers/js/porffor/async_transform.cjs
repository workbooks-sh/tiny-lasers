/* Async→then-chain (CPS) lowering pre-pass for the Porffor lane.
 *
 * Porffor compiles `async function` via the EAGER generator path and `await x` as a blocking
 * `__Porffor_promise_await(x)` that drives the microtask queue inline — so it never SUSPENDS, and
 * cross-async microtask ORDER diverges from node (an async body runs its post-await tail before the
 * synchronous code that follows the call). True await needs either stackful suspension (BEAM fibers) or
 * a continuation-passing transform. This pass does the latter, fully in-wasm: it rewrites an async
 * function into a PLAIN function that returns a Promise chain, splitting the body at each statement-level
 * `await` into a `.then` continuation. `Promise.resolve(X).then(cont)` defers `cont` exactly one microtask
 * (node's await semantics) and threads the resolved value — so ordering becomes byte-identical to node.
 *
 * This is only correct + possible because capturing `.then` callbacks now fire (the closure-box reaction
 * fix): each continuation captures the async body's locals.
 *
 *   async function f(a){ S0; await E1; S1; const x = await E2; S2; return R; }
 *     ⇩
 *   function f(a){ S0; return Promise.resolve(E1).then(function(){
 *                    S1; return Promise.resolve(E2).then(function(x){
 *                      S2; return R; }); }); }
 *
 * SUPPORTED (the dominant shape): awaits at STATEMENT position —
 *   `await E;`              (ExpressionStatement)
 *   `const/let/var x = await E;` (single declarator)
 *   `x = await E;`          (assignment)
 *   `return await E;` / `return E;`
 * in a flat BlockStatement body (including a trailing plain `return`).
 *
 * BAILED per-function (left async → Porffor's blocking fallback, documented gap, never miscompiled): an
 * `await` anywhere OTHER than those statement positions — inside an expression (`f(await x)`), a condition,
 * a loop/try/if body, or `for await`. Bailing one function never affects the rest of the file.
 *
 * On ANY error → return source unchanged.
 */
const acorn = require('./node_modules/acorn');
const { generate } = require('./node_modules/astring');

function parse(src) {
  for (const sourceType of ['module', 'script']) {
    try { return acorn.parse(src, { ecmaVersion: 2023, sourceType, allowReturnOutsideFunction: true }); }
    catch (_) {}
  }
  throw new Error('parse failed');
}

function children(node) {
  const out = [];
  for (const k in node) {
    if (k === 'type' || k[0] === '_') continue;
    const v = node[k];
    if (Array.isArray(v)) { for (const e of v) if (e && e.type) out.push(e); }
    else if (v && v.type) out.push(v);
  }
  return out;
}

// A CPS loop becomes a recursive `function(){…}` whose body is re-invoked via a bare `__loop()`. If the
// body (or a `while`/`do-while` test) references `this`, lexical `this` cannot survive: closure_convert
// threads `this`→`__this` as a method param, but the recursive `__loop()` passes no receiver, so `this`
// is undefined on the 2nd+ iteration (e.g. rollup's `do { await this.latestLoadModulesPromise } while…`).
// Fix: hoist `const __cpsThisN = this;` at method scope (where `this` is valid) and rewrite `this` →
// `__cpsThisN` inside the loop, so closure_convert captures it as an ordinary const via the env. Do NOT
// descend into nested non-arrow functions — their `this` is dynamic and must stay a real `this`.
function aliasThisInPlace(node, aliasName, found) {
  if (!node || typeof node !== 'object') return;
  if (Array.isArray(node)) { for (const e of node) aliasThisInPlace(e, aliasName, found); return; }
  if (typeof node.type !== 'string') return;
  if (node.type === 'FunctionExpression' || node.type === 'FunctionDeclaration') return; // own `this`
  for (const k in node) {
    if (k === 'type' || k[0] === '_') continue;
    const v = node[k];
    if (Array.isArray(v)) {
      for (let i = 0; i < v.length; i++) {
        if (v[i] && v[i].type === 'ThisExpression') { v[i] = id(aliasName); found.hit = true; }
        else aliasThisInPlace(v[i], aliasName, found);
      }
    } else if (v && v.type === 'ThisExpression') {
      node[k] = id(aliasName); found.hit = true;
    } else {
      aliasThisInPlace(v, aliasName, found);
    }
  }
}

// Does the subtree contain an AwaitExpression that belongs to THIS function (not a nested function)?
function hasOwnAwait(node) {
  if (!node || typeof node !== 'object') return false;
  if (node.type === 'AwaitExpression') return true;
  // do not descend into nested functions — their awaits are their own
  if (node.type === 'FunctionDeclaration' || node.type === 'FunctionExpression' || node.type === 'ArrowFunctionExpression') return false;
  for (const c of children(node)) if (hasOwnAwait(c)) return true;
  return false;
}

const id = (name) => ({ type: 'Identifier', name });
const isFunc = n => n && (n.type === 'FunctionDeclaration' || n.type === 'FunctionExpression' || n.type === 'ArrowFunctionExpression');

// Build `Promise.resolve(arg).then(function(<contParam?>){ <contBody> })`.
function thenChain(arg, contParam, contBody) {
  const params = contParam ? [contParam] : [];
  return {
    type: 'CallExpression', optional: false,
    callee: {
      type: 'MemberExpression', computed: false, optional: false,
      object: {
        type: 'CallExpression', optional: false,
        callee: { type: 'MemberExpression', computed: false, optional: false,
          object: id('Promise'), property: id('resolve') },
        arguments: [arg]
      },
      property: id('then')
    },
    // ARROW (not FunctionExpression) so the continuation inherits the async fn's lexical `this` — an async
    // method preserves `this` across `await` per spec, and closure_convert only threads `this`→`__this` into
    // arrows, so a non-arrow continuation would see `this === undefined` (e.g. rollup's loadEntryModule using
    // `this.fetchModule` after `await resolveId(...)`). Arrows have no own `this`/`arguments`, which is exactly
    // the await-continuation semantics. Returns in a block-body arrow still settle the chained promise.
    arguments: [{ type: 'ArrowFunctionExpression', id: null, params, generator: false, async: false,
      expression: false, body: { type: 'BlockStatement', body: contBody } }]
  };
}

// Classify a statement that introduces a top-level await. Returns {await: <expr>, bind: <pattern|null>} or
// null if this statement does not start with an await in a supported position.
function awaitStmt(stmt) {
  if (stmt.type === 'ExpressionStatement') {
    const e = stmt.expression;
    if (e.type === 'AwaitExpression') return { await: e.argument, bind: null };
    if (e.type === 'AssignmentExpression' && e.operator === '=' && e.right.type === 'AwaitExpression')
      return { await: e.right.argument, bind: e.left, assign: true };
  }
  if (stmt.type === 'VariableDeclaration' && stmt.declarations.length === 1) {
    const d = stmt.declarations[0];
    // any binding pattern: `const x = await E`, `const {a,b} = await E`, `const [x] = await E`.
    if (d.init && d.init.type === 'AwaitExpression')
      return { await: d.init.argument, bind: d.id, decl: stmt.kind };
  }
  if (stmt.type === 'ReturnStatement' && stmt.argument && stmt.argument.type === 'AwaitExpression')
    return { await: stmt.argument.argument, bind: null, ret: true };
  return null;
}

// CPS-lower a flat statement list. Throws BAIL if an await appears in an unsupported position.
function BAIL() { const e = new Error('bail'); e._bail = true; return e; }

// `tail` = statements to run when this list completes without suspending (the enclosing continuation, e.g. a
// loop's `return __loop(i+1)`). Default [] = fall through / return undefined.
function cpsList(stmts, tail) {
  tail = tail || [];
  for (let i = 0; i < stmts.length; i++) {
    const s = stmts[i];
    const aw = awaitStmt(s);
    if (aw) {
      const pre = stmts.slice(0, i);
      const post = stmts.slice(i + 1);
      const n = awCtr++;
      // the continuation body is the CPS lowering of everything after this await (threading the tail)
      let contBody = cpsList(post, tail);
      let contParam = null;
      if (aw.bind && aw.bind.type === 'Identifier' && !aw.assign && !aw.ret) {
        contParam = id(aw.bind.name);            // const x = await E  → function(x){…}
      } else if (aw.bind && aw.decl && !aw.assign && !aw.ret) {
        // const {a,b} = await E / const [x] = await E → function(__av){ const {a,b} = __av; … }
        contParam = id('__av' + n);
        contBody = [{ type: 'VariableDeclaration', kind: aw.decl,
          declarations: [{ type: 'VariableDeclarator', id: aw.bind, init: id('__av' + n) }] }, ...contBody];
      } else if (aw.assign) {
        contParam = id('__av' + n);              // x = await E → function(__av){ x = __av; … }
        contBody = [{ type: 'ExpressionStatement', expression: {
          type: 'AssignmentExpression', operator: '=', left: aw.bind, right: id('__av' + n) } }, ...contBody];
      }
      if (aw.ret) {
        // return await E  →  return Promise.resolve(E).then(function(__rv){ return __rv; })
        contParam = id('__rv' + n);
        contBody = [{ type: 'ReturnStatement', argument: id('__rv' + n) }];
      }
      const chain = thenChain(aw.await, contParam, contBody);
      return [...pre, { type: 'ReturnStatement', argument: chain }];
    }
    // A `for (const x of ARR) { …await… }` with an await in its body: lower to a recursive index loop whose
    // body's tail re-invokes the loop, and whose exit runs the post-loop continuation. The await suspends each
    // iteration (so the recursion is async — no deep sync stack). break/continue/labels are NOT handled → BAIL.
    if (s.type === 'ForOfStatement' && hasOwnAwait(s)) {
      if (bodyHasBreakOrContinue(s.body)) throw BAIL();
      // the ITERABLE may itself be an await (`for (const x of await Promise.all(...))`) — hoist it to a
      // statement before the loop and re-process, so that await is CPS-lowered (not left raw → syntax error).
      const rightHoisted = [];
      s.right = hoistAwaitsInExpr(s.right, rightHoisted);
      if (rightHoisted.length) {
        return cpsList([...stmts.slice(0, i), ...rightHoisted, s, ...stmts.slice(i + 1)], tail);
      }
      const pre = stmts.slice(0, i);
      const exitCont = cpsList(stmts.slice(i + 1), tail);
      return [...pre, ...loopOfCPS(s, exitCont)];
    }
    // `while (T) {…await…}` / `do {…await…} while (T)` — recursive-continuation loop, like for-of. The test
    // must be await-free (re-evaluated each recursion over body-mutated captured vars). break/continue → BAIL.
    if ((s.type === 'WhileStatement' || s.type === 'DoWhileStatement') && hasOwnAwait(s)) {
      if (bodyHasBreakOrContinue(s.body) || hasOwnAwait(s.test)) throw BAIL();
      const pre = stmts.slice(0, i);
      const exitCont = cpsList(stmts.slice(i + 1), tail);
      return [...pre, ...whileCPS(s, exitCont)];
    }
    // `try { …await… } catch (e) { H }` — lower to a promise chain that mirrors try/catch control flow:
    //   const __contN = () => { <CPS post> };
    //   return Promise.resolve().then(() => { <CPS body> ; return __contN() })
    //                           .catch(e => { <CPS handler> ; return __contN() });
    // The .catch sees only BODY rejections (sync OR from any await); the handler can itself reject
    // (propagates). The post-try continuation is factored into ONE shared `__contN` (NOT inlined into both
    // arms — that duplicates `post`, and nested/sequential try/catch then explode code size → OOM). A
    // `return` inside body/handler settles the function before reaching __contN; normal completion calls it.
    // `return V` inside post returns from __contN, which each arm `return __contN()`s → the function resolves
    // to V. Needs a catch clause; `finally` and break/continue out of the try are not modeled → BAIL.
    if (s.type === 'TryStatement' && hasOwnAwait(s)) {
      if (!s.handler || s.finalizer) throw BAIL();
      if (bodyHasBreakOrContinue(s.block) || bodyHasBreakOrContinue(s.handler.body)) throw BAIL();
      const n = awCtr++;
      const pre = stmts.slice(0, i);
      const contName = '__cont' + n;
      const arrow = (params, body) => ({ type: 'ArrowFunctionExpression', id: null, params, generator: false,
        async: false, expression: false, body: { type: 'BlockStatement', body } });
      const mcall = (obj, name, args) => ({ type: 'CallExpression', optional: false,
        callee: { type: 'MemberExpression', computed: false, optional: false, object: obj, property: id(name) },
        arguments: args });
      const contDecl = { type: 'VariableDeclaration', kind: 'const', declarations: [{ type: 'VariableDeclarator',
        id: id(contName), init: arrow([], cpsList(stmts.slice(i + 1), tail)) }] };
      const callCont = () => [{ type: 'ReturnStatement', argument: { type: 'CallExpression', optional: false,
        callee: id(contName), arguments: [] } }];
      const bodyArrow = arrow([], cpsList(s.block.body, callCont()));
      const catchParam = s.handler.param ? [s.handler.param] : [];
      const catchArrow = arrow(catchParam, cpsList(s.handler.body.body, callCont()));
      const chain = mcall(mcall(mcall(id('Promise'), 'resolve', []), 'then', [bodyArrow]), 'catch', [catchArrow]);
      return [...pre, contDecl, { type: 'ReturnStatement', argument: chain }];
    }
    // a non-await statement that itself contains an own-await in a sub-position is unsupported here
    if (hasOwnAwait(s)) throw BAIL();
  }
  return [...stmts, ...tail];
}

// break/continue/labeled at the top of a loop body break the recursive-continuation model — detect to bail.
function bodyHasBreakOrContinue(node) {
  if (!node || typeof node !== 'object') return false;
  if (node.type === 'BreakStatement' || node.type === 'ContinueStatement') return true;
  // do not descend into nested loops/switch (their break/continue are their own) or nested functions
  if (node.type === 'ForStatement' || node.type === 'ForOfStatement' || node.type === 'ForInStatement' ||
      node.type === 'WhileStatement' || node.type === 'DoWhileStatement' || node.type === 'SwitchStatement' ||
      isFunc(node)) return false;
  for (const c of children(node)) if (bodyHasBreakOrContinue(c)) return true;
  return false;
}

// for (const x of ARR) BODY  →  const __arr = ARR; const __loop = function(__i){ if(__i>=__arr.length){<exit>}
//   else { const x = __arr[__i]; <CPS(BODY, tail=return __loop(__i+1))> } }; return __loop(0);
function loopOfCPS(forOf, exitCont) {
  const n = awCtr++;
  const arrName = '__arr' + n, loopName = '__loop' + n, iName = '__i' + n;
  const declKind = forOf.left.type === 'VariableDeclaration' ? forOf.left.kind : 'let';
  const loopVar = forOf.left.type === 'VariableDeclaration' ? forOf.left.declarations[0].id : forOf.left;
  const bodyStmts = forOf.body.type === 'BlockStatement' ? forOf.body.body : [forOf.body];
  // hoist `this` used in the loop body (re-invoked via the recursive loop fn) to a captured const; the
  // iterable `forOf.right` is evaluated once outside the loop fn so its `this` stays valid as-is.
  const aliasName = '__cpsThis' + n;
  const foundThis = { hit: false };
  aliasThisInPlace(bodyStmts, aliasName, foundThis);
  aliasThisInPlace(exitCont, aliasName, foundThis); // exit (i>=length) runs inside the loop fn too
  const thisDecls = foundThis.hit ? [{ type: 'VariableDeclaration', kind: 'const', declarations: [
    { type: 'VariableDeclarator', id: id(aliasName), init: { type: 'ThisExpression' } } ] }] : [];
  const recur = { type: 'ReturnStatement', argument: { type: 'CallExpression', optional: false, callee: id(loopName),
    arguments: [{ type: 'BinaryExpression', operator: '+', left: id(iName), right: { type: 'Literal', value: 1 } }] } };
  const cpsBody = cpsList(bodyStmts.flatMap(hoistStmt), [recur]);
  const loopVarDecl = { type: 'VariableDeclaration', kind: declKind === 'var' ? 'var' : 'const',
    declarations: [{ type: 'VariableDeclarator', id: loopVar,
      init: { type: 'MemberExpression', computed: true, optional: false, object: id(arrName), property: id(iName) } }] };
  const ifStmt = { type: 'IfStatement',
    test: { type: 'BinaryExpression', operator: '>=', left: id(iName),
      right: { type: 'MemberExpression', computed: false, optional: false, object: id(arrName), property: id('length') } },
    consequent: { type: 'BlockStatement', body: exitCont },
    alternate: { type: 'BlockStatement', body: [loopVarDecl, ...cpsBody] } };
  const loopFn = { type: 'FunctionExpression', id: null, params: [id(iName)],
    body: { type: 'BlockStatement', body: [ifStmt] }, generator: false, async: false, expression: false };
  return [
    ...thisDecls,
    { type: 'VariableDeclaration', kind: 'const', declarations: [{ type: 'VariableDeclarator', id: id(arrName), init: forOf.right }] },
    { type: 'VariableDeclaration', kind: 'const', declarations: [{ type: 'VariableDeclarator', id: id(loopName), init: loopFn }] },
    { type: 'ReturnStatement', argument: { type: 'CallExpression', optional: false, callee: id(loopName), arguments: [{ type: 'Literal', value: 0 }] } }
  ];
}

// while (T) BODY → const __loop = function(){ if (T) { <CPS(BODY, tail=return __loop())> } else { <exit> } };
//   return __loop();   ·   do BODY while (T) → body runs first; tail = if (T) return __loop(); <exit>.
function whileCPS(loop, exitCont) {
  const n = awCtr++;
  const loopName = '__loop' + n;
  const bodyStmts = loop.body.type === 'BlockStatement' ? loop.body.body : [loop.body];
  // hoist `this` (used in body and/or test, both live inside the recursive loop fn) to a captured const
  const aliasName = '__cpsThis' + n;
  const found = { hit: false };
  aliasThisInPlace(bodyStmts, aliasName, found);
  aliasThisInPlace(loop.test, aliasName, found);
  aliasThisInPlace(exitCont, aliasName, found); // exitCont runs inside the loop fn too
  const thisDecls = found.hit ? [{ type: 'VariableDeclaration', kind: 'const', declarations: [
    { type: 'VariableDeclarator', id: id(aliasName), init: { type: 'ThisExpression' } } ] }] : [];
  const recurCall = { type: 'CallExpression', optional: false, callee: id(loopName), arguments: [] };
  let innerBody;
  if (loop.type === 'DoWhileStatement') {
    const tail = [
      { type: 'IfStatement', test: loop.test, consequent: { type: 'ReturnStatement', argument: recurCall }, alternate: null },
      ...exitCont
    ];
    innerBody = cpsList(bodyStmts.flatMap(hoistStmt), tail);
  } else {
    const cpsBody = cpsList(bodyStmts.flatMap(hoistStmt), [{ type: 'ReturnStatement', argument: recurCall }]);
    innerBody = [{ type: 'IfStatement', test: loop.test,
      consequent: { type: 'BlockStatement', body: cpsBody },
      alternate: { type: 'BlockStatement', body: exitCont } }];
  }
  const loopFn = { type: 'FunctionExpression', id: null, params: [],
    body: { type: 'BlockStatement', body: innerBody }, generator: false, async: false, expression: false };
  return [
    ...thisDecls,
    { type: 'VariableDeclaration', kind: 'const', declarations: [{ type: 'VariableDeclarator', id: id(loopName), init: loopFn }] },
    { type: 'ReturnStatement', argument: { type: 'CallExpression', optional: false, callee: id(loopName), arguments: [] } }
  ];
}

// ── await-in-expression hoisting ──
// `const p = f("x", await g())` → `const __aw0 = await g(); const p = f("x", __aw0)`, so the await becomes
// statement-level for cpsList. Awaits are hoisted in left-to-right evaluation order. BAIL if an await sits in
// a SHORT-CIRCUIT position (&&, ||, ?:) — hoisting it would evaluate it unconditionally (wrong semantics).
let awCtr = 0;
function hoistAwaitsInExpr(node, hoisted) {
  if (!node || typeof node !== 'object') return node;
  if (isFunc(node)) return node;                    // nested function — its awaits are its own
  if (node.type === 'AwaitExpression') {
    const arg = hoistAwaitsInExpr(node.argument, hoisted);   // hoist inner awaits first (eval order)
    const name = '__aw' + (awCtr++);
    hoisted.push({ type: 'VariableDeclaration', kind: 'const',
      declarations: [{ type: 'VariableDeclarator', id: id(name),
        init: { type: 'AwaitExpression', argument: arg } }] });
    return id(name);
  }
  if ((node.type === 'LogicalExpression' || node.type === 'ConditionalExpression') && hasOwnAwait(node))
    throw BAIL();                                    // await under conditional/short-circuit eval
  for (const k in node) {
    if (k === 'type' || k[0] === '_') continue;
    const v = node[k];
    if (Array.isArray(v)) { for (let i = 0; i < v.length; i++) if (v[i] && v[i].type) v[i] = hoistAwaitsInExpr(v[i], hoisted); }
    else if (v && v.type) node[k] = hoistAwaitsInExpr(v, hoisted);
  }
  return node;
}

function hoistStmt(stmt) {
  if (awaitStmt(stmt)) return [stmt];               // already a supported statement-level await
  if (!hasOwnAwait(stmt)) return [stmt];
  const hoisted = [];
  if (stmt.type === 'VariableDeclaration') {
    for (const d of stmt.declarations) if (d.init) d.init = hoistAwaitsInExpr(d.init, hoisted);
  } else if (stmt.type === 'ExpressionStatement') {
    stmt.expression = hoistAwaitsInExpr(stmt.expression, hoisted);
  } else if (stmt.type === 'ReturnStatement' && stmt.argument) {
    stmt.argument = hoistAwaitsInExpr(stmt.argument, hoisted);
  } else {
    return [stmt];                                  // if/for/while/try with await — cpsList handles/bails
  }
  return [...hoisted, stmt];
}

function lowerAsyncFn(fn) {
  // body must be a block; an async arrow with expression body and an await → wrap
  let bodyStmts;
  if (fn.body.type === 'BlockStatement') bodyStmts = fn.body.body;
  else {
    if (fn.body.type === 'AwaitExpression') bodyStmts = [{ type: 'ReturnStatement', argument: fn.body }];
    else return; // async arrow, expr body, no await → leave to Porffor (it returns a proper promise)
  }
  // No await at all → leave async; Porffor's native async path already returns a correctly-resolved
  // promise (and converts a sync throw to a rejection). We only rewrite functions that actually suspend.
  if (!hasOwnAwait({ type: 'BlockStatement', body: bodyStmts })) return;
  bodyStmts = bodyStmts.flatMap(hoistStmt);         // hoist sub-expression awaits to statement level (may BAIL)
  const lowered = cpsList(bodyStmts);              // may throw BAIL
  fn.async = false;
  fn.body = { type: 'BlockStatement', body: lowered };
  // an arrow turned into a block body is no longer an expression
  if (fn.type === 'ArrowFunctionExpression') fn.expression = false;
}

function transform(src) {
  if (!/\basync\b/.test(src)) return src;
  const ast = parse(src);

  (function walk(node) {
    if (!node || typeof node !== 'object') return;
    if ((node.type === 'FunctionDeclaration' || node.type === 'FunctionExpression' ||
         node.type === 'ArrowFunctionExpression') && node.async && !node.generator) {
      // lower nested functions FIRST (inner awaits belong to inner fns), then this one
      for (const c of children(node.body)) walk(c);
      try { lowerAsyncFn(node); } catch (e) { if (!e._bail) throw e; /* leave async untouched */ }
      return;
    }
    for (const c of children(node)) walk(c);
  })(ast);

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
