import type {} from './porffor.d.ts';

export const __ecma262_NewPromiseReactionJob = (reaction: any[], argument: any): any[] => {
  const job: any[] = Porffor.malloc(32);
  job[0] = reaction;
  job[1] = argument;

  return job;
};

const jobQueue: any[] = [];
export const __ecma262_HostEnqueuePromiseJob = (job: any[]): void => {
  Porffor.array.fastPush(jobQueue, job);
};

// Context for the currently-running combinator reaction handler — set by runJobs immediately before each
// (synchronous, non-reentrant) handler call. Combinator handlers read it instead of capturing locals (builtins
// can't capture, can't take a builtin fn as a call arg, and can't be called with a 2nd arg — that changes the
// indirect-call signature and breaks normal 1-arg .then handlers).
let __combineCtx: any;

// 27.2.1.8 TriggerPromiseReactions (reactions, argument)
// https://tc39.es/ecma262/#sec-triggerpromisereactions
export const __ecma262_TriggerPromiseReactions = (reactions: any[], argument: any): void => {
  // 1. For each element reaction of reactions, do
  for (const reaction of reactions) {
    // a. Let job be NewPromiseReactionJob(reaction, argument).
    // b. Perform HostEnqueuePromiseJob(job.[[Job]], job.[[Realm]]).
    __ecma262_HostEnqueuePromiseJob(__ecma262_NewPromiseReactionJob(reaction, argument));
  }

  // 2. Return unused.
};


// 27.2.1.6 IsPromise (x)
// https://tc39.es/ecma262/#sec-ispromise
export const __ecma262_IsPromise = (x: any): boolean => {
  // custom impl
  return Porffor.type(x) == Porffor.TYPES.promise;
};

// 27.2.1.4 FulfillPromise (promise, value)
// https://tc39.es/ecma262/#sec-fulfillpromise
export const __ecma262_FulfillPromise = (promise: any[], value: any): void => {
  // 1. Assert: The value of promise.[[PromiseState]] is pending.
  if (promise[1] != 0) return;

  // 2. Let reactions be promise.[[PromiseFulfillReactions]].
  const reactions: any[] = promise[2]; // fulfillReactions

  // 3. Set promise.[[PromiseResult]] to value.
  promise[0] = value;

  // 4. Set promise.[[PromiseFulfillReactions]] to undefined.
  promise[2] = undefined;

  // 5. Set promise.[[PromiseRejectReactions]] to undefined.
  promise[3] = undefined;

  // 6. Set promise.[[PromiseState]] to fulfilled.
  promise[1] = 1;

  // 7. Perform TriggerPromiseReactions(reactions, value).
  __ecma262_TriggerPromiseReactions(reactions, value);

  // 8. Return unused.
};

// 27.2.1.7 RejectPromise (promise, reason)
// https://tc39.es/ecma262/#sec-rejectpromise
export const __ecma262_RejectPromise = (promise: any[], reason: any): void => {
  // 1. Assert: The value of promise.[[PromiseState]] is pending.
  if (promise[1] != 0) return;

  // 2. Let reactions be promise.[[PromiseRejectReactions]].
  const reactions: any[] = promise[3]; // rejectReactions

  // 3. Set promise.[[PromiseResult]] to reason.
  promise[0] = reason;

  // 4. Set promise.[[PromiseFulfillReactions]] to undefined.
  promise[2] = undefined;

  // 5. Set promise.[[PromiseRejectReactions]] to undefined.
  promise[3] = undefined;

  // 6. Set promise.[[PromiseState]] to rejected.
  promise[1] = 2;

  // 7. If promise.[[PromiseIsHandled]] is false, perform HostPromiseRejectionTracker(promise, "reject").
  // unimplemented

  // 8. Perform TriggerPromiseReactions(reactions, reason).
  __ecma262_TriggerPromiseReactions(reactions, reason);

  // 9. Return unused.
};


export const __Porffor_promise_noop = (x: any): any => x;

