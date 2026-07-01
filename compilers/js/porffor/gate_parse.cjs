// F2 frontend seam: JS source -> acorn ESTree AST -> JSON on stdout. Reused Porffor parser dep (acorn).
const acorn = require('acorn');
const src = require('fs').readFileSync(process.argv[2], 'utf8');
try {
  const ast = acorn.parse(src, { ecmaVersion: 2022, sourceType: 'script' });
  process.stdout.write(JSON.stringify(ast));
} catch (e) { process.stderr.write('PARSE_ERR:' + e.message); process.exit(1); }
