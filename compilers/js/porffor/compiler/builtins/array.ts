import type {} from './porffor.d.ts';

export const Array = function (...args: any[]): any[] {
  const argsLen: number = args.length;
  if (argsLen == 0) {
    // 0 args, new 0 length array
    const out: any[] = Porffor.malloc();
    return out;
  }

  if (argsLen == 1) {
    // 1 arg, length (number) or first element (non-number)
    const arg: any = args[0];
    if (Porffor.type(arg) == Porffor.TYPES.number) {
      // number so use as length
      const n: number = args[0];
      if (Porffor.fastOr(
        n < 0, // negative
        n > 4294967295, // over 2**32 - 1
        !Number.isInteger(n) // non-integer/non-finite
      )) throw new RangeError('Invalid array length');

      // size the buffer to n elements (+ a page of headroom) — arrays don't realloc, so a default 16KB page
      // (~1820 slots) corrupts neighbours once index-assigned past it. Cap at ~1MB (the allocator's max
      // single chunk) so a huge sparse `new Array(1e6)` doesn't request an impossible block.
      let abytes: i32 = 4 + (n as i32) * 9 + 65536;
      if (abytes > 1048576 || abytes < 0) abytes = 1048576;
      const out: any[] = Porffor.malloc(abytes);
      out.length = n;
      return out;
    }

    // not number, leave to fallthrough as same as >1
  }

  // >1 arg, just return args array
  return args;
};

export const __Array_isArray = (x: unknown): boolean =>
  Porffor.type(x) == Porffor.TYPES.array;

export const __Array_from = (arg: any, mapFn: any, thisArg: any = undefined): any[] => {
  if (arg == null) throw new TypeError('Argument cannot be nullish');

  let out: any[] = Porffor.malloc();

  if (Porffor.fastOr(
    Porffor.type(arg) == Porffor.TYPES.array,
    (Porffor.type(arg) | 0b10000000) == Porffor.TYPES.bytestring,
    Porffor.type(arg) == Porffor.TYPES.set,
    Porffor.fastAnd(Porffor.type(arg) >= Porffor.TYPES.uint8clampedarray, Porffor.type(arg) <= Porffor.TYPES.float64array)
  )) {
    let i: i32 = 0;
    if (Porffor.type(mapFn) != Porffor.TYPES.undefined) {
      // mapFn may be a CLOSURE BOX ({__clo,env,fn}) — an object, not a function. Dispatch it through its
      // `fn` (env first, +thisArg as __this for a __method); a funcref must be called from an ARRAY slot,
      // not read directly off the object property (a builtin traps on the latter).
      let boxed: i32 = 0;
      if (Porffor.type(mapFn) == Porffor.TYPES.object) { if (mapFn.__clo) boxed = 1; }
      if (Porffor.fastAnd(Porffor.type(mapFn) != Porffor.TYPES.function, boxed == 0)) throw new TypeError('Called Array.from with a non-function mapFn');
      const slot: any[] = Porffor.malloc(16);

      for (const x of arg) {
        if (boxed) {
          slot[0] = mapFn.fn;
          const f: any = slot[0];
          if (mapFn.__method) out[i] = f(mapFn.env, thisArg, x, i);
          else out[i] = f(mapFn.env, x, i);
        } else {
          out[i] = mapFn.call(thisArg, x, i);
        }
        i++;
      }
    } else {
      for (const x of arg) {
        out[i++] = x;
      }
    }

    out.length = i;
    return out;
  }

  if (__Porffor_object_isObject(arg)) {
    const obj: object = Porffor.type(arg) == Porffor.TYPES.object ? arg : __Porffor_object_underlying(arg);
    let len: i32 = ecma262.ToIntegerOrInfinity(obj['length']);
    if (len > 4294967295) throw new RangeError('Invalid array length');
    if (len < 0) len = 0;

    if (Porffor.type(mapFn) != Porffor.TYPES.undefined) {
      let boxed: i32 = 0;
      if (Porffor.type(mapFn) == Porffor.TYPES.object) { if (mapFn.__clo) boxed = 1; }
      if (Porffor.fastAnd(Porffor.type(mapFn) != Porffor.TYPES.function, boxed == 0)) throw new TypeError('Called Array.from with a non-function mapFn');
      const slot: any[] = Porffor.malloc(16);

      for (let i: i32 = 0; i < len; i++) {
        if (boxed) {
          slot[0] = mapFn.fn;
          const f: any = slot[0];
          if (mapFn.__method) out[i] = f(mapFn.env, thisArg, obj[i], i);
          else out[i] = f(mapFn.env, obj[i], i);
        } else {
          out[i] = mapFn.call(thisArg, obj[i], i);
        }
      }
    } else {
      for (let i: i32 = 0; i < len; i++) {
        out[i] = obj[i];
      }
    }

    out.length = len;
    return out;
  }

  return out;
};

// 23.1.3.1 Array.prototype.at (index)
// https://tc39.es/ecma262/multipage/indexed-collections.html#sec-array.prototype.at
// ── wb-9yie spill-on-overflow growth (chunk 2, slice 1) ──────────────────────────────────────────
// Arrays never realloc (raw i32 pointers + === identity ⇒ the base must never move). When an append
// overflows the array's own buffer it SPILLS into malloc'd chunks linked through the allocator's base-4
// header slot (grow-zeroed 0 = never spilled). Each chunk = i32 used @+0, i32 next @+4, then 256 nine-byte
// element slots (f64 value @+0, type byte @+8) from +16 = 2320 bytes. Defined BEFORE all callers
// (at/push/fastPush) so each emits a direct call to an already-exported callee; a callee defined after its
// caller is force-included as `internal` and dropped from the bundle ("... has no built-in").

// read an element's value+type at byte address `addr` and return it as an any. The bare two-value return
// idiom (mirrors __Porffor_object_get) ONLY compiles cleanly in a control-flow-free function — inside
// chainGet's branch/loop the same template mis-resolves. addr points at the f64 value; type byte at addr+8.
export const __Porffor_array_readAt = (addr: i32): any => {
  // value via FUNCTIONAL f64.load (template loads mis-resolve here); re-tag it with the stored type byte
  // by assigning to a correctly-typed local (Porffor tags a local from a raw pointer value the same way
  // `let a: any[] = Porffor.malloc()` does) — template-free.
  const v: f64 = Porffor.wasm.f64.load(addr, 0, 0);
  const t: i32 = Porffor.wasm.i32.load8_u(addr, 0, 8);
  if (t == Porffor.TYPES.object) { const x: object = v; return x; }
  if (t == Porffor.TYPES.array) { const x: any[] = v; return x; }
  if (t == Porffor.TYPES.string) { const x: string = v; return x; }
  if (t == Porffor.TYPES.bytestring) { const x: bytestring = v; return x; }
  if (t == Porffor.TYPES.boolean) { const x: boolean = v; return x; }
  if (t == Porffor.TYPES.function) { const x: Function = v; return x; }
  if (t == Porffor.TYPES.undefined) return undefined;
  return v; // number (and any unhandled type falls back to its f64 value)
};

