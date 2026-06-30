// acorn parser rung — JS source → AST fingerprint. Prepended with cjs_prelude + acorn bundle.
// Each line: `label=<value>` where value is a deterministic parse summary (node type + child count).
const acorn = module.exports;
const parse = acorn.parse;

function summary(node) {
  if (!node || typeof node !== "object") return String(node);
  var kids = 0;
  for (var k in node) {
    if (k === "type" || k === "start" || k === "end" || k === "loc") continue;
    var v = node[k];
    if (v && typeof v === "object") {
      if (Array.isArray(v)) kids += v.length;
      else if (v.type) kids += 1;
    }
  }
  return node.type + ":" + kids;
}

function probe(label, src, opts) {
  opts = opts || { ecmaVersion: 2023, sourceType: "script" };
  try {
    var ast = parse(src, opts);
    console.log(label + "=" + summary(ast.body && ast.body[0] ? ast.body[0] : ast));
    if (ast.body && ast.body.length > 1) {
      console.log(label + "_n=" + ast.body.length);
    }
  } catch (e) {
    console.log(label + "=ERR:" + e.message.split("\n")[0]);
  }
}

probe("var", "var x = 1 + 2;");
probe("let", "let y = 3 * 4;");
probe("const", "const z = 5;");
probe("fn", "function f(a, b) { return a + b; }");
probe("arrow", "const g = (x) => x * 2;");
probe("class", "class A { m() { return 1; } }");
probe("for", "for (let i = 0; i < 3; i++) { x++; }");
probe("while", "while (x > 0) { x--; }");
probe("if", "if (x) { y(); } else { z(); }");
probe("try", "try { x(); } catch (e) { y(e); } finally { z(); }");
probe("import", "import { x } from 'm';", { ecmaVersion: 2023, sourceType: "module" });
probe("export", "export const x = 1;", { ecmaVersion: 2023, sourceType: "module" });
probe("tpl", "const s = `hello ${name}!`;");
probe("regex", "const r = /foo\\d+/gi;");
probe("bigint", "const n = 123n + 1n;");
probe("spread", "const a = [...xs, y];");
probe("yield", "function* gen() { yield 1; yield* other; }");
probe("async", "async function h() { await p; }");
probe("unicode_id", "const π = 3.14;");
probe("regex_ctor", "const r = new RegExp('[a-z]+', 'gi');");