// A reaction handler is callable if it is a real function OR a closure_convert box {__clo:1, env, fn}. A
// capturing user callback (`.then(v => p.tag = v)`) is boxed into an OBJECT, so the plain `type == function`
// check rejected it (silently → noop) and the reaction never fired. Accept the box here; runJob dispatches it.
export const __Porffor_promise_callable = (v: any): boolean => {
  if (Porffor.type(v) == Porffor.TYPES.function) return true;
  if (Porffor.type(v) == Porffor.TYPES.object) {
    const box: object = v;
    if (box.__clo) return true;
  }
  return false;
};

export const __Porffor_promise_newReaction = (handler: any, promise: any, flags: i32): any[] => {
  // enum ReactionType { then = 0, finally = 1 }
  // 96 bytes = 6 element slots: [3] = combinator context, [4] = closure env, [5] = boxed marker.
  const out: any[] = Porffor.malloc(96);
  out[1] = promise;
  out[2] = flags;
  out[3] = undefined;
  out[4] = undefined;
  out[5] = 0;

  // UNBOX a closure_convert handler {__clo, env, fn} HERE: store the bare funcref in slot[0] (the same slot a
  // plain handler uses) and the env in slot[4]. A funcref CALLED from an array element works from a builtin;
  // a funcref read out of an OBJECT property and called traps (undefined_element). Unboxing at creation lets
  // runJob's array-slot call path invoke a captured user callback — without this, capturing `.then`/`await`
  // callbacks (real `new Promise` resolvers, async desugars) silently never fire.
  if (Porffor.type(handler) == Porffor.TYPES.object) {
    const box: object = handler;
    out[0] = box.fn;
    out[4] = box.env;
    out[5] = 1;
  } else {
    out[0] = handler;
  }

  return out;
};

export const __Porffor_then = (promise: any[], fulfillReaction: any[], rejectReaction: any[]): void => {
  const state: i32 = promise[1];

  // 27.2.5.4.1 PerformPromiseThen (promise, onFulfilled, onRejected [, resultCapability])
  // https://tc39.es/ecma262/#sec-performpromisethen

  // 9. If promise.[[PromiseState]] is pending, then
  if (state == 0) { // pending
    // a. Append fulfillReaction to promise.[[PromiseFulfillReactions]].
    const fulfillReactions: any[] = promise[2];
    Porffor.array.fastPush(fulfillReactions, fulfillReaction);

    // b. Append rejectReaction to promise.[[PromiseRejectReactions]].
    const rejectReactions: any[] = promise[3];
    Porffor.array.fastPush(rejectReactions, rejectReaction);
  } else if (state == 1) { // fulfilled
    // 10. Else if promise.[[PromiseState]] is fulfilled, then
    // a. Let value be promise.[[PromiseResult]].
    const value: any = promise[0];

    // b. Let fulfillJob be NewPromiseReactionJob(fulfillReaction, value).
    // c. Perform HostEnqueuePromiseJob(fulfillJob.[[Job]], fulfillJob.[[Realm]]).
    __ecma262_HostEnqueuePromiseJob(__ecma262_NewPromiseReactionJob(fulfillReaction, value));
  } else { // rejected
    // 11. Else,
    // a. Assert: The value of promise.[[PromiseState]] is rejected.
    // todo

    // b. Let reason be promise.[[PromiseResult]].
    const reason: any = promise[0];

    // c. If promise.[[PromiseIsHandled]] is false, perform HostPromiseRejectionTracker(promise, "handle").
    // unimplemented

    // d. Let rejectJob be NewPromiseReactionJob(rejectReaction, reason).
    // e. Perform HostEnqueuePromiseJob(rejectJob.[[Job]], rejectJob.[[Realm]]).
    __ecma262_HostEnqueuePromiseJob(__ecma262_NewPromiseReactionJob(rejectReaction, reason));
  }
};