// has this array spilled? base-4 holds the first chunk ptr (0 = never spilled) — one load+branch.
// GUARD: only a malloc'd array (ptr >= heapStart) carries the header. A static allocPage array sits below
// heapStart and has NO header — reading p-4 there is garbage, so report not-spilled (it can't have spilled:
// growth only happens through the malloc path). hs == 0 means no malloc has run yet ⇒ nothing has spilled.
export const __Porffor_array_hasSpilled = (arr: any[]): boolean => {
  const p: i32 = Porffor.wasm`local.get ${arr}` | 0;
  const hs: i32 = __Porffor_heap_start();
  if (Porffor.fastOr(hs == 0, p < hs)) return false;
  return Porffor.wasm.i32.load(p - 4, 0, 0) != 0;
};

// Loud gate for the structural ops (shift/unshift/splice/slice/fastRemove) that do raw in-buffer pointer
// math / memory.copy assuming contiguous storage. A spilled array's tail lives in malloc'd chunks, so those
// ops would read/write PAST the buffer and corrupt neighbour memory. They are not yet chain-aware — refuse
// loudly instead of corrupting silently (wb-9yie slice 1). Defined before all callers so the call is direct.
// Cheap: one hasSpilled load+branch, fires only on arrays that actually grew past their initial capacity.
export const __Porffor_array_guardContiguous = (arr: any[]): void => {
  if (__Porffor_array_hasSpilled(arr)) throw new RangeError('array grown past capacity: this operation is not yet chain-aware');
};

// chain-aware read of logical index → an any (value+type). returns `any` ⇒ registered [f64,i32] in precompile.
export const __Porffor_array_chainGet = (arr: any[], index: i32): any => {
  const base: i32 = Porffor.wasm`local.get ${arr}` | 0;
  const cap: i32 = (__Porffor_alloc_size(arr) - 4) / 9 | 0;
  // resolve the element's byte address `a` (in-buffer slot, or walk the spill chain), then ONE any-return
  // at the end — a single bare-return mirrors __Porffor_object_get; two of them mis-compile.
  let a: i32 = base + 4 + index * 9;
  if (index >= cap) {
    let rem: i32 = index - cap;
    let chunk: i32 = Porffor.wasm.i32.load(base - 4, 0, 0);
    while (chunk != 0 && rem >= 256) {
      rem -= 256;
      chunk = Porffor.wasm.i32.load(chunk + 4, 0, 0);
    }
    a = chunk + 16 + rem * 9;
  }
  return __Porffor_array_readAt(a);
};

// place el (value+type) at logical index, extending the spill chain as needed. returns index+1 (new len).
export const __Porffor_array_growSet = (arr: any[], index: i32, el: any): i32 => {
  const base: i32 = Porffor.wasm`local.get ${arr}` | 0;
  // GUARD: a static allocPage array (ptr < heapStart) has no malloc header, so __Porffor_alloc_size is
  // garbage here. Fall back to a plain inline store at base+4+index*9 (stride 9) — the pre-spill behaviour,
  // benign overflow into free bump space (load-bearing; static arrays never grow a chain). hs==0: no malloc
  // yet, treat as static. Callers (push/fastPush) already gate, but guard here so any caller is safe.
  const hs: i32 = __Porffor_heap_start();
  if (Porffor.fastOr(hs == 0, base < hs)) {
    const slotS: i32 = base + 4 + index * 9;
    Porffor.wasm.f64.store(slotS, el, 0, 0);
    Porffor.wasm.i32.store8(slotS, Porffor.wasm`local.get ${el+1}`, 0, 8);
    return index + 1;
  }
  const cap: i32 = (__Porffor_alloc_size(arr) - 4) / 9 | 0;
  if (index < cap) {
    const slot: i32 = base + 4 + index * 9;
    Porffor.wasm.f64.store(slot, el, 0, 0);
    Porffor.wasm.i32.store8(slot, Porffor.wasm`local.get ${el+1}`, 0, 8);
    return index + 1;
  }
  let rem: i32 = index - cap;
  let prev: i32 = base - 4;
  let chunk: i32 = Porffor.wasm.i32.load(prev, 0, 0);
  while (rem >= 256) {
    if (chunk == 0) {
      chunk = Porffor.malloc(2320);
      Porffor.wasm.i32.store(prev, chunk, 0, 0);
    }
    prev = chunk + 4;
    rem -= 256;
    chunk = Porffor.wasm.i32.load(prev, 0, 0);
  }
  if (chunk == 0) {
    chunk = Porffor.malloc(2320);
    Porffor.wasm.i32.store(prev, chunk, 0, 0);
  }
  const slot: i32 = chunk + 16 + rem * 9;
  Porffor.wasm.f64.store(slot, el, 0, 0);
  Porffor.wasm.i32.store8(slot, Porffor.wasm`local.get ${el+1}`, 0, 8);
  const used: i32 = Porffor.wasm.i32.load(chunk, 0, 0);
  if (rem + 1 > used) Porffor.wasm.i32.store(chunk, rem + 1, 0, 0);
  return index + 1;
};

// chain-aware in-place move of `count` logical elements within `arr`, overlap-safe like memmove: copy forward
// when dst < src (left shift), backward when dst > src (right shift). Every slot is addressed via
// growSet/chainGet so it spans the spill chain. Used by the structural ops (shift/unshift/splice/fastRemove).
export const __Porffor_array_chainMove = (arr: any[], dstStart: i32, srcStart: i32, count: i32): void => {
  if (count <= 0) return;
  if (dstStart < srcStart) {
    for (let k: i32 = 0; k < count; k++)
      __Porffor_array_growSet(arr, dstStart + k, __Porffor_array_chainGet(arr, srcStart + k));
  } else if (dstStart > srcStart) {
    for (let k: i32 = count - 1; k >= 0; k--)
      __Porffor_array_growSet(arr, dstStart + k, __Porffor_array_chainGet(arr, srcStart + k));
  }
};

// chain-aware copy of `count` logical elements from src[srcStart..] into a DISTINCT out[dstStart..].
// Used when building a fresh result array from a spilled source (slice/splice/with/concat/toSorted/...).
export const __Porffor_array_chainCopy = (src: any[], srcStart: i32, out: any[], dstStart: i32, count: i32): void => {
  for (let k: i32 = 0; k < count; k++)
    __Porffor_array_growSet(out, dstStart + k, __Porffor_array_chainGet(src, srcStart + k));
};

