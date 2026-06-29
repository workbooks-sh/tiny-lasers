/* Mechanical small-scope program generator for closure conversion.
 *
 * Methodology method #3: don't hand-pick test inputs — ENUMERATE all programs over
 * {scope kind} × {capture kind} × {call site} at small scope, run each through the transform pipeline +
 * cc_invariants (+ the node oracle), and report a coverage matrix. This turns "closed at the cases we
 * thought of" into "closed at small scope": it produces lc/mg AND the native-capture cases automatically,
 * and surfaces the SEAMS (combinations the static checker misses but node ≠ ASM would catch) before any real
 * bundle does.
 *
 *   node cc_generate.cjs              → print the coverage matrix (combination → checker-clean? · node value)
 *   node cc_generate.cjs --emit DIR   → also write each program to DIR/<name>.js + a line-based expectations
 *                                        file DIR/_expected.txt (`name<TAB>base64(program)<TAB>node-output`)
 *                                        for the Elixir ASM≡node corpus runner. (No JSON — line format.)
 *
 * Each generated program is self-contained and ends in a single deterministic `console.log`, so the node
 * oracle is exact and the ASM lane can be diffed against it.
 */
const cp = require('child_process');
const fs = require('fs');
const PASSES = ['map_desugar', 'spread_desugar', 'async_transform', 'generator_transform',
  'destructure_desugar', 'optional_call_desugar', 'closure_convert'];
const { check } = require('./cc_invariants.cjs');

// ── dimensions ──
// A "capture" describes what the inner closure closes over and the body that exercises it. Each returns the
// fragment that DECLARES the captured datum + an expression `read(i)` the closure uses for element i, and the
// expected per-element value. We build a loop that creates one closure per element and reads them back, so
// per-iteration freshness is observable (closures must NOT collapse to the last value).
const CAPTURES = {
  // outer const declared OUTSIDE the loop, shared (one value) — closures all see it (correct)
  outer_const: { decl: 'var base = 100;', perIter: false, inner: 'base', expectAll: '100' },
  // function parameter, shared
  param: { param: 'p', decl: '', perIter: false, inner: 'p', expectAll: 'P' },
  // loop CONTROL var — per-iteration (ES let-per-iteration)
  loop_control: { perIter: true, useControl: true, inner: '__x', expect: i => String(i) },
  // loop-BODY const — per-iteration
  loop_body_const: { perIter: true, body: 'const t = __x;', inner: 't', expect: i => String(i) },
  // loop-body let mutated — per-iteration binding but reassigned in body
  loop_body_let: { perIter: true, body: 'let t = __x * 2;', inner: 't', expect: i => String(i * 2) },
};
// how the inner closure is shaped (affects boxing + this-threading)
const SCOPES = {
  arrow: (inner) => `() => ${inner}`,
  func: (inner) => `function(){ return ${inner}; }`,
};
// how the produced closure is stored/invoked
const CALLSITES = {
  array_push: { collect: (mk) => `fns.push(${mk});`, read: 'fns[__i]()' },
};

// wrap dimension: function-scoped captures (the realistic, fixed case) vs MODULE/top-level (the seam —
// closure_convert treats a top-level binding as a global and leaves the closure native, so a top-level
// loop-body const is NOT made per-iteration; static checks pass but ASM ≠ node).
const WRAPS = ['function', 'toplevel'];