export const __Porffor_promise_resolve = (value: any, promise: any): void => {
  // if value is own promise, reject with typeerror
  if (value === promise) throw new TypeError('cannot resolve promise with itself');

  if (__ecma262_IsPromise(value)) {
    const fulfillReaction: any[] = __Porffor_promise_newReaction(__Porffor_promise_noop, promise, 0);
    // passthrough reject (0b110): assimilating a rejected promise must re-reject the target with the reason
    const rejectReaction: any[] = __Porffor_promise_newReaction(__Porffor_promise_noop, promise, 0b110);

    __Porffor_then(value, fulfillReaction, rejectReaction);
  } else {
    __ecma262_FulfillPromise(promise, value);
  }
};

export const __Porffor_promise_reject = (reason: any, promise: any): void => {
  __ecma262_RejectPromise(promise, reason);
};

export const __Porffor_promise_create = (): any[] => {
  // Promise [ result, state, fulfillReactions, rejectReactions ]
  const obj: any[] = Porffor.malloc(64);

  // result = undefined
  obj[0] = undefined;

  // enum PromiseState { pending = 0, fulfilled = 1, rejected = 2 }
  // state = .pending
  obj[1] = 0;

  // fulfillReactions = []
  const fulfillReactions: any[] = Porffor.malloc(512);
  obj[2] = fulfillReactions;

  // rejectReactions = []
  const rejectReactions: any[] = Porffor.malloc(512);
  obj[3] = rejectReactions;

  return obj;
};

// A fresh pending promise typed as `Promise` (so `.then` etc. dispatch). Used by the `new Promise` desugar,
// which binds `res`/`rej` as USER-LEVEL closures over this specific promise — sidestepping the builtin
// `activePromise` global (which mis-bound an async `res()` to the most-recently-constructed promise).
export const __Porffor_promise_new = (): Promise => __Porffor_promise_create() as Promise;

export const __Porffor_promise_runNext = (func: Function): void => {
  const reaction: any[] = __Porffor_promise_newReaction(func, undefined, 1);
  __ecma262_HostEnqueuePromiseJob(__ecma262_NewPromiseReactionJob(reaction, undefined));
};

// Run a single queued reaction job (the body of the microtask loop; also reused by blocking await to drain).
export const __Porffor_promise_runJob = (x: any): void => {
  const reaction: any[] = x[0];
  const handler: any = reaction[0];
  const outPromise: any = reaction[1];
  const flags: i32 = reaction[2];

  const value: any = x[1];

  // todo: handle thrown errors in handler?
  let outValue: any;
  // handler (slot[0]) is always a bare funcref — newReaction unboxed any closure_convert box, putting its env
  // in slot[4] and a marker in slot[5]. A captured callback's boxed fn takes a leading __env param.
  const boxed: i32 = reaction[5];
  const henv: any = reaction[4];
  if (flags & 0b01) { // finally reaction
    if (boxed) handler(henv);
    else handler();
    outValue = value;
  } else { // then reaction
    __combineCtx = reaction[3]; // undefined for normal reactions; the per-call ctx for combinator reactions
    if (boxed) outValue = handler(henv, value);
    else outValue = handler(value);
  }

  // After a handler runs and returns normally the result is RESOLVED with its return value — for a fulfill
  // reaction AND for a recovering reject handler (`.catch(e => v)` settles the chain with v). Only a
  // PASSTHROUGH reject reaction (0b100: no real onRejected, or promise-assimilation) re-rejects, propagating
  // the original reason. (Handlers that THROW should reject too — not yet modeled; see todo above.)
  if (outPromise) if (flags & 0b100) {
    __Porffor_promise_reject(outValue, outPromise); // passthrough: re-reject with reason
  } else {
    __Porffor_promise_resolve(outValue, outPromise); // ran a handler (or fulfill): resolve with result
  }
};

export const __Porffor_promise_runJobs = (): void => {
  while (true) {
    let x: any = jobQueue.shift();
    if (x == null) break;
    __Porffor_promise_runJob(x);
  }
};

