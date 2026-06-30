/* Combinatorial generator eager-expansion matrix. */
const cp = require('child_process');
const fs = require('fs');
const { check } = require('./cc_invariants.cjs');
const PASSES = ['map_desugar', 'spread_desugar', 'async_transform', 'generator_transform',
  'destructure_desugar', 'optional_call_desugar', 'closure_convert'];

const SHAPES = {
  finite_stmt: `function* g(){ yield 1; yield 2; } console.log([...g()].join(','));`,
  yield_star: `function* g(){ yield 1; yield* [2,3]; } console.log([...g()].join(','));`,
  yield_expr: `function* g(){ const x = yield 1; console.log(x); } var it=g(); it.next(); it.next(9);`,
};

function transform(src) {
  let s = src;
  for (const p of PASSES) { const m = require('./' + p + '.cjs'); s = (m.transform || m)(s); }
  return s;
}

function nodeRun(src) {
  const f = require('os').tmpdir() + '/gen_gen_' + process.pid + '.js';
  try { fs.writeFileSync(f, src); return cp.execSync('node ' + f, { encoding: 'utf8', timeout: 10000 }).trim(); }
  catch (e) { return 'NODE_ERR'; }
  finally { try { fs.unlinkSync(f); } catch (_) {} }
}

function main() {
  const emitDir = process.argv.includes('--emit') ? process.argv[process.argv.indexOf('--emit') + 1] : null;
  for (const [name, src] of Object.entries(SHAPES)) {
    const node = nodeRun(src);
    let inv = '?';
    try { inv = check(transform(src)).ok; } catch (_) { inv = 'throw'; }
    const bail = name === 'yield_expr';
    console.log(`${name.padEnd(20)} node=${node.padEnd(12)} inv=${String(inv).padEnd(5)} gen_bail=${bail}`);
    if (emitDir) { fs.mkdirSync(emitDir, { recursive: true }); fs.writeFileSync(`${emitDir}/${name}.js`, src); }
  }
}
main();
