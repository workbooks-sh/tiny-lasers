import type {} from './porffor.d.ts';

// `eval` is invalid syntax so work around
export const _eval = (source: string) => {
  throw new SyntaxError('Dynamic code evaluation is not supported');
};

export const Function = function (source: string) {
  throw new SyntaxError('Dynamic code evaluation is not supported');
};

export const __Function_prototype_toString = (_this: Function) => {
  const out: bytestring = Porffor.malloc(256);

  Porffor.bytestring.appendStr(out, 'function ');
  Porffor.bytestring.appendStr(out, __Porffor_funcLut_name(_this));
  Porffor.bytestring.appendStr(out, '() { [native code] }');
  return out;
};

export const __Function_prototype_toLocaleString = (_this: Function) => __Function_prototype_toString(_this);

export const __Function_prototype_apply = (_this: Function, thisArg: any, argsArray: any) => {
  return Porffor.call(_this, Array.from(argsArray ?? []) as any[], thisArg, null);
};

export const __Function_prototype_call = (_this: Function, thisArg: any, ...args: any[]) => {
  // `fn.call(thisArg, a, b, …)` = invoke fn with `this`=thisArg and the rest as positional args.
  // Mirrors apply but the args arrive spread (rest param) instead of as one array. Exposing this builtin
  // also makes `Function.prototype.call` resolve to a real funcref (was undefined) — the uncurry-this idiom
  // `Function.prototype.call.bind(SomeMethod)` in test262's propertyHelper.js depends on it.
  // KNOWN GAP (deep, tracked in bd porffor-bind-uncurry-state): reached INDIRECTLY through the uncurry
  // (Function.prototype.call.bind(method) -> bound box -> apply -> Porffor.call(FP.call, [thisArg,...args],
  // receiver)), this builtin's OWN args arrive MIS-ALIGNED — measured: a string thisArg gives args.length 0,
  // an object thisArg gives args.length 1 but args[0] is a wrong number not the real arg. Every user-code
  // equivalent works; only a builtin WITH a _this receiver param, invoked indirectly with a spread, packs
  // its positional args wrong. A nested-indirect-call ABI defect. Direct fn.call(...) is special-cased + ok.
  return Porffor.call(_this, args, thisArg, null);
};

export const __Function_prototype_bind = (_this: Function, thisArg: any, argsArray: any) => {
  // Fallback only: closure_convert lowers `fn.bind(thisArg)` (incl. global native methods) to a BOUND BOX
  // {__clo,__bound,bthis,fn} that the call-site dispatch re-invokes as `fn.apply(bthis,args)` — that source
  // path is the real bind. This builtin is reached only for forms the rewrite skips (e.g. `bind()` no-arg or
  // curried multi-arg binds); leave it as identity rather than returning a box the call sites won't dispatch.
  return _this;
};


export const __Porffor_generateArgumentsObject = (argc: i32, hasRest: boolean, ...args: any[]) => {
  let obj: object = {}, i: i32 = 0, limit: i32 = args.length;
  if (hasRest) limit--;
  limit = Math.min(argc, limit);

  while (i < limit) {
    obj[i] = args[i];
    i++;
  }

  if (hasRest) {
    const rest: any[] = args[limit];
    const len: i32 = rest.length;
    for (let j: i32 = 0; j < len; j++) {
      obj[i] = rest[j];
      i++;
    }
  }

  obj.length = i;
  return obj;
};