export const __Array_prototype_at = (_this: any[], index: any) => {
  // 1. Let O be ? ToObject(this value).
  // 2. Let len be ? LengthOfArrayLike(O).
  const len: i32 = _this.length;

  // 3. Let relativeIndex be ? ToIntegerOrInfinity(index).
  index = ecma262.ToIntegerOrInfinity(index);

  // 4. If relativeIndex ≥ 0, then
  //        a. Let k be relativeIndex.
  // 5. Else,
  //        a. Let k be len + relativeIndex.
  if (index < 0) index = len + index;

  // 6. If k < 0 or k ≥ len, return undefined.
  if (Porffor.fastOr(index < 0, index >= len)) return undefined;

  // 7. Return ? Get(O, ! ToString(𝔽(k))).
  if (__Porffor_array_hasSpilled(_this)) return __Porffor_array_chainGet(_this, index);
  return _this[index];
};

export const __Array_prototype_push = (_this: any[], ...items: any[]) => {
  let len: i32 = _this.length;
  const itemsLen: i32 = items.length;

  for (let i: i32 = 0; i < itemsLen; i++) {
    __Porffor_array_growSet(_this, i + len, items[i]);
  }

  return _this.length = len + itemsLen;
};

export const __Array_prototype_pop = (_this: any[]) => {
  const len: i32 = _this.length;
  if (len == 0) return undefined;

  const lastIndex: i32 = len - 1;
  // chain-aware: the last element may live in the spill chain when the array grew past its buffer.
  if (__Porffor_array_hasSpilled(_this)) {
    const spilled: any = __Porffor_array_chainGet(_this, lastIndex);
    _this.length = lastIndex;
    return spilled;
  }
  const element: any = _this[lastIndex];
  _this.length = lastIndex;

  return element;
};

export const __Array_prototype_shift = (_this: any[]) => {
  const len: i32 = _this.length;
  if (len == 0) return undefined;

  if (__Porffor_array_hasSpilled(_this)) {
    const first: any = __Porffor_array_chainGet(_this, 0);
    _this.length = len - 1;
    __Porffor_array_chainMove(_this, 0, 1, len - 1); // shift all elements left by 1
    return first;
  }

  const element: any = _this[0];
  _this.length = len - 1;

  // shift all elements left by 1 using memory.copy
  Porffor.wasm`;; ptr = ptr(_this) + 4
local #shift_ptr i32
local.get ${_this}
i32.to_u
i32.const 4
i32.add
local.set #shift_ptr

;; dst = ptr (start of array)
local.get #shift_ptr

;; src = ptr + 9 (second element)
local.get #shift_ptr
i32.const 9
i32.add

;; size = (len - 1) * 9
local.get ${len}
i32.to_u
i32.const 1
i32.sub
i32.const 9
i32.mul

memory.copy 0 0`;

  return element;
};

export const __Array_prototype_unshift = (_this: any[], ...items: any[]) => {
  let len: i32 = _this.length;
  const itemsLen: i32 = items.length;

  if (__Porffor_array_hasSpilled(_this)) {
    __Porffor_array_chainMove(_this, itemsLen, 0, len); // shift existing elements right by itemsLen
    for (let i: i32 = 0; i < itemsLen; i++) __Porffor_array_growSet(_this, i, items[i]);
    return _this.length = len + itemsLen;
  }

  // use memory.copy to move existing elements right
  Porffor.wasm`;; ptr = ptr(_this) + 4
local #splice_ptr i32
local.get ${_this}
i32.to_u
i32.const 4
i32.add
local.set #splice_ptr

;; dst = ptr + itemsLen * 9
local.get #splice_ptr
local.get ${itemsLen}
i32.to_u
i32.const 9
i32.mul
i32.add

;; src = ptr
local.get #splice_ptr

;; size = len * 9
local.get ${len}
i32.to_u
i32.const 9
i32.mul

memory.copy 0 0`;

  // write to now empty elements
  for (let i: i32 = 0; i < itemsLen; i++) {
    _this[i] = items[i];
  }

  return _this.length = len + itemsLen;
};

export const __Array_prototype_slice = (_this: any[], _start: any, _end: any) => {
  const len: i32 = _this.length;
  if (Porffor.type(_end) == Porffor.TYPES.undefined) _end = len;

  let start: i32 = ecma262.ToIntegerOrInfinity(_start);
  let end: i32 = ecma262.ToIntegerOrInfinity(_end);

  if (start < 0) {
    start = len + start;
    if (start < 0) start = 0;
  }
  if (start > len) start = len;
  if (end < 0) {
    end = len + end;
    if (end < 0) end = 0;
  }
  if (end > len) end = len;

  if (__Porffor_array_hasSpilled(_this)) {
    let outC: any[] = Porffor.malloc();
    if (start < end) {
      __Porffor_array_chainCopy(_this, start, outC, 0, end - start);
      outC.length = end - start;
    }
    return outC;
  }

  let out: any[] = Porffor.malloc();

  if (start > end) return out;

  let outPtr: i32 = Porffor.wasm`local.get ${out}`;
  let thisPtr: i32 = Porffor.wasm`local.get ${_this}`;

  const thisPtrEnd: i32 = thisPtr + end * 9;

  thisPtr += start * 9;

  while (thisPtr < thisPtrEnd) {
    Porffor.wasm.f64.store(outPtr, Porffor.wasm.f64.load(thisPtr, 0, 4), 0, 4);
    Porffor.wasm.i32.store8(outPtr, Porffor.wasm.i32.load8_u(thisPtr, 0, 12), 0, 12);

    thisPtr += 9;
    outPtr += 9;
  }

  out.length = end - start;
  return out;
};

