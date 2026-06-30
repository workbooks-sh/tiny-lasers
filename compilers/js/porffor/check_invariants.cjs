/* Run the full transform pipeline + cc_invariants on a JS program.
 * stdout: one JSON line {ok, violations:[{inv,where,detail}]}
 * exit 0 if ok, 1 if violations, 2 on parse/transform error.
 */
const fs = require('fs');
const { check } = require('./cc_invariants.cjs');

const PASSES = [
  'arguments_desugar.cjs',
  'map_desugar.cjs',
  'spread_desugar.cjs',
  'async_transform.cjs',
  'generator_transform.cjs',
  'destructure_desugar.cjs',
  'optional_call_desugar.cjs',
  'closure_convert.cjs',
];

function driveAsync(source) {
  if (/\basync\b|\bawait\b|\.then\s*\(|\bPromise\b/.test(source) &&
      !source.includes('Promise.resolve(0)/*drv*/')) {
    return 'Promise.resolve(0)/*drv*/;\n' + source;
  }
  return source;
}

function transform(src) {
  let s = driveAsync(src);
  process.env.CC_INVARIANTS = '1';
  try {
    for (const p of PASSES) {
      const m = require('./' + p);
      const fn = m.transform || m;
      const next = fn(s);
      if (typeof next === 'string' && next.length > 0) s = next;
    }
    return s;
  } finally {
    delete process.env.CC_INVARIANTS;
  }
}

function main() {
  const path = process.argv[2];
  const checkOnly = process.argv.includes('--transformed');
  if (!path) {
    process.stderr.write('usage: node check_invariants.cjs <file.js>\n');
    process.exit(2);
  }
  const src = fs.readFileSync(path, 'utf8');
  let xformed;
  try {
    xformed = checkOnly ? src : transform(src);
  } catch (e) {
    process.stdout.write(JSON.stringify({ ok: false, error: String(e.message || e), violations: [] }) + '\n');
    process.exit(2);
  }
  const res = check(xformed);
  // `ok` reflects VIOLATIONS only (warnings — e.g. the over-reporting INV-LOOP-FRESH heuristic — surface
  // but never block; the sound CC_INVARIANTS construction-time check is the real gate for that bug class).
  process.stdout.write(JSON.stringify({ ok: res.ok, violations: res.violations, warnings: res.warnings || [] }) + '\n');
  process.exit(res.ok ? 0 : 1);
}

main();