// The resolve/reject functions handed to a Promise executor must bind to THAT promise — a global
// `activePromise` mis-bound an async `res()` to the most-recently-constructed promise (two interleaved
// `new Promise`s, `withResolvers`, every real-async resolver). Builtins can't run closure_convert, but a
// closure_convert BOX is just a plain object {__clo:1, env, fn}: we hand-build one here with env = the
// promise and fn = a bound resolver. User code calling `res(v)` dispatches `res.__clo ? res.fn(res.env, v)`
// — and a funcref read from an object property and called from USER code works fine. So per-promise binding
// is exact without any shared global.
export const __Porffor_promise_resolveBound = (env: any, value: any): void => __Porffor_promise_resolve(value, env);
export const __Porffor_promise_rejectBound = (env: any, reason: any): void => __Porffor_promise_reject(reason, env);

export const __Porffor_promise_makeResolver = (promise: any, fn: any): object => {
  const box: object = {};
  box.__clo = 1;
  box.env = promise;
  box.fn = fn;
  return box;
};

export const Promise = function (executor: any): Promise {
  if (!new.target) throw new TypeError("Constructor Promise requires 'new'");

  // A capturing executor (`new Promise((res, rej) => { ...captures... })`) closure_converts to a BOX
  // {__clo, env, fn} whose Porffor.type is object, not function — accept it. Same array-slot dispatch the
  // resolver/reaction machinery uses: a funcref read from an OBJECT property and called from a builtin traps
  // (undefined_element), but one stashed into an ARRAY element and called from there works.
  let boxed: i32 = 0;
  if (Porffor.type(executor) == Porffor.TYPES.object) {
    if (executor.__clo) boxed = 1;
  }
  if (Porffor.type(executor) != Porffor.TYPES.function && !boxed) throw new TypeError('Promise executor is not a function');

  const obj: any[] = __Porffor_promise_create();
  const res: object = __Porffor_promise_makeResolver(obj, __Porffor_promise_resolveBound);
  const rej: object = __Porffor_promise_makeResolver(obj, __Porffor_promise_rejectBound);

  try {
    if (boxed) {
      const box: object = executor;
      const slot: any[] = Porffor.malloc(16);
      slot[0] = box.fn;        // bare funcref into an array slot (callable from a builtin)
      const f: any = slot[0];
      f(box.env, res, rej);    // boxed fn takes a leading __env param
    } else {
      executor(res, rej);
    }
  } catch (e) {
    // executor threw, reject promise
    __ecma262_RejectPromise(obj, e);
  }

  return obj as Promise;
};

export const __Promise_withResolvers = (): object => {
  const obj: any[] = __Porffor_promise_create();

  const out: object = Porffor.malloc();
  out.promise = obj as Promise;

  out.resolve = __Porffor_promise_makeResolver(obj, __Porffor_promise_resolveBound);
  out.reject = __Porffor_promise_makeResolver(obj, __Porffor_promise_rejectBound);

  return out;
};

export const __Promise_resolve = (value: any): Promise => {
  // 27.2.5.3: if x is already a (native) promise, return it UNCHANGED — no new wrapper. Double-wrapping a
  // resolved promise (`Promise.resolve(Promise.resolve())`, the async→then desugar of `await aPromise`)
  // would otherwise cost an extra unwrap microtask and push the continuation one tick late vs node.
  if (Porffor.type(value) == Porffor.TYPES.promise) return value as Promise;

  const obj: any[] = __Porffor_promise_create();

  __Porffor_promise_resolve(value, obj);

  return obj as Promise;
};

export const __Promise_reject = (reason: any): Promise => {
  const obj: any[] = __Porffor_promise_create();

  __Porffor_promise_reject(reason, obj);

  return obj as Promise;
};