export const __Array_prototype_splice = (_this: any[], _start: any, _deleteCount: any, ...items: any[]) => {
  const len: i32 = _this.length;

  let start: i32 = ecma262.ToIntegerOrInfinity(_start);
  if (start < 0) {
    start = len + start;
    if (start < 0) start = 0;
  }
  if (start > len) start = len;

  if (Porffor.type(_deleteCount) == Porffor.TYPES.undefined) _deleteCount = len - start;
  let deleteCount: i32 = ecma262.ToIntegerOrInfinity(_deleteCount);

  if (deleteCount < 0) deleteCount = 0;
  if (deleteCount > len - start) deleteCount = len - start;

  if (__Porffor_array_hasSpilled(_this)) {
    let outS: any[] = Porffor.malloc();
    outS.length = deleteCount;
    __Porffor_array_chainCopy(_this, start, outS, 0, deleteCount);

    const itemsLenS: i32 = items.length;
    _this.length = len - deleteCount + itemsLenS;
    // shift the tail to its new position (overlap-safe), then drop the inserted items in
    __Porffor_array_chainMove(_this, start + itemsLenS, start + deleteCount, len - start - deleteCount);
    for (let k: i32 = 0; k < itemsLenS; k++) __Porffor_array_growSet(_this, start + k, items[k]);
    return outS;
  }

  // read values to be deleted into out
  let out: any[] = Porffor.malloc();
  out.length = deleteCount;

  let outPtr: i32 = Porffor.wasm`local.get ${out}`;
  let thisPtr: i32 = Porffor.wasm`local.get ${_this}` + start * 9;
  let thisPtrEnd: i32 = thisPtr + deleteCount * 9;

  while (thisPtr < thisPtrEnd) {
    Porffor.wasm.f64.store(outPtr, Porffor.wasm.f64.load(thisPtr, 0, 4), 0, 4);
    Porffor.wasm.i32.store8(outPtr, Porffor.wasm.i32.load8_u(thisPtr, 0, 12), 0, 12);

    thisPtr += 9;
    outPtr += 9;
  }

  // update this length
  const itemsLen: i32 = items.length;
  _this.length = len - deleteCount + itemsLen;

  // remove deleted values via memory.copy shifting values in mem
  Porffor.wasm`;; ptr = ptr(_this) + 4 + (start * 9)
local #splice_ptr i32
local.get ${_this}
i32.to_u
i32.const 4
i32.add
local.get ${start}
i32.to_u
i32.const 9
i32.mul
i32.add
local.set #splice_ptr

;; dst = ptr + itemsLen * 9
local.get #splice_ptr
local.get ${itemsLen}
i32.to_u
i32.const 9
i32.mul
i32.add

;; src = ptr + deleteCount * 9
local.get #splice_ptr
local.get ${deleteCount}
i32.to_u
i32.const 9
i32.mul
i32.add

;; size = (len - start - deleteCount) * 9
local.get ${len}
i32.to_u
local.get ${start}
i32.to_u
local.get ${deleteCount}
i32.to_u
i32.sub
i32.sub
i32.const 9
i32.mul

memory.copy 0 0`;

  if (itemsLen > 0) {
    let itemsPtr: i32 = Porffor.wasm`local.get ${items}`;
    thisPtr = Porffor.wasm`local.get ${_this}` + start * 9;
    thisPtrEnd = thisPtr + itemsLen * 9;

    while (thisPtr < thisPtrEnd) {
      Porffor.wasm.f64.store(thisPtr, Porffor.wasm.f64.load(itemsPtr, 0, 4), 0, 4);
      Porffor.wasm.i32.store8(thisPtr, Porffor.wasm.i32.load8_u(itemsPtr, 0, 12), 0, 12);

      thisPtr += 9;
      itemsPtr += 9;
    }
  }

  return out;
};

// @porf-typed-array
export const __Array_prototype_fill = (_this: any[], value: any, _start: any, _end: any) => {
  const len: i32 = _this.length;

  if (Porffor.type(_start) == Porffor.TYPES.undefined) _start = 0;
  if (Porffor.type(_end) == Porffor.TYPES.undefined) _end = len;

  let start: i32 = ecma262.ToIntegerOrInfinity(_start);
  let end: i32 = ecma262.ToIntegerOrInfinity(_end);

  if (start < 0) {
    start = len + start;
    if (start < 0) start = 0;
  }
  if (start > len) start = len;
  if (end < 0) {
    end = len + end;
    if (end < 0) end = 0;
  }
  if (end > len) end = len;

  if (__Porffor_array_hasSpilled(_this)) {
    for (let i: i32 = start; i < end; i++) __Porffor_array_growSet(_this, i, value);
    return _this;
  }

  for (let i: i32 = start; i < end; i++) {
    _this[i] = value;
  }

  return _this;
};

// @porf-typed-array
export const __Array_prototype_indexOf = (_this: any[], searchElement: any, _position: any) => {
  const len: i32 = _this.length;
  if (len == 0) return -1;

  let position: i32 = ecma262.ToIntegerOrInfinity(_position);
  if (position >= 0) {
    if (position > len) position = len;
  } else {
    position = len + position;
    if (position < 0) position = 0;
  }

  const spilled: boolean = __Porffor_array_hasSpilled(_this);
  for (let i: i32 = position; i < len; i++) {
    const el: any = spilled ? __Porffor_array_chainGet(_this, i) : _this[i];
    if (el === searchElement) return i;
  }

  return -1;
};

// @porf-typed-array
export const __Array_prototype_lastIndexOf = (_this: any[], searchElement: any, _position: any) => {
  const len: i32 = _this.length;
  if (len == 0) return -1;

  let position: i32 = _position == null ? len - 1 : ecma262.ToIntegerOrInfinity(_position);
  if (position >= 0) {
    if (position > len - 1) position = len - 1;
  } else {
    position = len + position;
  }

  const spilled: boolean = __Porffor_array_hasSpilled(_this);
  for (let i: i32 = position; i >= 0; i--) {
    const el: any = spilled ? __Porffor_array_chainGet(_this, i) : _this[i];
    if (el === searchElement) return i;
  }

  return -1;
};

// @porf-typed-array
export const __Array_prototype_includes = (_this: any[], searchElement: any, _position: any) => {
  const len: i32 = _this.length;
  if (len == 0) return false;

  let position: i32 = ecma262.ToIntegerOrInfinity(_position);
  if (position >= 0) {
    if (position > len) position = len;
  } else {
    position = len + position;
    if (position < 0) position = 0;
  }

  const spilled: boolean = __Porffor_array_hasSpilled(_this);
  for (let i: i32 = position; i < len; i++) {
    const el: any = spilled ? __Porffor_array_chainGet(_this, i) : _this[i];
    if (__ecma262_SameValueZero(el, searchElement)) return true;
  }

  return false;
};

// @porf-typed-array
export const __Array_prototype_with = (_this: any[], _index: any, value: any) => {
  const len: i32 = _this.length;

  let index: i32 = ecma262.ToIntegerOrInfinity(_index);
  if (index < 0) {
    index = len + index;
    if (index < 0) {
      throw new RangeError('Invalid index');
    }
  }

  if (index >= len) {
    throw new RangeError('Invalid index');
  }

  if (__Porffor_array_hasSpilled(_this)) {
    let outW: any[] = Porffor.malloc();
    outW.length = len;
    __Porffor_array_chainCopy(_this, 0, outW, 0, len);
    __Porffor_array_growSet(outW, index, value);
    return outW;
  }

  let out: any[] = Porffor.malloc();
  Porffor.clone(_this, out);

  out[index] = value;

  return out;
};

