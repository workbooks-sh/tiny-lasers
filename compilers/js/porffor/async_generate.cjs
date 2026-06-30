/* Combinatorial async CPS bail matrix — mirrors cc_generate.cjs pattern. */
const cp = require('child_process');
const fs = require('fs');
const PASSES = ['map_desugar', 'spread_desugar', 'async_transform', 'generator_transform',
  'destructure_desugar', 'optional_call_desugar', 'closure_convert'];
const { check } = require('./cc_invariants.cjs');

const SHAPES = {
  stmt_await: (cap) => `async function f(){ ${cap.decl} const x=await Promise.resolve(1); return ${cap.read}; }\nf().then(v=>console.log(v));`,
  expr_await: (cap) => `async function f(){ ${cap.decl} return await Promise.resolve(${cap.read}); }\nf().then(v=>console.log(v));`,
  try_await: (cap) => `async function f(){ ${cap.decl} try { const x=await Promise.resolve(2); console.log(x+${cap.read}); } catch(e){ console.log('err'); } }\nf();`,
};

const CAPTURES = {
  none: { decl: '', read: '1', expect: '1' },
  outer: { decl: 'var k=10;', read: 'k', expect: '10' },
};

function transform(src) {
  let s = 'Promise.resolve(0)/*drv*/;\n' + src;
  process.env.CC_INVARIANTS = '1';
  for (const p of PASSES) {
    const m = require('./' + p + '.cjs');
    s = (m.transform || m)(s);
  }
  delete process.env.CC_INVARIANTS;
  return s;
}

function nodeRun(src) {
  const f = require('os').tmpdir() + '/async_gen_' + process.pid + '.js';
  try { fs.writeFileSync(f, src); return cp.execSync('node ' + f, { encoding: 'utf8', timeout: 15000 }).trim(); }
  catch (e) { return 'NODE_ERR'; }
  finally { try { fs.unlinkSync(f); } catch (_) {} }
}

function main() {
  const emitDir = process.argv.includes('--emit') ? process.argv[process.argv.indexOf('--emit') + 1] : null;
  for (const sk of Object.keys(SHAPES)) {
    for (const ck of Object.keys(CAPTURES)) {
      const cap = CAPTURES[ck];
      const src = SHAPES[sk](cap);
      const name = `${sk}__${ck}`;
      const node = nodeRun(src);
      let checkerClean = '?';
      try { checkerClean = check(transform(src)).ok; } catch (_) { checkerClean = 'throw'; }
      const bail = sk === 'expr_await';
      console.log(`${name.padEnd(28)} node=${node.padEnd(8)} inv=${String(checkerClean).padEnd(5)} async_bail=${bail}`);
      if (emitDir) {
        fs.mkdirSync(emitDir, { recursive: true });
        fs.writeFileSync(`${emitDir}/${name}.js`, src);
      }
    }
  }
}
main();