function gen(captureKey, scopeKey, wrap) {
  const cap = CAPTURES[captureKey];
  const mkInner = SCOPES[scopeKey](cap.inner);
  const param = cap.param ? cap.param : '';
  const arr = '[0,1,2]';
  const bodyDecl = cap.body || '';
  const expectedJoined = cap.expectAll != null
    ? [0, 1, 2].map(() => cap.expectAll).join(',')
    : [0, 1, 2].map(i => cap.expect(i)).join(',');
  const loop =
    `  var fns = [];\n` +
    `  ${cap.decl || ''}\n` +
    `  for (const __x of ${arr}) {\n` +
    `    ${bodyDecl}\n` +
    `    ${CALLSITES.array_push.collect(mkInner)}\n` +
    `  }\n` +
    `  var out = [];\n` +
    `  for (var __i = 0; __i < fns.length; __i++) out.push(${CALLSITES.array_push.read});\n`;
  let src;
  if (wrap === 'function') {
    src = `function run(${param}){\n${loop}  return out.join(",");\n}\nconsole.log(run(${cap.param ? '"P"' : ''}));\n`;
  } else {
    if (cap.param) return null; // a param needs a function
    src = `${loop}console.log(out.join(","));\n`;
  }
  return { name: `${captureKey}__${scopeKey}__${wrap}`, src, expected: expectedJoined };
}

function transform(src) {
  let s = src;
  for (const p of PASSES) { const m = require('./' + p + '.cjs'); s = (m.transform || m)(s); }
  return s;
}
let _tmpN = 0;
function nodeRun(src) {
  const f = require('os').tmpdir() + '/cc_gen_' + process.pid + '_' + (_tmpN++) + '.js';
  try { fs.writeFileSync(f, src); return cp.execSync('node ' + f, { encoding: 'utf8', timeout: 10000 }).trim(); }
  catch (e) { return 'NODE_ERR:' + (e.message || '').split('\n')[0]; }
  finally { try { fs.unlinkSync(f); } catch (_) {} }
}

function main() {
  const emitDir = process.argv.includes('--emit') ? process.argv[process.argv.indexOf('--emit') + 1] : null;
  const rows = [];
  const emit = [];
  for (const ck of Object.keys(CAPTURES)) {
    for (const sk of Object.keys(SCOPES)) {
      for (const wk of WRAPS) {
      const g = gen(ck, sk, wk);
      if (!g) continue;
      const node = nodeRun(g.src);
      let xformed, checkerClean, constructionClean;
      try {
        xformed = transform(g.src);
        checkerClean = check(xformed).ok;
        // sound construction gate (binding provenance)
        process.env.CC_INVARIANTS = '1';
        try { transform(g.src); constructionClean = true; } catch (_) { constructionClean = false; }
        delete process.env.CC_INVARIANTS;
      } catch (e) { xformed = null; checkerClean = '(transform-threw)'; constructionClean = '(threw)'; }
      const oracleOk = node === g.expected;
      rows.push({ name: g.name, expected: g.expected, node, oracleOk, checkerClean, constructionClean });
      if (emitDir) emit.push(`${g.name}\t${Buffer.from(g.src).toString('base64')}\t${node}`);
      }
    }
  }
  const pad = (s, n) => (s + ' '.repeat(n)).slice(0, n);
  console.log(pad('combination', 30) + pad('node', 10) + pad('oracle', 8) + pad('checker', 9) + 'construct');
  for (const r of rows) {
    console.log(pad(r.name, 30) + pad(r.node, 10) + pad(r.oracleOk ? 'ok' : 'DIFF', 8) +
      pad(String(r.checkerClean), 9) + String(r.constructionClean));
  }
  if (emitDir) {
    fs.mkdirSync(emitDir, { recursive: true });
    for (const ck of Object.keys(CAPTURES)) for (const sk of Object.keys(SCOPES)) for (const wk of WRAPS) {
      const g = gen(ck, sk, wk); if (g) fs.writeFileSync(`${emitDir}/${g.name}.js`, g.src);
    }
    fs.writeFileSync(`${emitDir}/_expected.txt`, emit.join('\n') + '\n');
    console.log(`\nemitted ${emit.length} programs + _expected.txt to ${emitDir}`);
  }
  const seams = rows.filter(r => r.oracleOk && r.constructionClean === true);
  // (informational) ASM≡node is the only thing that catches the top-level native-capture seam; the static
  // gates pass it. The Elixir corpus runner (--emit) closes that loop.
}
main();
