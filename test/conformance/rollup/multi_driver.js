// multi-module rung driver — appended AFTER rollup_bundle.cjs (reuses its top-level `rollup` binding).
// Four virtual modules with a 3-deep import chain; every module carries dead exports so the output proves
// CROSS-MODULE treeshaking, scope hoisting, and name handling. Golden: rollup_multi_golden.js (real
// rollup@4.62.2 under node — scratch goldengen/gen.js evals this same file).
var files = {
  "entry": [
    'import { greet, farewell } from "./lib.js";',
    'import { VERSION } from "./meta.js";',
    'const who = "world";',
    'export const msg = greet(who) + " " + farewell(who) + VERSION;',
    'console.log(msg);'
  ].join("\n"),
  "./lib.js": [
    'import { upper, punct } from "./util.js";',
    'export function greet(n) { return "hi " + upper(n) + punct; }',
    'export function farewell(n) { return "bye " + n; }',
    'export function neverUsed() { return "DEAD CODE"; }'
  ].join("\n"),
  "./util.js": [
    'export const upper = (s) => s.toUpperCase();',
    'export const punct = "!";',
    'export const deadConst = 42;'
  ].join("\n"),
  "./meta.js": [
    'export const VERSION = "@v1";',
    'export function alsoDead() { return deadHelper(); }',
    'function deadHelper() { return 0; }'
  ].join("\n")
};
var multiVirt = { name: "multi", resolveId(id) { return id in files ? id : null; }, load(id) { return id in files ? files[id] : null; } };
rollup.rollup({ input: "entry", plugins: [multiVirt], treeshake: true }).then((b) => b.generate({ format: "cjs" })).then(({ output }) => console.log("MULTI_OK[" + output[0].code + "]")).catch((e) => console.log("MULTI_ERR " + (e && e.stack ? e.stack : e)));