// @porf-typed-array
export const __Array_prototype_copyWithin = (_this: any[], _target: any, _start: any, _end: any) => {
  const len: i32 = _this.length;

  let target: i32 = ecma262.ToIntegerOrInfinity(_target);
  if (target < 0) {
    target = len + target;
    if (target < 0) target = 0;
  }
  if (target > len) target = len;

  let start: i32 = ecma262.ToIntegerOrInfinity(_start);
  if (start < 0) {
    start = len + start;
    if (start < 0) start = 0;
  }
  if (start > len) start = len;

  let end: i32;
  if (Porffor.type(_end) == Porffor.TYPES.undefined) {
    end = len;
  } else {
    end = ecma262.ToIntegerOrInfinity(_end);
    if (end < 0) {
      end = len + end;
      if (end < 0) end = 0;
    }
    if (end > len) end = len;
  }

  if (__Porffor_array_hasSpilled(_this)) {
    // mirror the non-spilled forward copy (same overlap behaviour) through the spill chain
    while (start < end) __Porffor_array_growSet(_this, target++, __Porffor_array_chainGet(_this, start++));
    return _this;
  }

  while (start < end) {
    _this[target++] = _this[start++];
  }

  return _this;
};

// @porf-typed-array
export const __Array_prototype_concat = (_this: any[], ...vals: any[]) => {
  // todo/perf: rewrite to use memory.copy (via some Porffor.array.append thing?)
  let len: i32 = _this.length;

  if (__Porffor_array_hasSpilled(_this)) {
    let outC: any[] = Porffor.malloc();
    outC.length = len;
    __Porffor_array_chainCopy(_this, 0, outC, 0, len);
    for (const x of vals) {
      if (Porffor.type(x) & 0b01000000) {
        const l: i32 = x.length;
        for (let i: i32 = 0; i < l; i++) __Porffor_array_growSet(outC, len++, x[i]);
      } else __Porffor_array_growSet(outC, len++, x);
    }
    outC.length = len;
    return outC;
  }

  let out: any[] = Porffor.malloc();
  Porffor.clone(_this, out);

  for (const x of vals) {
    if (Porffor.type(x) & 0b01000000) { // value is iterable
      // todo: for..of is broken here because ??
      const l: i32 = x.length;
      for (let i: i32 = 0; i < l; i++) {
        out[len++] = x[i];
      }
    } else {
      out[len++] = x;
    }
  }

  out.length = len;
  return out;
};

// @porf-typed-array
export const __Array_prototype_reverse = (_this: any[]) => {
  const len: i32 = _this.length;

  let start: i32 = 0;
  let end: i32 = len - 1;

  if (__Porffor_array_hasSpilled(_this)) {
    while (start < end) {
      const t: any = __Porffor_array_chainGet(_this, start);
      __Porffor_array_growSet(_this, start, __Porffor_array_chainGet(_this, end));
      __Porffor_array_growSet(_this, end, t);
      start++; end--;
    }
    return _this;
  }

  while (start < end) {
    const tmp: any = _this[start];
    _this[start++] = _this[end];
    _this[end--] = tmp;
  }

  return _this;
};


// @porf-typed-array
export const __Array_prototype_forEach = (_this: any[], callbackFn: any, thisArg: any) => {
  if (Porffor.type(callbackFn) != Porffor.TYPES.function) throw new TypeError('Callback must be a function');
  const len: i32 = _this.length;
  // chain-aware (wb-9yie slice 3): if the array grew past its buffer, read each element through the spill
  // chain. Hoist hasSpilled once (mirrors slice-2 for-of) — non-spilled arrays pay one load+branch total.
  const spilled: boolean = __Porffor_array_hasSpilled(_this);
  let i: i32 = 0;
  while (i < len) {
    const el: any = spilled ? __Porffor_array_chainGet(_this, i) : _this[i];
    callbackFn.call(thisArg, el, i++, _this);
  }
};

// @porf-typed-array
export const __Array_prototype_filter = (_this: any[], callbackFn: any, thisArg: any) => {
  if (Porffor.type(callbackFn) != Porffor.TYPES.function) throw new TypeError('Callback must be a function');
  const out: any[] = Porffor.malloc();

  const len: i32 = _this.length;
  // chain-aware (wb-9yie slice 3): read _this through the spill chain when grown; write the result via
  // growSet so `out` itself spills correctly when more than its initial buffer survives the filter.
  const spilled: boolean = __Porffor_array_hasSpilled(_this);
  let i: i32 = 0;
  let j: i32 = 0;
  while (i < len) {
    const el: any = spilled ? __Porffor_array_chainGet(_this, i) : _this[i];
    if (!!callbackFn.call(thisArg, el, i++, _this)) __Porffor_array_growSet(out, j++, el);
  }

  out.length = j;
  return out;
};

// @porf-typed-array
export const __Array_prototype_map = (_this: any[], callbackFn: any, thisArg: any) => {
  if (Porffor.type(callbackFn) != Porffor.TYPES.function) throw new TypeError('Callback must be a function');
  const len: i32 = _this.length;
  const out: any[] = Porffor.malloc();
  out.length = len;

  // chain-aware (wb-9yie slice 3): read _this through the chain when grown; write via growSet so the
  // result array spills past its own initial buffer when len exceeds it.
  const spilled: boolean = __Porffor_array_hasSpilled(_this);
  let i: i32 = 0;
  while (i < len) {
    const el: any = spilled ? __Porffor_array_chainGet(_this, i) : _this[i];
    __Porffor_array_growSet(out, i, callbackFn.call(thisArg, el, i, _this));
    i++;
  }

  return out;
};

// Array iterator methods. Porffor's for-of/spread consume a real Array natively (it has no lazy
// Symbol.iterator for custom objects), and generators are eager — so these return an eager Array, which
// `for (const [i, v] of arr.entries())` (rollup's normalizePlugins) and `[...arr.keys()]` iterate correctly.
export const __Array_prototype_entries = (_this: any[]) => {
  const len: i32 = _this.length;
  const out: any[] = Porffor.malloc();
  out.length = len;

  const spilled: boolean = __Porffor_array_hasSpilled(_this);
  let i: i32 = 0;
  while (i < len) {
    const pair: any[] = Porffor.malloc();
    pair.length = 2;
    pair[0] = i;
    pair[1] = spilled ? __Porffor_array_chainGet(_this, i) : _this[i];
    __Porffor_array_growSet(out, i, pair);
    i++;
  }

  return out;
};

export const __Array_prototype_keys = (_this: any[]) => {
  const len: i32 = _this.length;
  const out: any[] = Porffor.malloc();
  out.length = len;

  let i: i32 = 0;
  while (i < len) {
    out[i] = i;
    i++;
  }

  return out;
};

export const __Array_prototype_values = (_this: any[]) => {
  const len: i32 = _this.length;
  const out: any[] = Porffor.malloc();
  out.length = len;

  const spilled: boolean = __Porffor_array_hasSpilled(_this);
  let i: i32 = 0;
  while (i < len) {
    const el: any = spilled ? __Porffor_array_chainGet(_this, i) : _this[i];
    __Porffor_array_growSet(out, i, el);
    i++;
  }

  return out;
};