// 27.2.5.4 Promise.prototype.then (onFulfilled, onRejected)
// https://tc39.es/ecma262/#sec-promise.prototype.then
export const __Promise_prototype_then = (_this: any, onFulfilled: any, onRejected: any) => {
  // 1. Let promise be the this value.
  // 2. If IsPromise(promise) is false, throw a TypeError exception.
  if (!__ecma262_IsPromise(_this)) throw new TypeError('Promise.prototype.then called on non-Promise');

  if (!__Porffor_promise_callable(onFulfilled)) onFulfilled = __Porffor_promise_noop;

  // flags bit 0b100 = "passthrough/Thrower": no real onRejected, so a source rejection must propagate
  // (re-reject the result with the same reason). A REAL onRejected handler that returns normally is a
  // RECOVERY and must RESOLVE the result with its return value (flags 0b10 alone) — see runJob.
  let rejFlags: i32 = 2;
  if (!__Porffor_promise_callable(onRejected)) {
    onRejected = __Porffor_promise_noop;
    rejFlags = 0b110; // reject reaction + passthrough
  }

  const outPromise: any[] = __Porffor_promise_create();

  const fulfillReaction: any[] = __Porffor_promise_newReaction(onFulfilled, outPromise, 0);
  const rejectReaction: any[] = __Porffor_promise_newReaction(onRejected, outPromise, rejFlags);

  __Porffor_then(_this, fulfillReaction, rejectReaction);

  return outPromise as Promise;
};

// 27.2.5.1 Promise.prototype.catch (onRejected)
// https://tc39.es/ecma262/#sec-promise.prototype.catch
export const __Promise_prototype_catch = (_this: any, onRejected: any) => {
  // 1. Let promise be the this value.
  // 2. Return ? Invoke(promise, "then", « undefined, onRejected »).
  return __Promise_prototype_then(_this, undefined, onRejected);
};

export const __Promise_prototype_finally = (_this: any, onFinally: any) => {
  // custom impl based on then but also not (sorry)
  if (!__ecma262_IsPromise(_this)) throw new TypeError('Promise.prototype.then called on non-Promise');

  if (Porffor.type(onFinally) != Porffor.TYPES.function) onFinally = __Porffor_promise_noop;

  const promise: any[] = _this;
  const state: i32 = promise[1];

  const outPromise: any[] = __Porffor_promise_create();

  const finallyReaction: any[] = __Porffor_promise_newReaction(onFinally, outPromise, 1);

  if (state == 0) { // pending
    const fulfillReactions: any[] = promise[2];
    Porffor.array.fastPush(fulfillReactions, finallyReaction);

    const rejectReactions: any[] = promise[3];
    Porffor.array.fastPush(rejectReactions, finallyReaction);
  } else { // fulfilled or rejected
    const value: any = promise[0];
    __ecma262_HostEnqueuePromiseJob(__ecma262_NewPromiseReactionJob(finallyReaction, value));
  }

  return outPromise as Promise;
};


// commentary: its as 🦐shrimple🦐 as this
// hack: cannot share scope so use a global
//    ^ multiple Promise.all(-like)s are glitchy because of this

// Combinator state in a per-call array threaded to each input promise's reaction via reaction[3], read by a
// kind-based dispatcher through __combineCtx. state = [out, remaining, outPromise, settledFlag, kind].
export const __Porffor_combine_onF = (value: any): any => {
  const ctx: any[] = __combineCtx;
  const state: any[] = ctx[0];
  const kind: i32 = state[4];
  const out: any[] = state[0];
  const idx: i32 = ctx[1];
  if (kind == 3 || kind == 2) { // race / any: first fulfilment wins
    if (state[3] == 0) { state[3] = 1; __Porffor_promise_resolve(value, state[2]); }
    return undefined;
  }
  if (kind == 1) { const o: object = {}; o.status = 'fulfilled'; o.value = value; out[idx] = o; } // allSettled
  else out[idx] = value; // all
  state[1] = state[1] - 1;
  if (state[1] == 0 && state[3] == 0) { state[3] = 1; __Porffor_promise_resolve(out, state[2]); }
  return undefined;
};

