/* arguments / variadic pre-pass for the Porffor lane.
 *
 * Two independent, safe rewrites. On ANY error the original source is returned unchanged.
 *
 * ── Rewrite A — `arguments` -> explicit rest param ────────────────────────────────────────────────
 *   A non-arrow function that *reads* `arguments` (and does not already declare a `...rest`) is given
 *   a synthetic trailing rest param `...__args0`, and every `arguments` reference inside that
 *   function (but NOT inside a nested non-arrow function, which has its own `arguments`) is rewritten
 *   to that identifier. `arguments.length`, `arguments[i]`, `for..of arguments`, etc. all then run as
 *   ordinary array ops, which Porffor 0.61 handles correctly. Arrow functions are skipped (they have
 *   no `arguments` of their own — their `arguments` binds to the nearest enclosing non-arrow, which is
 *   handled by that function's rewrite). Functions that already have a rest param, or that *assign* to
 *   `arguments`, or use it in any unsupported way, are left untouched.
 *
 * ── Rewrite B — compound-assign codegen bug ──────────────────────────────────────────────────────
 *   Porffor 0.61 miscompiles `x += RHS` when RHS reads `x` inside a Logical/Conditional sub-expression
 *   *and* the statement runs in a loop-carried position (the short-circuit operand caches a stale value
 *   of the just-assigned var). Concretely `n += (n && ' ') + a` drops `n` on the first hit.
 *
 *   The reliable, observed fix is to (1) hoist each Logical/Conditional operand of the `+` RHS to a
 *   `const` temp evaluated *before* the assignment, and (2) rewrite `x += R` into a FLAT left-assoc
 *   `x = x + t0 + t1 + …` (note: a parenthesised `x = x + (t + a)` does NOT fix it — the flat chain
 *   does). This is applied to any `+=` whose RHS contains the assigned simple variable inside a
 *   logical/conditional node. All other compound assigns are left untouched.
 *
 * Safe fallback: any structural surprise -> return source unchanged.
 */
const acornMod = require('acorn');
const { generate } = require('astring');

function parse(src) {
  for (const sourceType of ['module', 'script']) {
    try { return acornMod.parse(src, { ecmaVersion: 2023, sourceType, allowReturnOutsideFunction: true }); }
    catch (_) {}
  }
  throw new Error('parse failed');
}

const id = name => ({ type: 'Identifier', name });

// ── generic walker: visit(node, parent) on every node ────────────────────────────────────────────
function walk(node, visit, parent = null) {
  if (!node || typeof node.type !== 'string') return;
  visit(node, parent);
  for (const k of Object.keys(node)) {
    if (k === 'type' || k === 'start' || k === 'end' || k === 'loc' || k === 'range') continue;
    const v = node[k];
    if (Array.isArray(v)) { for (const c of v) if (c && typeof c.type === 'string') walk(c, visit, node); }
    else if (v && typeof v.type === 'string') walk(v, visit, node);
  }
}

const isFn = n => n && (n.type === 'FunctionDeclaration' || n.type === 'FunctionExpression');
const isArrow = n => n && n.type === 'ArrowFunctionExpression';

// ── Rewrite C — self-referential multi-declarator `var` ───────────────────────────────────────────
// Porffor 0.61 miscompiles a `var` statement where one declarator ASSIGNS a name early (in another
// declarator's initializer, e.g. `(g = x)`) and a LATER declarator re-declares that same name reading its
// prior value (`g = p ? … : "\\" + g`). Porffor re-zero-inits the var at its own declarator, wiping the
// earlier assignment, so the later initializer reads `undefined`/0. (marked's list() builds its item regex
// exactly this way: `var p = 1 < (g = t[1].trim()).length, f = {…}, g = p ? … : "\\" + g` → `g` came out
// `"\undefined"`, the item loop never matched, and the list crashed.)
//
// Splitting a statement-level `var a = …, b = …` into a hoisted `var a, b;` + sequential `a = …; b = …;`
// is exactly equivalent under JS var-hoisting, and sidesteps the per-declarator re-init. Only fires when a
// declarator name is actually read elsewhere in the same declaration's initializers (normal `var`s are left
// untouched). For-init declarations live in `ForStatement.init`, not a statement body, so they're skipped.

// collect variable reads/writes by name, skipping non-variable identifier positions (member props, keys).
function collectReads(node, out) {
  if (!node || typeof node.type !== 'string') return;
  if (node.type === 'Identifier') { out.add(node.name); return; }
  for (const k of Object.keys(node)) {
    if (k === 'type' || k === 'start' || k === 'end' || k === 'loc' || k === 'range') continue;
    if (node.type === 'MemberExpression' && k === 'property' && !node.computed) continue;
    if (node.type === 'Property' && k === 'key' && !node.computed) continue;
    const v = node[k];
    if (Array.isArray(v)) { for (const c of v) collectReads(c, out); }
    else if (v && typeof v.type === 'string') collectReads(v, out);
  }
}