export const __Array_prototype_flatMap = (_this: any[], callbackFn: any, thisArg: any) => {
  if (Porffor.type(callbackFn) != Porffor.TYPES.function) throw new TypeError('Callback must be a function');
  const len: i32 = _this.length;
  const out: any[] = Porffor.malloc();

  const spilled: boolean = __Porffor_array_hasSpilled(_this);
  let i: i32 = 0, j: i32 = 0;
  while (i < len) {
    const el: any = spilled ? __Porffor_array_chainGet(_this, i) : _this[i];
    let x: any = callbackFn.call(thisArg, el, i++, _this);
    if (Porffor.type(x) == Porffor.TYPES.array) {
      for (const y of x) __Porffor_array_growSet(out, j++, y);
    } else __Porffor_array_growSet(out, j++, x);
  }

  out.length = j;
  return out;
};

// @porf-typed-array
export const __Array_prototype_find = (_this: any[], callbackFn: any, thisArg: any) => {
  if (Porffor.type(callbackFn) != Porffor.TYPES.function) throw new TypeError('Callback must be a function');
  const len: i32 = _this.length;
  const spilled: boolean = __Porffor_array_hasSpilled(_this);
  let i: i32 = 0;
  while (i < len) {
    const el: any = spilled ? __Porffor_array_chainGet(_this, i) : _this[i];
    if (!!callbackFn.call(thisArg, el, i++, _this)) return el;
  }
};

// @porf-typed-array
export const __Array_prototype_findLast = (_this: any[], callbackFn: any, thisArg: any) => {
  if (Porffor.type(callbackFn) != Porffor.TYPES.function) throw new TypeError('Callback must be a function');
  const spilled: boolean = __Porffor_array_hasSpilled(_this);
  let i: i32 = _this.length;
  while (i > 0) {
    const el: any = spilled ? __Porffor_array_chainGet(_this, --i) : _this[--i];
    if (!!callbackFn.call(thisArg, el, i, _this)) return el;
  }
};

// @porf-typed-array
export const __Array_prototype_findIndex = (_this: any[], callbackFn: any, thisArg: any) => {
  if (Porffor.type(callbackFn) != Porffor.TYPES.function) throw new TypeError('Callback must be a function');
  const len: i32 = _this.length;
  const spilled: boolean = __Porffor_array_hasSpilled(_this);
  let i: i32 = 0;
  while (i < len) {
    const el: any = spilled ? __Porffor_array_chainGet(_this, i) : _this[i];
    if (!!callbackFn.call(thisArg, el, i, _this)) return i;
    i++;
  }
  return -1;
};

// @porf-typed-array
export const __Array_prototype_findLastIndex = (_this: any[], callbackFn: any, thisArg: any) => {
  if (Porffor.type(callbackFn) != Porffor.TYPES.function) throw new TypeError('Callback must be a function');
  const spilled: boolean = __Porffor_array_hasSpilled(_this);
  let i: i32 = _this.length;
  while (i > 0) {
    const el: any = spilled ? __Porffor_array_chainGet(_this, --i) : _this[--i];
    if (!!callbackFn.call(thisArg, el, i, _this)) return i;
  }
  return -1;
};

// @porf-typed-array
export const __Array_prototype_every = (_this: any[], callbackFn: any, thisArg: any) => {
  if (Porffor.type(callbackFn) != Porffor.TYPES.function) throw new TypeError('Callback must be a function');
  const len: i32 = _this.length;
  const spilled: boolean = __Porffor_array_hasSpilled(_this);
  let i: i32 = 0;
  while (i < len) {
    const el: any = spilled ? __Porffor_array_chainGet(_this, i) : _this[i];
    if (!!callbackFn.call(thisArg, el, i++, _this)) {}
      else return false;
  }

  return true;
};

// @porf-typed-array
export const __Array_prototype_some = (_this: any[], callbackFn: any, thisArg: any) => {
  if (Porffor.type(callbackFn) != Porffor.TYPES.function) throw new TypeError('Callback must be a function');
  const len: i32 = _this.length;
  const spilled: boolean = __Porffor_array_hasSpilled(_this);
  let i: i32 = 0;
  while (i < len) {
    const el: any = spilled ? __Porffor_array_chainGet(_this, i) : _this[i];
    if (!!callbackFn.call(thisArg, el, i++, _this)) return true;
  }

  return false;
};

// @porf-typed-array
export const __Array_prototype_reduce = (_this: any[], callbackFn: any, initialValue: any) => {
  if (Porffor.type(callbackFn) != Porffor.TYPES.function) throw new TypeError('Callback must be a function');
  const len: i32 = _this.length;
  const spilled: boolean = __Porffor_array_hasSpilled(_this);
  let acc: any = initialValue;
  let i: i32 = 0;
  if (acc === undefined) {
    if (len == 0) throw new TypeError('Reduce of empty array with no initial value');
    acc = spilled ? __Porffor_array_chainGet(_this, i++) : _this[i++];
  }

  while (i < len) {
    const el: any = spilled ? __Porffor_array_chainGet(_this, i) : _this[i];
    acc = callbackFn(acc, el, i++, _this);
  }

  return acc;
};

// @porf-typed-array
export const __Array_prototype_reduceRight = (_this: any[], callbackFn: any, initialValue: any) => {
  if (Porffor.type(callbackFn) != Porffor.TYPES.function) throw new TypeError('Callback must be a function');
  const len: i32 = _this.length;
  const spilled: boolean = __Porffor_array_hasSpilled(_this);
  let acc: any = initialValue;
  let i: i32 = len;
  if (acc === undefined) {
    if (len == 0) throw new TypeError('Reduce of empty array with no initial value');
    acc = spilled ? __Porffor_array_chainGet(_this, --i) : _this[--i];
  }

  while (i > 0) {
    const el: any = spilled ? __Porffor_array_chainGet(_this, --i) : _this[--i];
    acc = callbackFn(acc, el, i, _this);
  }

  return acc;
};

// string less than <
export const __Porffor_strlt = (a: string|bytestring, b: string|bytestring) => {
  const maxLength: i32 = Math.max(a.length, b.length);
  for (let i: i32 = 0; i < maxLength; i++) {
    const ac: i32 = a.charCodeAt(i);
    const bc: i32 = b.charCodeAt(i);

    if (ac < bc) return true;
  }

  return false;
};

