/* Per-pass semantic oracle: node(source) vs node(pass(source)) on a corpus file/dir.
 * Usage: node transform_oracle.cjs [--pass NAME] <file.js|dir>
 */
const cp = require('child_process');
const fs = require('fs');
const path = require('path');

const PASSES = [
  'arguments_desugar.cjs', 'map_desugar.cjs', 'spread_desugar.cjs', 'async_transform.cjs',
  'generator_transform.cjs', 'destructure_desugar.cjs', 'optional_call_desugar.cjs', 'closure_convert.cjs'
];

function nodeOut(src) {
  const f = path.join(require('os').tmpdir(), 'xform_oracle_' + process.pid + '_' + Math.random().toString(36).slice(2) + '.js');
  try {
    fs.writeFileSync(f, 'Promise.resolve(0)/*drv*/;\n' + src);
    return cp.execSync('node ' + f, { encoding: 'utf8', timeout: 15000, stdio: ['pipe', 'pipe', 'pipe'] }).trim();
  } catch (e) {
    return 'NODE_ERR:' + (e.status || '');
  } finally {
    try { fs.unlinkSync(f); } catch (_) {}
  }
}

function applyPass(src, passName) {
  const m = require('./' + passName);
  const fn = m.transform || m;
  const tmp = path.join(require('os').tmpdir(), 'xform_in_' + process.pid + '.js');
  fs.writeFileSync(tmp, src);
  try {
    const out = fn(fs.readFileSync(tmp, 'utf8'));
    return typeof out === 'string' && out.length > 0 ? out : src;
  } finally {
    try { fs.unlinkSync(tmp); } catch (_) {}
  }
}

function checkFile(file, onlyPass) {
  const src = fs.readFileSync(file, 'utf8');
  const base = nodeOut(src);
  const passes = onlyPass ? [onlyPass + (onlyPass.endsWith('.cjs') ? '' : '.cjs')] : PASSES;
  let diffs = 0;
  for (const p of passes) {
    if (!fs.existsSync(path.join(__dirname, p))) continue;
    let next;
    try { next = applyPass(src, p); } catch (e) { console.log(`  ${p}: TRANSFORM_THROW`); diffs++; continue; }
    const out = nodeOut(next);
    if (out !== base) {
      console.log(`  DIFF ${p}: base=${base.slice(0,40)} out=${out.slice(0,40)}`);
      diffs++;
    } else {
      console.log(`  OK   ${p}`);
    }
  }
  return diffs;
}

function main() {
  const args = process.argv.slice(2);
  const passIdx = args.indexOf('--pass');
  const onlyPass = passIdx >= 0 ? args[passIdx + 1] : null;
  const target = args.find(a => !a.startsWith('--') && a !== onlyPass);
  if (!target) {
    console.error('usage: node transform_oracle.cjs [--pass NAME] <file.js>');
    process.exit(2);
  }
  const diffs = checkFile(target, onlyPass);
  process.exit(diffs > 0 ? 1 : 0);
}
main();