function selfRefVar(node) {
  if (!node || node.type !== 'VariableDeclaration' || node.kind !== 'var') return false;
  if (node.declarations.length < 2) return false;
  const names = [];
  for (const d of node.declarations) {
    if (!d.id || d.id.type !== 'Identifier') return false; // skip destructuring
    names.push(d.id.name);
  }
  const referenced = new Set();
  for (const d of node.declarations) if (d.init) collectReads(d.init, referenced);
  return names.some(n => referenced.has(n));
}

function splitVar(node) {
  const hoist = {
    type: 'VariableDeclaration', kind: 'var',
    declarations: node.declarations.map(d => ({ type: 'VariableDeclarator', id: id(d.id.name), init: null }))
  };
  const out = [hoist];
  for (const d of node.declarations) {
    if (d.init) out.push({
      type: 'ExpressionStatement',
      expression: { type: 'AssignmentExpression', operator: '=', left: id(d.id.name), right: d.init }
    });
  }
  return out;
}

function rewriteSelfRefVars(ast) {
  walk(ast, node => {
    for (const key of ['body', 'consequent']) {
      const arr = node[key];
      if (!Array.isArray(arr)) continue;
      let i = 0;
      while (i < arr.length) {
        if (selfRefVar(arr[i])) {
          const repl = splitVar(arr[i]);
          arr.splice(i, 1, ...repl);
          i += repl.length;
        } else i++;
      }
    }
  });
}

// ── Rewrite A: arguments -> rest param ───────────────────────────────────────────────────────────
// Determine, for a given non-arrow function, the `arguments` references that belong to IT
// (not to a nested non-arrow function). Returns the list of Identifier nodes named 'arguments'.
function collectOwnArguments(fnBody) {
  const refs = [];
  let nestedDepth = 0;
  (function rec(node) {
    if (!node || typeof node.type !== 'string') return;
    const entersNew = isFn(node); // nested non-arrow gets its own `arguments`
    if (entersNew) nestedDepth++;
    if (!entersNew || nestedDepth === 0) {
      if (node.type === 'Identifier' && node.name === 'arguments' && nestedDepth === 0) refs.push(node);
    }
    for (const k of Object.keys(node)) {
      if (k === 'type' || k === 'start' || k === 'end' || k === 'loc' || k === 'range') continue;
      const v = node[k];
      if (Array.isArray(v)) for (const c of v) (c && typeof c.type === 'string') && rec(c);
      else if (v && typeof v.type === 'string') rec(v);
    }
    if (entersNew) nestedDepth--;
  })(fnBody);
  return refs;
}

function rewriteArguments(ast) {
  let counter = 0;
  const fns = [];
  walk(ast, n => { if (isFn(n)) fns.push(n); });
  for (const fn of fns) {
    // skip if already has a rest param
    if (fn.params.some(p => p.type === 'RestElement')) continue;
    const refs = collectOwnArguments(fn.body);
    if (refs.length === 0) continue;
    // bail if `arguments` is assigned to (rare, unsupported)
    let unsafe = false;
    walk(fn.body, (n, parent) => {
      if (n.type === 'Identifier' && n.name === 'arguments') {
        if (parent && parent.type === 'AssignmentExpression' && parent.left === n) unsafe = true;
        if (parent && parent.type === 'UpdateExpression') unsafe = true;
      }
    });
    if (unsafe) continue;
    // `arguments` is indexed from 0 over ALL passed args (including those bound to named params),
    // so a trailing rest param only aligns indices when there are NO named params. When named params
    // exist, absorb them into the rest: replace all params with `...__argsN` and prepend
    // `const <p> = __argsN[k];` bindings (only simple Identifier params are supported; bail otherwise).
    const name = '__args' + (counter++);
    if (fn.params.length === 0) {
      fn.params.push({ type: 'RestElement', argument: id(name) });
    } else {
      if (!fn.params.every(p => p.type === 'Identifier')) continue; // patterns/defaults: leave alone
      const binds = fn.params.map((p, k) => ({
        type: 'VariableDeclaration', kind: 'let',
        declarations: [{
          type: 'VariableDeclarator', id: id(p.name),
          init: { type: 'MemberExpression', computed: true, object: id(name),
                  property: { type: 'Literal', value: k }, optional: false },
        }],
      }));
      // body must be a BlockStatement to prepend bindings
      if (fn.body.type !== 'BlockStatement') continue;
      fn.params = [{ type: 'RestElement', argument: id(name) }];
      fn.body.body.unshift(...binds);
    }
    for (const r of refs) r.name = name;
  }
}

