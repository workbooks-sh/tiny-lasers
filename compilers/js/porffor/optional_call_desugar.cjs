/* Optional-call desugar for the Porffor lane.
 *
 * Porffor 0.61 miscompiles an optional METHOD CALL whose object is nullish:
 * `obj?.method(args)` with obj == null throws "undefined is not a function" instead of
 * short-circuiting the whole chain to undefined. (Optional MEMBER access `obj?.prop`
 * short-circuits fine, and an optional call on a DEFINED object works — only the
 * nullish-object + call combination is broken: the member short-circuits to undefined but
 * the surrounding call still invokes that undefined.) This blocked the rollup bundle at
 * `baseFileEmitter?.addOutputFileEmitter(this)` inside FileEmitter's constructor.
 *
 * Fix: rewrite the exact broken shape — a ChainExpression whose spine is a single optional
 * member that is immediately called — into an explicit nullish guard:
 *
 *   obj?.method(args)        =>  (obj == null ? undefined : obj.method(args))         // simple obj
 *   getObj()?.method(args)   =>  ((__oc0) => __oc0 == null ? undefined : __oc0.method(args))(getObj())
 *   obj?.[k](args)           =>  (obj == null ? undefined : obj[k](args))             // computed
 *
 * `this` binding is preserved (the call stays a member call on the same object). Simple objects
 * (Identifier / this) are duplicated inline (no closure); anything else is evaluated once through
 * a one-arg arrow so side effects fire exactly once. We BAIL (leave untouched) on any chain with
 * more than this single optional link — multi-link chains (`a?.b?.c()`, `a?.b().c`) are rarer and
 * Porffor's member short-circuit already covers the member-only ones. On any error the source is
 * returned UNCHANGED.
 */
const acornMod = require('acorn');
const { generate } = require('astring');

function parse(src) {
  for (const sourceType of ['module', 'script']) {
    try { return acornMod.parse(src, { ecmaVersion: 2023, sourceType, allowReturnOutsideFunction: true }); }
    catch (_) {}
  }
  throw new Error('parse failed');
}

function walk(node, parent, key, visit) {
  if (!node || typeof node !== 'object') return;
  if (Array.isArray(node)) { for (let i = 0; i < node.length; i++) walk(node[i], parent, key, visit); return; }
  if (typeof node.type !== 'string') return;
  visit(node, parent, key);
  for (const k of Object.keys(node)) {
    if (k === 'type' || k === 'start' || k === 'end' || k === 'loc' || k === 'range') continue;
    walk(node[k], node, k, visit);
  }
}

// Does this subtree contain any optional member/call link? (used to reject multi-link chains)
function hasOptional(node) {
  let found = false;
  walk(node, null, null, (n) => {
    if ((n.type === 'MemberExpression' || n.type === 'CallExpression') && n.optional) found = true;
  });
  return found;
}

const isSimpleObj = (n) => n && (n.type === 'Identifier' || n.type === 'ThisExpression' || n.type === 'Super');

function transform(src) {
  const ast = parse(src);
  let counter = 0;
  let touched = false;

  walk(ast, null, null, (node, parent, key) => {
    if (node.type !== 'ChainExpression') return;
    const call = node.expression;
    // Must be: CALL( optional-MEMBER( object, property ) ). The call's own `optional` may be
    // false (`obj?.m()`) or true; what matters is the callee member is the optional link.
    if (!call || call.type !== 'CallExpression') return;
    const callee = call.callee;
    if (!callee || callee.type !== 'MemberExpression' || !callee.optional) return;
    // Reject if anything OTHER than this one member is optional (object subtree or args).
    if (hasOptional(callee.object)) return;
    if (call.arguments.some(hasOptional)) return;

    const obj = callee.object;
    const undef = { type: 'Identifier', name: 'undefined' };

    // Build the non-optional call against a (possibly temp) object reference.
    const buildCall = (ref) => ({
      type: 'CallExpression', optional: false,
      callee: { type: 'MemberExpression', computed: callee.computed, optional: false,
                object: ref, property: callee.property },
      arguments: call.arguments
    });
    const nullishTest = (ref) => ({
      type: 'BinaryExpression', operator: '==', left: ref, right: { type: 'Literal', value: null }
    });

    let replacement;
    if (isSimpleObj(obj)) {
      // (obj == null ? undefined : obj.method(args)) — obj has no side effects, duplicate inline.
      const ref2 = JSON.parse(JSON.stringify(obj));
      replacement = { type: 'ConditionalExpression', test: nullishTest(obj),
                      consequent: undef, alternate: buildCall(ref2) };
    } else {
      // ((__ocN) => __ocN == null ? undefined : __ocN.method(args))(obj) — single eval.
      const tmp = { type: 'Identifier', name: '__oc' + (counter++) };
      const tmp2 = { type: 'Identifier', name: tmp.name };
      const tmp3 = { type: 'Identifier', name: tmp.name };
      const arrow = {
        type: 'ArrowFunctionExpression', params: [tmp], expression: true, async: false,
        body: { type: 'ConditionalExpression', test: nullishTest(tmp2), consequent: undef, alternate: buildCall(tmp3) }
      };
      replacement = { type: 'CallExpression', optional: false, callee: arrow, arguments: [obj] };
    }

    if (parent && key != null) {
      if (Array.isArray(parent[key])) { const i = parent[key].indexOf(node); if (i >= 0) parent[key][i] = replacement; }
      else parent[key] = replacement;
      touched = true;
    }
  });

  if (!touched) return src;
  return generate(ast);
}

function run() {
  const file = process.argv[2];
  const src = require('fs').readFileSync(file, 'utf8');
  let out;
  try { out = transform(src); } catch (_) { out = src; }
  process.stdout.write(out);
}

if (require.main === module) run();
module.exports = { transform };
