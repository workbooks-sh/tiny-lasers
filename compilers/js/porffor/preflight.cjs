/* AST preflight scanner — detect known seams BEFORE transforms/compile.
 * stdout: one JSON line {warnings:[{code,detail,loc?}], hard_block: bool}
 */
const acorn = require('./node_modules/acorn');

function parse(src) {
  for (const sourceType of ['module', 'script']) {
    try {
      return acorn.parse(src, { ecmaVersion: 2023, sourceType, locations: true, allowReturnOutsideFunction: true });
    } catch (_) {}
  }
  throw new Error('parse failed');
}

const isFunc = n => n && (n.type === 'FunctionDeclaration' || n.type === 'FunctionExpression' ||
  n.type === 'ArrowFunctionExpression');

function walk(node, visit, state) {
  if (!node || typeof node !== 'object') return;
  if (Array.isArray(node)) { for (const c of node) walk(c, visit, state); return; }
  if (typeof node.type !== 'string') return;
  visit(node, state);
  for (const k of Object.keys(node)) {
    if (k === 'type' || k[0] === '_') continue;
    walk(node[k], visit, state);
  }
}

function inAsyncFn(node, asyncFns) {
  return asyncFns.has(node);
}

function scanAwaitBail(ast) {
  const warnings = [];
  const asyncFns = new Set();
  walk(ast, (node, _s) => {
    if (isFunc(node) && node.async) asyncFns.add(node);
  }, null);

  walk(ast, (node, _s) => {
    if (node.type !== 'AwaitExpression') return;
    const p = node;
    let cur = p;
    let parent = null;
    // find parent by re-walking with parent tracking
  }, null);

  // parent-aware walk for await
  (function aw(n, parent, inAsync) {
    if (!n || typeof n !== 'object') return;
    if (Array.isArray(n)) { for (const c of n) aw(c, n, inAsync); return; }
    if (typeof n.type !== 'string') return;
    let nextAsync = inAsync;
    if (isFunc(n)) nextAsync = n.async ? n : false;
    if (n.type === 'AwaitExpression' && inAsync) {
      const ok =
        (parent && parent.type === 'ExpressionStatement' && parent.expression === n) ||
        (parent && parent.type === 'VariableDeclarator' && parent.init === n) ||
        (parent && parent.type === 'AssignmentExpression' && parent.right === n) ||
        (parent && parent.type === 'ReturnStatement' && parent.argument === n);
      if (!ok) {
        warnings.push({ code: 'async_bail', detail: 'await used outside supported statement position (CPS transform will bail)' });
      }
    }
    for (const k of Object.keys(n)) {
      if (k === 'type' || k[0] === '_') continue;
      aw(n[k], n, nextAsync);
    }
  })(ast, null, false);

  return warnings;
}

function scanGeneratorBail(ast) {
  const warnings = [];
  walk(ast, (node, _s) => {
    if (node.type !== 'YieldExpression') return;
    const p = node;
    // statement-position yield only
  }, null);

  (function yw(n, parent, inGen) {
    if (!n || typeof n !== 'object') return;
    if (Array.isArray(n)) { for (const c of n) yw(c, n, inGen); return; }
    if (typeof n.type !== 'string') return;
    let nextGen = inGen;
    if (isFunc(n) && n.generator) nextGen = n;
    if (n.type === 'YieldExpression' && inGen) {
      const stmtOk = parent && parent.type === 'ExpressionStatement' && parent.expression === n;
      if (!stmtOk) {
        warnings.push({ code: 'generator_bail', detail: 'yield used in value position (eager generator transform will bail this function)' });
      }
      if (n.argument && n.argument.type === 'YieldExpression') {
        warnings.push({ code: 'generator_bail', detail: 'nested yield expression' });
      }
    }
    for (const k of Object.keys(n)) {
      if (k === 'type' || k[0] === '_') continue;
      yw(n[k], n, nextGen);
    }
  })(ast, null, false);

  return warnings;
}

function scan(src) {
  const warnings = [];
  let ast;
  try { ast = parse(src); } catch (e) {
    return { warnings: [{ code: 'parse_error', detail: String(e.message || e) }], hard_block: false };
  }

  walk(ast, (node, _s) => {
    if (node.type === 'CallExpression' && node.callee.type === 'Identifier') {
      if (node.callee.name === 'eval') {
        warnings.push({ code: 'hard_unsupported', detail: 'eval() is not supported (AOT compiler)' });
      }
    }
    if (node.type === 'NewExpression' && node.callee.type === 'Identifier' && node.callee.name === 'Function') {
      warnings.push({ code: 'hard_unsupported', detail: 'new Function() is not supported (AOT compiler)' });
    }
    if (node.type === 'ImportDeclaration' || node.type === 'ExportNamedDeclaration' ||
        node.type === 'ExportDefaultDeclaration' || node.type === 'ExportAllDeclaration') {
      warnings.push({ code: 'module', detail: 'ES module syntax not wired on the single-program lane' });
    }
  }, null);

  if (/\bTemporal\b/.test(src)) {
    warnings.push({ code: 'temporal', detail: 'Temporal API referenced (not implemented)' });
  }

  warnings.push(...scanAwaitBail(ast));
  warnings.push(...scanGeneratorBail(ast));

  const hard_block = warnings.some(w => w.code === 'hard_unsupported');
  // de-dup
  const seen = new Set();
  const uniq = [];
  for (const w of warnings) {
    const k = w.code + '|' + w.detail;
    if (!seen.has(k)) { seen.add(k); uniq.push(w); }
  }
  return { warnings: uniq, hard_block };
}

function main() {
  const fs = require('fs');
  const path = process.argv[2];
  if (!path) {
    process.stderr.write('usage: node preflight.cjs <file.js>\n');
    process.exit(2);
  }
  const src = fs.readFileSync(path, 'utf8');
  const res = scan(src);
  process.stdout.write(JSON.stringify(res) + '\n');
  process.exit(0);
}

if (require.main === module) main();
module.exports = { scan };