// ── Rewrite B: compound-assign + logical codegen fix ─────────────────────────────────────────────
const LOGICALish = n => n && (n.type === 'LogicalExpression' || n.type === 'ConditionalExpression');

// flatten a `+` BinaryExpression chain into an ordered operand list
function flattenPlus(node, out) {
  if (node.type === 'BinaryExpression' && node.operator === '+') {
    flattenPlus(node.left, out);
    flattenPlus(node.right, out);
  } else out.push(node);
}

// does subtree contain an Identifier named `name`?
function referencesVar(node, name) {
  let found = false;
  walk(node, n => { if (n.type === 'Identifier' && n.name === name) found = true; });
  return found;
}

// Porffor 0.61 miscompiles a `+=`/`+`-chain in a loop whenever ANY operand is a Logical or
// Conditional expression (the short-circuit/branch operand caches a stale loop-carried value),
// regardless of which variable it references. Trigger whenever such an operand is present.
function needsHoist(operands /*, name */) {
  return operands.some(op => LOGICALish(op));
}

// Rewrite a statement `x += RHS` -> [ const t0=…; … ; x = x + t0 + … ; ] when triggered.
// Returns an array of replacement statements, or null to leave unchanged.
function rewriteCompound(stmt, mkTemp) {
  if (stmt.type !== 'ExpressionStatement') return null;
  const e = stmt.expression;
  if (!e || e.type !== 'AssignmentExpression' || e.operator !== '+=') return null;
  if (e.left.type !== 'Identifier') return null;
  const name = e.left.name; // retained for the flat-assign target identifier

  const operands = [];
  flattenPlus(e.right, operands);
  if (!needsHoist(operands)) return null;

  const pre = [];
  const finalOps = operands.map(op => {
    if (LOGICALish(op)) {
      const t = mkTemp();
      pre.push({
        type: 'VariableDeclaration', kind: 'const',
        declarations: [{ type: 'VariableDeclarator', id: id(t), init: op }],
      });
      return id(t);
    }
    return op;
  });

  // build flat left-assoc chain:  x + finalOps[0] + finalOps[1] + …
  let chain = e.left; // start from x
  for (const op of finalOps) {
    chain = { type: 'BinaryExpression', operator: '+', left: chain, right: op };
  }
  const assign = {
    type: 'ExpressionStatement',
    expression: { type: 'AssignmentExpression', operator: '=', left: id(name), right: chain },
  };
  return [...pre, assign];
}

// walk every statement-list container and splice in rewrites
function rewriteCompoundAll(ast) {
  let counter = 0;
  const mkTemp = () => '__cat' + (counter++);
  function visitBlock(list) {
    for (let i = 0; i < list.length; i++) {
      const s = list[i];
      const repl = rewriteCompound(s, mkTemp);
      if (repl) { list.splice(i, 1, ...repl); i += repl.length - 1; }
    }
  }
  // For single-statement bodies (e.g. `if(c) n += …` with no braces) the statement lives directly on
  // a parent slot, not in a body[] array. If it needs rewriting (which produces multiple statements),
  // wrap it in a BlockStatement and rewrite within.
  function wrapSlot(parent, key) {
    const s = parent[key];
    if (!s || s.type !== 'ExpressionStatement') return;
    const repl = rewriteCompound(s, mkTemp);
    if (repl) parent[key] = { type: 'BlockStatement', body: repl };
  }
  walk(ast, n => {
    if (n.type === 'BlockStatement' || n.type === 'Program') visitBlock(n.body);
    else if (n.type === 'SwitchCase') visitBlock(n.consequent);
    else if (n.type === 'IfStatement') { wrapSlot(n, 'consequent'); if (n.alternate) wrapSlot(n, 'alternate'); }
    else if (n.type === 'ForStatement' || n.type === 'ForInStatement' ||
             n.type === 'ForOfStatement' || n.type === 'WhileStatement' ||
             n.type === 'DoWhileStatement') wrapSlot(n, 'body');
  });
}

function transform(src) {
  const ast = parse(src);
  rewriteArguments(ast);
  rewriteCompoundAll(ast);
  rewriteSelfRefVars(ast);
  return generate(ast);
}

function main() {
  const fs = require('fs');
  const file = process.argv[2];
  const src = fs.readFileSync(file, 'utf8');
  let out;
  try { out = transform(src); } catch (_) { out = src; }
  process.stdout.write(out);
}

if (require.main === module) main();
module.exports = { transform };
