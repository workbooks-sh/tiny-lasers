/* Spread-into-call pre-pass for the Porffor lane.
 *
 * Porffor 0.61 handles spread into user functions and ordinary (non-comptime) builtins via an
 * 8-slot expansion, but spread into a *comptime* builtin (Math.max / Math.min) reaches the comptime
 * generator with a raw SpreadElement in `decl.arguments` => "porffor: no generation for SpreadElement".
 * The 8-slot path also can't help comptime builtins (it would read out-of-bounds undefined slots).
 *
 * This pass rewrites the comptime-min/max spread forms into a runtime `reduce`, which is correct for
 * ANY element count and any (static or dynamic) array:
 *
 *   Math.max(...arr)            -> (arr).reduce((__a,__b)=> __a>__b?__a:__b, -Infinity)
 *   Math.min(...arr)            -> (arr).reduce((__a,__b)=> __a<__b?__a:__b,  Infinity)
 *   Math.max(x, ...arr, y)      -> ([x].concat(arr, [y])).reduce(... , -Infinity)
 *
 * Every other spread (user funcs, array/object literals, ordinary builtins) is left untouched — those
 * already compile correctly. On any error the source is returned unchanged (safe fallback).
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

const id = name => ({ type: 'Identifier', name });
const lit = value => ({ type: 'Literal', value });

// -Infinity / Infinity as UnaryExpression / Identifier (astring-friendly)
const negInf = () => ({ type: 'UnaryExpression', operator: '-', prefix: true, argument: id('Infinity') });
const posInf = () => id('Infinity');

// reducer arrow: (__a,__b) => __a OP __b ? __a : __b
function reducer(op) {
  return {
    type: 'ArrowFunctionExpression', params: [id('__mr_a'), id('__mr_b')], expression: true, async: false, generator: false,
    body: {
      type: 'ConditionalExpression',
      test: { type: 'BinaryExpression', operator: op, left: id('__mr_a'), right: id('__mr_b') },
      consequent: id('__mr_a'), alternate: id('__mr_b')
    }
  };
}

// Build a single array expression from the call arguments, turning spreads into .concat segments.
// Returns an AST node that evaluates to a plain array of all the numbers.
function argsToArray(args) {
  // Fast path: exactly one arg and it's a spread -> just the spread argument (already an array/iterable)
  if (args.length === 1 && args[0].type === 'SpreadElement') return args[0].argument;

  // General: head literal elements until first spread, then .concat the rest
  // [a, b].concat(spreadArg, [c], spreadArg2, ...)
  const segments = [];
  let current = [];
  for (const a of args) {
    if (a.type === 'SpreadElement') {
      if (current.length) { segments.push({ type: 'ArrayExpression', elements: current }); current = []; }
      segments.push(a.argument);
    } else {
      current.push(a);
    }
  }
  if (current.length) segments.push({ type: 'ArrayExpression', elements: current });

  if (segments.length === 1) return segments[0].type === 'ArrayExpression' ? segments[0] : segments[0];
  const base = segments[0].type === 'ArrayExpression' ? segments[0] : { type: 'ArrayExpression', elements: [] };
  const rest = segments[0].type === 'ArrayExpression' ? segments.slice(1) : segments;
  return {
    type: 'CallExpression', optional: false,
    callee: { type: 'MemberExpression', computed: false, optional: false, object: base, property: id('concat') },
    arguments: rest
  };
}

function makeReduce(arrNode, op, init) {
  return {
    type: 'CallExpression', optional: false,
    callee: { type: 'MemberExpression', computed: false, optional: false, object: arrNode, property: id('reduce') },
    arguments: [reducer(op), init]
  };
}

// is callee Math.max / Math.min ?
function mathExtreme(callee) {
  if (!callee || callee.type !== 'MemberExpression' || callee.computed) return null;
  if (callee.object.type !== 'Identifier' || callee.object.name !== 'Math') return null;
  if (callee.property.type !== 'Identifier') return null;
  if (callee.property.name === 'max') return { op: '>', init: negInf() };
  if (callee.property.name === 'min') return { op: '<', init: posInf() };
  return null;
}

function hasSpread(args) { return args.some(a => a.type === 'SpreadElement'); }

function walk(node, visit) {
  if (!node || typeof node !== 'object') return;
  visit(node);
  for (const k in node) {
    if (k === 'type' || k[0] === '_') continue;
    const v = node[k];
    if (Array.isArray(v)) { for (const c of v) if (c && typeof c.type === 'string') walk(c, visit); }
    else if (v && typeof v.type === 'string') walk(v, visit);
  }
}

// is callee  <expr>.replace / <expr>.replaceAll  with non-regexp string args?
// We only desugar when the search arg is NOT a regexp literal and the replacement
// is NOT a function (the broken-but-common string,string form). Otherwise leave it.
function replaceKind(node) {
  const c = node.callee;
  if (!c || c.type !== 'MemberExpression' || c.computed) return null;
  if (c.property.type !== 'Identifier') return null;
  const name = c.property.name;
  if (name !== 'replace' && name !== 'replaceAll') return null;
  const args = node.arguments;
  if (args.length < 2) return null;
  if (args.some(a => a.type === 'SpreadElement')) return null;
  const search = args[0], repl = args[1];
  // skip regexp search (RegExp literal or `new RegExp`) and function replacement
  if (search.type === 'Literal' && search.regex) return null;
  if (repl.type === 'ArrowFunctionExpression' || repl.type === 'FunctionExpression') return null;
  return { all: name === 'replaceAll', object: c.object, search, repl };
}

// <expr>.replace(/re/g, "literal") — Porffor's native regexp replace is broken, but split+join is
// equivalent for a GLOBAL regex with a plain-string replacement (no $ backrefs / no function): the
// working `.split(regex)` + `.join(str)` compose, e.g. 'a1b2c3'.split(/[0-9]/).join('#') = 'a#b#c#'.
function regexReplaceKind(node) {
  const c = node.callee;
  if (!c || c.type !== 'MemberExpression' || c.computed) return null;
  if (c.property.type !== 'Identifier' || c.property.name !== 'replace') return null;
  const args = node.arguments;
  if (args.length < 2) return null;
  const search = args[0], repl = args[1];
  if (!(search.type === 'Literal' && search.regex && /g/.test(search.regex.flags))) return null;
  if (repl.type !== 'Literal' || typeof repl.value !== 'string') return null;
  if (/\$[0-9&$`']/.test(repl.value)) return null; // $-backref/special — leave to native
  return { object: c.object, search, repl };
}

// <expr>.replace(/re/.../, fn) — function replacer. Porffor's native regex-replace throws on a
// function replacement, but exec-loop + capture groups + .apply all work, so we rewrite to a helper
// that walks matches and calls fn(match, g1..gn, index, str), rebuilding the string. Handles global
// (all matches) and non-global (first only). The fn stays a normal arrow/function so closure_convert
// downstream can lift any captured outer vars. Bails (returns null) on unsupported shapes.
function regexReplaceFnKind(node) {
  const c = node.callee;
  if (!c || c.type !== 'MemberExpression' || c.computed) return null;
  if (c.property.type !== 'Identifier' || c.property.name !== 'replace') return null;
  const args = node.arguments;
  if (args.length !== 2) return null;
  if (args.some(a => a.type === 'SpreadElement')) return null;
  const search = args[0], repl = args[1];
  // search must be a regexp literal; repl must be callable: an inline function/arrow, OR a reference
  // (Identifier / member) we can pass through — the helper dispatches whatever it receives and rejects
  // a non-function at runtime, matching native semantics. We explicitly reject a string/regex/literal
  // repl so the string-replacement paths keep owning those.
  if (!(search.type === 'Literal' && search.regex)) return null;
  const fnLike = repl.type === 'ArrowFunctionExpression' || repl.type === 'FunctionExpression';
  const refLike = repl.type === 'Identifier' || repl.type === 'MemberExpression';
  if (!fnLike && !refLike) return null;
  return { object: c.object, search, repl };
}

// __porf_replace_fn(str, regex, fn): regex replace with a FUNCTION replacer, via exec-loop.
// Calls fn(match, g1..gn, index, str) and concatenates the gaps; honors the /g flag (all vs first)
// and advances past zero-length matches to avoid an infinite loop.
const REPLACE_FN_HELPER = `function __porf_replace_fn(__s, __re, __fn){
  if (__s !== null && typeof __s === 'object') {
    var __om = __s.replace;
    if (__om) {
      if (__om.__clo) return __om.__method ? __om.fn(__om.env, __s, __re, __fn) : __om.fn(__om.env, __re, __fn);
      if (typeof __om === 'function') return __om(__re, __fn);
    }
  }
  __s = '' + __s;
  var __g = (__re.flags.indexOf('g') >= 0);
  var __out = ''; var __last = 0; var __m;
  __re.lastIndex = 0;
  while ((__m = __re.exec(__s)) !== null) {
    var __idx = __m.index;
    __out = __out + __s.slice(__last, __idx);
    var __args = [];
    var __n = __m.length; var __j = 0;
    while (__j < __n) { __args.push(__m[__j]); __j = __j + 1; }
    __args.push(__idx);
    __args.push(__s);
    var __rep = (__fn && __fn.__clo) ? __fn.fn.apply(__fn.env, [__fn.env].concat(__args))
                                     : __fn.apply(undefined, __args);
    __out = __out + ('' + __rep);
    var __mlen = ('' + __m[0]).length;
    __last = __idx + __mlen;
    if (!__g) break;
    if (__mlen === 0) { __re.lastIndex = __re.lastIndex + 1; }
  }
  __out = __out + __s.slice(__last);
  return __out;
}`;

// __porf_rrep(str, regex, replStr): regex search + template-aware string replacement. The old split+join
// shortcut silently DROPPED $-templates ($1/$&/$\`/$'/$$), so a marked edit() like .replace(h,"$1") emitted
// the literal "$1" and corrupted the built grammar regex. This does the real exec-loop with $-expansion
// (mirrors __porf_replace_fn) and never mutates the caller's regex (works on a private global clone).
const REPLACE_RREP_HELPER = `function __porf_rrep(__s, __re, __r){
  __s = '' + __s; __r = '' + __r;
  var __g = ('' + __re.flags).indexOf('g') >= 0;
  var __re2 = __g ? __re : new RegExp(__re.source, ('' + __re.flags) + 'g');
  __re2.lastIndex = 0;
  var __out = ''; var __last = 0; var __m; var __prev = -1;
  while ((__m = __re2.exec(__s)) !== null) {
    var __idx = __m.index;
    __out = __out + __s.slice(__last, __idx);
    var __m0 = '' + __m[0];
    var __mlen = __m0.length;
    var __ncap = __m.length - 1;
    var __k = 0; var __rl = __r.length;
    while (__k < __rl) {
      var __c = __r.charCodeAt(__k);
      if (__c === 36 && __k + 1 < __rl) {
        var __c2 = __r.charCodeAt(__k + 1);
        if (__c2 === 36) { __out = __out + '$'; __k = __k + 2; continue; }
        if (__c2 === 38) { __out = __out + __m0; __k = __k + 2; continue; }
        if (__c2 === 96) { __out = __out + __s.slice(0, __idx); __k = __k + 2; continue; }
        if (__c2 === 39) { __out = __out + __s.slice(__idx + __mlen); __k = __k + 2; continue; }
        if (__c2 >= 48 && __c2 <= 57) {
          var __num = __c2 - 48; var __adv = 2;
          if (__k + 2 < __rl) {
            var __c3 = __r.charCodeAt(__k + 2);
            if (__c3 >= 48 && __c3 <= 57) {
              var __two = (__c2 - 48) * 10 + (__c3 - 48);
              if (__two >= 1 && __two <= __ncap) { __num = __two; __adv = 3; }
            }
          }
          if (__num >= 1 && __num <= __ncap) {
            var __cap = __m[__num];
            if (__cap !== undefined && __cap !== null) __out = __out + ('' + __cap);
            __k = __k + __adv; continue;
          }
          __out = __out + '$'; __k = __k + 1; continue;
        }
      }
      __out = __out + __r.charAt(__k); __k = __k + 1;
    }
    __last = __idx + __mlen;
    if (!__g) break;
    // Never depend on exec() advancing lastIndex (the engine leaves it stuck for some patterns). Force
    // strict forward progress: next scan starts beyond this match's end AND beyond the previous floor.
    var __next = __idx + __mlen;
    if (__mlen === 0 && __idx + 1 > __next) __next = __idx + 1;
    if (__next <= __prev) __next = __prev + 1;
    __prev = __next;
    __re2.lastIndex = __next;
  }
  __out = __out + __s.slice(__last);
  return __out;
}`;

// __porf_replace(str, search, repl, all): first-or-all literal-string replacement,
// implemented with indexOf/slice/concat (all of which work in Porffor 0.61).
const REPLACE_HELPER = `function __porf_replace(__s, __q, __r, __all){
  if (__s !== null && typeof __s === 'object') {
    var __m = __s.replace;
    if (__m) {
      if (__m.__clo) return __m.__method ? __m.fn(__m.env, __s, __q, __r) : __m.fn(__m.env, __q, __r);
      if (typeof __m === 'function') return __m(__q, __r);
    }
  }
  // The search may be a RegExp held in a VARIABLE (spread_desugar can't see that statically and routed it
  // here as a literal-string replace). Detect it at runtime and do a regex replacement instead — coercing a
  // regex to a string and indexOf-ing it would never match (e.g. marked's edit().replace(/punct/g, cls)).
  if (__q !== null && typeof __q === 'object' && __q.source !== undefined && __q.exec) {
    return __porf_rrep('' + __s, __q, '' + __r);
  }
  __s = '' + __s; __q = '' + __q; __r = '' + __r;
  if (__q === '') return __all ? __s : (__r + __s);
  var __out = ''; var __from = 0;
  while (true) {
    var __i = __s.indexOf(__q, __from);
    if (__i < 0) { __out = __out + __s.slice(__from); break; }
    __out = __out + __s.slice(__from, __i) + __r;
    __from = __i + __q.length;
    if (!__all) { __out = __out + __s.slice(__from); break; }
  }
  return __out;
}`;

// __porf_replace_re(str, regex, replStr): regex search + plain-string replacement. For a real string we
// use the proven split+join equivalence (Porffor's native regex-replace path is avoided here); for an
// object receiver with its own .replace (e.g. marked's edit() chain box) we delegate to that method with
// the ORIGINAL regex so its internal semantics apply.
const REPLACE_RE_HELPER = `function __porf_replace_re(__s, __re, __r){
  if (__s !== null && typeof __s === 'object') {
    var __m = __s.replace;
    if (__m) {
      if (__m.__clo) return __m.__method ? __m.fn(__m.env, __s, __re, __r) : __m.fn(__m.env, __re, __r);
      if (typeof __m === 'function') return __m(__re, __r);
    }
  }
  return __porf_rrep('' + __s, __re, '' + __r);
}`;

// --- spread-into-call hoist (rollup root gap) ---
// Porffor's native spread expansion (codegen.js:2635) types the spread argument by calling getNodeType on
// the SAME expression it already generated; for a CallExpression whose type is dynamic (e.g. a chained
// `.map()`), getNodeType RE-EVALUATES it — running it twice and dropping the spread elements. Proven:
// `a.push(...g().map(f))` yields 0, `var t=g().map(f); a.push(...t)` yields the right count. So hoist a
// CallExpression spread argument (in an always-evaluated statement position) to a temp var, then spread the
// temp (a plain Identifier types statically, no re-eval). This is what unblocks rollup's getChunkAssignments
// `chunkDefinitions.push(...getOptimizedChunks(...).map(...))` — without it generate() produces ZERO chunks.
let __sdSpreadCounter = 0;
function topLevelSpreadCall(stmt) {
  let expr = null;
  if (stmt.type === 'ExpressionStatement') expr = stmt.expression;
  else if (stmt.type === 'ReturnStatement') expr = stmt.argument;
  else if (stmt.type === 'VariableDeclaration' && stmt.declarations.length === 1) expr = stmt.declarations[0].init;
  if (!expr || expr.type !== 'CallExpression' || !expr.arguments.length) return null;
  const last = expr.arguments[expr.arguments.length - 1];
  if (last.type === 'SpreadElement' && last.argument.type === 'CallExpression') return expr;
  return null;
}
function hoistBody(stmts) {
  const out = [];
  for (const stmt of stmts) {
    const call = topLevelSpreadCall(stmt);
    if (call) {
      const sp = call.arguments[call.arguments.length - 1];
      const name = '__sd_spread_' + (__sdSpreadCounter++);
      out.push({ type: 'VariableDeclaration', kind: 'var', declarations: [
        { type: 'VariableDeclarator', id: id(name), init: sp.argument }
      ]});
      sp.argument = id(name);
    }
    out.push(stmt);
  }
  return out;
}
function hoistSpreads(node) {
  if (!node || typeof node !== 'object') return;
  if (Array.isArray(node)) { for (const c of node) hoistSpreads(c); return; }
  if (Array.isArray(node.body)) node.body = hoistBody(node.body);
  if (Array.isArray(node.consequent)) node.consequent = hoistBody(node.consequent); // SwitchCase
  for (const k in node) {
    if (k === 'type' || k === 'start' || k === 'end') continue;
    const v = node[k];
    if (v && typeof v === 'object') hoistSpreads(v);
  }
}

function transform(src) {
  let ast;
  try { ast = parse(src); } catch (_) { return src; }
  try {
    let usedReplace = false;
    let usedReplaceFn = false;
    let usedReplaceRe = false;
    walk(ast, node => {
      if (node.type !== 'CallExpression') return;

      // Math.max/min spread -> reduce
      const m = mathExtreme(node.callee);
      if (m && hasSpread(node.arguments)) {
        const arr = argsToArray(node.arguments);
        const reduced = makeReduce(arr, m.op, m.init);
        for (const k of Object.keys(node)) delete node[k];
        Object.assign(node, reduced);
        return;
      }

      // <expr>.replace(/re/g, "str") -> <expr>.split(/re/).join("str")
      const grk = regexReplaceKind(node);
      if (grk) {
        // <expr>.replace(/re/g, "str") -> __porf_replace_re(<expr>, /re/g, "str"). The helper does
        // split+join for a real string (the proven equivalence) and delegates to a custom .replace for an
        // object receiver (marked's edit() box), so we no longer assume <expr> is a string.
        usedReplaceRe = true;
        const call = {
          type: 'CallExpression', optional: false, callee: id('__porf_replace_re'),
          arguments: [grk.object, grk.search, grk.repl]
        };
        for (const k of Object.keys(node)) delete node[k];
        Object.assign(node, call);
        return;
      }

      // <expr>.replace(/re/.../, fn) -> __porf_replace_fn(<expr>, /re/.../, fn)
      const fnk = regexReplaceFnKind(node);
      if (fnk) {
        usedReplaceFn = true;
        const call = {
          type: 'CallExpression', optional: false, callee: id('__porf_replace_fn'),
          arguments: [fnk.object, fnk.search, fnk.repl]
        };
        for (const k of Object.keys(node)) delete node[k];
        Object.assign(node, call);
        return;
      }

      // String#replace / replaceAll (string,string) -> __porf_replace(...)
      const rk = replaceKind(node);
      if (rk) {
        usedReplace = true;
        const call = {
          type: 'CallExpression', optional: false, callee: id('__porf_replace'),
          arguments: [rk.object, rk.search, rk.repl, lit(rk.all)]
        };
        for (const k of Object.keys(node)) delete node[k];
        Object.assign(node, call);
      }
    });

    hoistSpreads(ast);

    let out = generate(ast);
    if (usedReplaceFn) out = REPLACE_FN_HELPER + '\n' + out;
    if (usedReplaceRe) out = REPLACE_RE_HELPER + '\n' + out;
    if (usedReplace) out = REPLACE_HELPER + '\n' + out;
    // __porf_rrep backs the regex-search paths in both __porf_replace_re and __porf_replace.
    if (usedReplaceRe || usedReplace) out = REPLACE_RREP_HELPER + '\n' + out;
    return out;
  } catch (_) {
    return src;
  }
}

module.exports = { transform };

if (require.main === module) {
  const fs = require('fs');
  const input = fs.readFileSync(process.argv[2] || 0, 'utf8');
  process.stdout.write(transform(input));
}