// @porf-typed-array
export const __Array_prototype_sort = (_this: any[], callbackFn: any) => {
  if (callbackFn === undefined) {
    // default callbackFn, convert to strings and sort by char code
    callbackFn = (x: any, y: any) => {
      // 23.1.3.30.2 CompareArrayElements (x, y, comparefn)
      // https://tc39.es/ecma262/#sec-comparearrayelements
      // 5. Let xString be ? ToString(x).
      const xString: any = ecma262.ToString(x);

      // 6. Let yString be ? ToString(y).
      const yString: any = ecma262.ToString(y);

      // 7. Let xSmaller be ! IsLessThan(xString, yString, true).
      // 8. If xSmaller is true, return -1𝔽.
      if (__Porffor_strlt(xString, yString)) return -1;

      // 9. Let ySmaller be ! IsLessThan(yString, xString, true).
      // 10. If ySmaller is true, return 1𝔽.
      if (__Porffor_strlt(yString, xString)) return 1;

      // 11. Return +0𝔽.
      return 0;
    };
  }

  if (Porffor.type(callbackFn) != Porffor.TYPES.function) throw new TypeError('Callback must be a function');

  // insertion sort, i guess
  const len: i32 = _this.length;

  if (__Porffor_array_hasSpilled(_this)) {
    // same insertion sort, but every element access rides the spill chain. O(n^2) accesses x chain-walk —
    // correct but slow for very large spilled arrays (a future slice could use a chain-aware merge sort).
    for (let i: i32 = 0; i < len; i++) {
      const x: any = __Porffor_array_chainGet(_this, i);
      let j: i32 = i;
      while (j > 0) {
        const y: any = __Porffor_array_chainGet(_this, j - 1);
        let v: number;
        if (Porffor.type(x) == Porffor.TYPES.undefined && Porffor.type(y) == Porffor.TYPES.undefined) v = 0;
          else if (Porffor.type(x) == Porffor.TYPES.undefined) v = 1;
          else if (Porffor.type(y) == Porffor.TYPES.undefined) v = -1;
          else v = callbackFn(x, y);
        if (v >= 0) break;
        __Porffor_array_growSet(_this, j, y);
        j--;
      }
      __Porffor_array_growSet(_this, j, x);
    }
    return _this;
  }

  for (let i: i32 = 0; i < len; i++) {
    const x: any = _this[i];
    let j: i32 = i;
    while (j > 0) {
      const y: any = _this[j - 1];

      // 23.1.3.30.2 CompareArrayElements (x, y, comparefn)
      // https://tc39.es/ecma262/#sec-comparearrayelements
      let v: number;

      // 1. If x and y are both undefined, return +0𝔽.
      if (Porffor.type(x) == Porffor.TYPES.undefined && Porffor.type(y) == Porffor.TYPES.undefined) v = 0;
        // 2. If x is undefined, return 1𝔽.
        else if (Porffor.type(x) == Porffor.TYPES.undefined) v = 1;
        // 3. If y is undefined, return -1𝔽.
        else if (Porffor.type(y) == Porffor.TYPES.undefined) v = -1;
        else {
          // 4. If comparefn is not undefined, then
          // a. Let v be ? ToNumber(? Call(comparefn, undefined, « x, y »)).
          // perf: ToNumber unneeded as we just check >= 0
          v = callbackFn(x, y);

          // b. If v is NaN, return +0𝔽.
          // perf: unneeded as we just check >= 0
          // if (Number.isNaN(v)) v = 0;

          // c. Return v.
        }

      if (v >= 0) break;
      _this[j--] = y;
    }

    _this[j] = x;
  }

  return _this;
};

// @porf-typed-array
export const __Array_prototype_toString = (_this: any[]) => {
  // todo: this is bytestring only!

  let out: bytestring = Porffor.malloc();
  const len: i32 = _this.length;
  const spilled: boolean = __Porffor_array_hasSpilled(_this);
  let i: i32 = 0;
  while (i < len) {
    if (i > 0) Porffor.bytestring.appendChar(out, 44);

    const element: any = spilled ? __Porffor_array_chainGet(_this, i++) : _this[i++];
    if (element != 0 || Porffor.fastAnd(
      Porffor.type(element) != Porffor.TYPES.undefined, // undefined
      Porffor.type(element) != Porffor.TYPES.object // null
    )) {
      Porffor.bytestring.appendStr(out, ecma262.ToString(element));
    }
  }

  return out;
};

// @porf-typed-array
export const __Array_prototype_toLocaleString = (_this: any[]) => __Array_prototype_toString(_this);

// @porf-typed-array
export const __Array_prototype_join = (_this: any[], _separator: any) => {
  // todo: this is bytestring only!
  // todo/perf: optimize single char separators
  // todo/perf: optimize default separator (?)

  let separator: bytestring = ',';
  if (Porffor.type(_separator) != Porffor.TYPES.undefined)
    separator = ecma262.ToString(_separator);

  let out: bytestring = Porffor.malloc();
  const len: i32 = _this.length;
  const spilled: boolean = __Porffor_array_hasSpilled(_this);
  let i: i32 = 0;
  while (i < len) {
    if (i > 0) Porffor.bytestring.appendStr(out, separator);

    const element: any = spilled ? __Porffor_array_chainGet(_this, i++) : _this[i++];
    if (element != 0 || Porffor.fastAnd(
      Porffor.type(element) != Porffor.TYPES.undefined, // undefined
      Porffor.type(element) != Porffor.TYPES.object // null
    )) {
      Porffor.bytestring.appendStr(out, ecma262.ToString(element));
    }
  }

  return out;
};

// @porf-typed-array
export const __Array_prototype_valueOf = (_this: any[]) => {
  return _this;
};

// @porf-typed-array
export const __Array_prototype_toReversed = (_this: any[]) => {
  const len: i32 = _this.length;

  let start: i32 = 0;
  let end: i32 = len - 1;

  let out: any[] = Porffor.malloc();
  out.length = len;

  if (__Porffor_array_hasSpilled(_this)) {
    while (true) {
      __Porffor_array_growSet(out, start, __Porffor_array_chainGet(_this, end));
      if (start >= end) break;
      __Porffor_array_growSet(out, end, __Porffor_array_chainGet(_this, start));
      end--; start++;
    }
    return out;
  }

  while (true) {
    out[start] = _this[end];
    if (start >= end) {
      break;
    }
    out[end--] = _this[start++];
  }

  return out;
};

// @porf-typed-array
export const __Array_prototype_toSorted = (_this: any[], callbackFn: any) => {
  // todo/perf: could be rewritten to be its own instead of cloning and using normal sort()

  let out: any[] = Porffor.malloc();
  if (__Porffor_array_hasSpilled(_this)) {
    const lenT: i32 = _this.length;
    out.length = lenT;
    __Porffor_array_chainCopy(_this, 0, out, 0, lenT);
  } else {
    Porffor.clone(_this, out);
  }

  return __Array_prototype_sort(out, callbackFn);
};