export const __Porffor_combine_onR = (reason: any): any => {
  const ctx: any[] = __combineCtx;
  const state: any[] = ctx[0];
  const kind: i32 = state[4];
  const out: any[] = state[0];
  const idx: i32 = ctx[1];
  if (kind == 3 || kind == 0) { // race / all: first rejection rejects
    if (state[3] == 0) { state[3] = 1; __Porffor_promise_reject(reason, state[2]); }
    return undefined;
  }
  if (kind == 1) { // allSettled
    const o: object = {}; o.status = 'rejected'; o.reason = reason; out[idx] = o;
    state[1] = state[1] - 1;
    if (state[1] == 0) { state[3] = 1; __Porffor_promise_resolve(out, state[2]); }
  } else { // any: collect rejections, AggregateError when all reject
    out[idx] = reason;
    state[1] = state[1] - 1;
    if (state[1] == 0 && state[3] == 0) { state[3] = 1; __Porffor_promise_reject(new AggregateError(out), state[2]); }
  }
  return undefined;
};

export const __Porffor_combine = (promises: any, kind: i32): Promise => {
  const outPromise: any[] = __Porffor_promise_create();
  const out: any[] = Porffor.malloc(512);
  const state: any[] = Porffor.malloc(128); // 5 slots × 16 bytes/element, with headroom
  state[0] = out; state[1] = 0; state[2] = outPromise; state[3] = 0; state[4] = kind;
  let len: i32 = 0;
  for (const x of promises) {
    const idx: i32 = len;
    len++;
    out[idx] = undefined;
    out.length = len;
    state[1] = state[1] + 1;
    let px: any[];
    if (__ecma262_IsPromise(x)) { px = x; }
    else { px = __Porffor_promise_create(); __ecma262_FulfillPromise(px, x); }
    const ctx: any[] = Porffor.malloc(64); // 2 slots × 16 bytes/element, with headroom
    ctx[0] = state; ctx[1] = idx;
    const fr: any[] = __Porffor_promise_newReaction(__Porffor_combine_onF, undefined, 0);
    fr[3] = ctx;
    const rr: any[] = __Porffor_promise_newReaction(__Porffor_combine_onR, undefined, 0);
    rr[3] = ctx;
    __Porffor_then(px, fr, rr);
  }
  if (len == 0) {
    if (kind == 0 || kind == 1) __ecma262_FulfillPromise(outPromise, out);
    else if (kind == 2) __Porffor_promise_reject(new AggregateError(out), outPromise);
    // race([]) stays pending
  }
  return outPromise as Promise;
};
export const __Promise_all = (promises: any): Promise => __Porffor_combine(promises, 0);
export const __Promise_allSettled = (promises: any): Promise => __Porffor_combine(promises, 1);
export const __Promise_any = (promises: any): Promise => __Porffor_combine(promises, 2);
export const __Promise_race = (promises: any): Promise => __Porffor_combine(promises, 3);

// export const __Promise_try = function (cb: any, ...args: any[]) { return new this(res => res(cb(...args))) };
export const __Promise_try = async (cb: any, ...args: any[]) => cb(...args);

export const __Promise_prototype_toString = (_this: any) => '[object Promise]';
export const __Promise_prototype_toLocaleString = (_this: any) => __Promise_prototype_toString(_this);


export const __Porffor_promise_await = (value: any): any => {
  if (Porffor.type(value) != Porffor.TYPES.promise) return value;

  // Blocking await: drive the microtask queue until THIS promise settles, then return its real value. Unlike
  // a true suspending await it does not yield to the caller (so cross-async microtask ORDER differs from node —
  // tracked; the proper fix is a BEAM-fiber await parked via atomic.wait), but awaited values resolve correctly
  // — which is what a deterministic pipeline like Rollup needs for byte-identical output.
  let guard: i32 = 0;
  while ((value as any[])[1] == 0) { // pending
    const x: any = jobQueue.shift();
    if (x == null) break; // queue drained but still pending — nothing left to resolve it
    __Porffor_promise_runJob(x);
    if (++guard > 100000000) break; // safety bound
  }

  const state: i32 = (value as any[])[1];
  const result: any = (value as any[])[0];
  if (state == 1) return result; // fulfilled
  if (state == 2) throw result; // rejected
  return value; // still pending (unresolvable) — fall back to the value
};
