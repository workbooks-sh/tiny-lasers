/* Combinatorial destructuring + closure capture matrix. */
const cp = require('child_process');
const fs = require('fs');
const { check } = require('./cc_invariants.cjs');
const PASSES = ['map_desugar', 'spread_desugar', 'async_transform', 'generator_transform',
  'destructure_desugar', 'optional_call_desugar', 'closure_convert'];

const SHAPES = {
  flat: `function mk(){ var o={a:1,b:2}; return function(){ const {a,b}=o; return a+','+b; }; } console.log(mk()());`,
  nested: `function mk(){ var o={x:{y:3}}; return function(){ const {x:{y}}=o; return ''+y; }; } console.log(mk()());`,
  default_rest: `function mk(){ var o={a:1}; return function(){ const {a,b=9,...r}=o; return a+','+b; }; } console.log(mk()());`,
};

function transform(src) {
  let s = src;
  for (const p of PASSES) { const m = require('./' + p + '.cjs'); s = (m.transform || m)(s); }
  return s;
}

function nodeRun(src) {
  const f = require('os').tmpdir() + '/dstr_gen_' + process.pid + '.js';
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
    console.log(`${name.padEnd(16)} node=${node.padEnd(8)} inv=${inv}`);
    if (emitDir) { fs.mkdirSync(emitDir, { recursive: true }); fs.writeFileSync(`${emitDir}/${name}.js`, src); }
  }
}
main();