export const __Array_prototype_toSpliced = (_this: any[], _start: any, _deleteCount: any, ...items: any[]) => {
  if (__Porffor_array_hasSpilled(_this)) {
    const lenS: i32 = _this.length;
    let startS: i32 = ecma262.ToIntegerOrInfinity(_start);
    if (startS < 0) { startS = lenS + startS; if (startS < 0) startS = 0; }
    if (startS > lenS) startS = lenS;
    let dcS: any = _deleteCount;
    if (Porffor.type(dcS) == Porffor.TYPES.undefined) dcS = lenS - startS;
    let deleteCountS: i32 = ecma262.ToIntegerOrInfinity(dcS);
    if (deleteCountS < 0) deleteCountS = 0;
    if (deleteCountS > lenS - startS) deleteCountS = lenS - startS;
    const itemsLenS: i32 = items.length;

    // build the result from scratch: head [0,start) + items + tail [start+deleteCount, len)
    let outS: any[] = Porffor.malloc();
    __Porffor_array_chainCopy(_this, 0, outS, 0, startS);
    let w: i32 = startS;
    for (let k: i32 = 0; k < itemsLenS; k++) __Porffor_array_growSet(outS, w++, items[k]);
    const tailS: i32 = lenS - startS - deleteCountS;
    __Porffor_array_chainCopy(_this, startS + deleteCountS, outS, w, tailS);
    w += tailS;
    outS.length = w;
    return outS;
  }

  let out: any[] = Porffor.malloc();
  Porffor.clone(_this, out);

  const len: i32 = _this.length;

  let start: i32 = ecma262.ToIntegerOrInfinity(_start);
  if (start < 0) {
    start = len + start;
    if (start < 0) start = 0;
  }
  if (start > len) start = len;

  if (Porffor.type(_deleteCount) == Porffor.TYPES.undefined) _deleteCount = len - start;
  let deleteCount: i32 = ecma262.ToIntegerOrInfinity(_deleteCount);

  if (deleteCount < 0) deleteCount = 0;
  if (deleteCount > len - start) deleteCount = len - start;

  // update this length
  const itemsLen: i32 = items.length;
  out.length = len - deleteCount + itemsLen;

  // remove deleted values via memory.copy shifting values in mem
  Porffor.wasm`;; ptr = ptr(_this) + 4 + (start * 9)
local #splice_ptr i32
local.get ${out}
i32.to_u
i32.const 4
i32.add
local.get ${start}
i32.to_u
i32.const 9
i32.mul
i32.add
local.set #splice_ptr

;; dst = ptr + itemsLen * 9
local.get #splice_ptr
local.get ${itemsLen}
i32.to_u
i32.const 9
i32.mul
i32.add

;; src = ptr + deleteCount * 9
local.get #splice_ptr
local.get ${deleteCount}
i32.to_u
i32.const 9
i32.mul
i32.add

;; size = (len - start - deleteCount) * 9
local.get ${len}
i32.to_u
local.get ${start}
i32.to_u
local.get ${deleteCount}
i32.to_u
i32.sub
i32.sub
i32.const 9
i32.mul

memory.copy 0 0`;

  if (itemsLen > 0) {
    let itemsPtr: i32 = Porffor.wasm`local.get ${items}`;
    let outPtr: i32 = Porffor.wasm`local.get ${out}` + start * 9;
    let outPtrEnd: i32 = outPtr + itemsLen * 9;

    while (outPtr < outPtrEnd) {
      Porffor.wasm.f64.store(outPtr, Porffor.wasm.f64.load(itemsPtr, 0, 4), 0, 4);
      Porffor.wasm.i32.store8(outPtr, Porffor.wasm.i32.load8_u(itemsPtr, 0, 12), 0, 12);

      outPtr += 9;
      itemsPtr += 9;
    }
  }

  return out;
};


export const __Array_prototype_flat = (_this: any[], _depth: any) => {
  if (Porffor.type(_depth) == Porffor.TYPES.undefined) _depth = 1;
  let depth: i32 = ecma262.ToIntegerOrInfinity(_depth);

  if (__Porffor_array_hasSpilled(_this)) {
    const lenF: i32 = _this.length;
    let outF: any[] = Porffor.malloc();
    if (depth <= 0) { outF.length = lenF; __Porffor_array_chainCopy(_this, 0, outF, 0, lenF); return outF; }
    let iF: i32 = 0, jF: i32 = 0;
    while (iF < lenF) {
      let xF: any = __Porffor_array_chainGet(_this, iF++);
      if (Porffor.type(xF) == Porffor.TYPES.array) {
        if (depth > 1) xF = __Array_prototype_flat(xF, depth - 1);
        for (const yF of xF) __Porffor_array_growSet(outF, jF++, yF);
      } else __Porffor_array_growSet(outF, jF++, xF);
    }
    outF.length = jF;
    return outF;
  }

  let out: any[] = Porffor.malloc();
  if (depth <= 0) {
    Porffor.clone(_this, out);
    return out;
  }

  const len: i32 = _this.length;
  let i: i32 = 0, j: i32 = 0;
  while (i < len) {
    let x: any = _this[i++];
    if (Porffor.type(x) == Porffor.TYPES.array) {
      if (depth > 1) x = __Array_prototype_flat(x, depth - 1);
      for (const y of x) out[j++] = y;
    } else out[j++] = x;
  }

  out.length = j;

  return out;
};


export const __Porffor_array_fastPush = (arr: any[], el: any): i32 => {
  let len: i32 = arr.length;
  // GUARD: a static allocPage array (ptr < heapStart) has no header — never read __Porffor_alloc_size on it.
  // Use the pre-spill inline store (benign overflow into free bump space). hs==0: no malloc yet ⇒ static.
  const base: i32 = Porffor.wasm`local.get ${arr}` | 0;
  const hs: i32 = __Porffor_heap_start();
  if (Porffor.fastOr(hs == 0, base < hs)) {
    arr[len] = el;
    arr.length = ++len;
    return len;
  }
  const cap: i32 = (__Porffor_alloc_size(arr) - 4) / 9 | 0;
  if (len >= cap || __Porffor_array_hasSpilled(arr)) {
    arr.length = len + 1;
    return __Porffor_array_growSet(arr, len, el);
  }
  arr[len] = el;
  arr.length = ++len;
  return len;
};

export const __Porffor_array_fastIndexOf = (arr: any[], el: number): i32 => {
  const len: i32 = arr.length;
  for (let i: i32 = 0; i < len; i++) {
    if (arr[i] == el) return i;
  }

  return -1;
};

// functional to arr.splice(i, 1)
export const __Porffor_array_fastRemove = (arr: any[], i: i32, len: i32): void => {
  if (__Porffor_array_hasSpilled(arr)) {
    arr.length = len - 1;
    __Porffor_array_chainMove(arr, i, i + 1, len - i - 1);
    return;
  }
  arr.length = len - 1;

  // offset all elements after by -1 ind
  Porffor.wasm`
local offset i32
local.get ${i}
i32.to_u
i32.const 9
i32.mul
local.get ${arr}
i32.to_u
i32.add
i32.const 4
i32.add
local.set offset

;; dst = offset (this element)
local.get offset

;; src = offset + 9 (this element + 1 element)
local.get offset
i32.const 9
i32.add

;; size = (size - i - 1) * 9
local.get ${len}
local.get ${i}
f64.sub
i32.to_u
i32.const 1
i32.sub
i32.const 9
i32.mul

memory.copy 0 0`;
};