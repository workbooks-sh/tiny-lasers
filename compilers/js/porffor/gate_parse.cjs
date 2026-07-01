// F2 frontend seam: JS source -> acorn ESTree AST -> JSON on stdout. Reused Porffor parser dep (acorn).
const acorn = require('acorn');
const src = require('fs').readFileSync(process.argv[2], 'utf8');
try {
  const ast = acorn.parse(src, { ecmaVersion: 2022, sourceType: 'script' });
  // BigInt literal values (`123n`) aren't JSON-serializable; tag them so the lowering can reconstruct the
  // value. acorn also puts the digits in the node's `bigint` field, but a nested BigInt anywhere would still
  // throw — the replacer makes serialization total.
  const replacer = (_k, v) => (typeof v === 'bigint' ? { $bigint: v.toString() } : v);
  process.stdout.write(JSON.stringify(ast, replacer));
} catch (e) { process.stderr.write('PARSE_ERR:' + e.message); process.exit(1); }
