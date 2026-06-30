// @porf --valtype=i32
import type {} from './porffor.d.ts';

// __memory layout__
// per object (8):
//  size (u16, 2)
//  root flags (u8, 1):
//   inextensible - 0b0001
//  prototype type (u8, 1)
//  prototype (u32, 4)
// per entry (18):
//  key - hash (u32, 4)
//  key - value, type MSB encoded (u32, 4)
//  value - value (f64, 8)
//  value - type + flags (u16, 2):
//   accessor - 0b0001
//   configurable - 0b0010
//   enumerable - 0b0100
//   writable - 0b1000

// hash key for hashmap
export const __Porffor_object_hash = (key: any): i32 => {
  if (true /* symbol keys always supported: gating this on usedTypes caused a write/read asymmetry — lookup builtins emitted before the first symbol got the branch compiled out, so symbol-keyed reads silently missed */) {
    if (Porffor.wasm`local.get ${key+1}` == Porffor.TYPES.symbol) {
      // symbol, hash is unused so just return 0
      return 0;
    }
  }

  // bytestring or string, xxh32-based hash
  // todo/opt: custom wasm simd variant?
  // todo: bytestring/string symmetric hashing
  let p: i32 = Porffor.wasm`local.get ${key}`;
  let len: i32 = Porffor.wasm.i32.load(key, 0, 0);
  if (Porffor.wasm`local.get ${key+1}` == Porffor.TYPES.string) len *= 2;

  // (The read-side len-sanity check is superseded by the write-side capacity guard in
  // __Porffor_object_fastAdd, which traps at the overflowing INSERT before any neighbour-header corruption
  // can occur — so a corrupt key length can no longer be produced via object overflow.)
  let hash: i32 = 374761393 + len;
  const end: i32 = p + len;
  while (p + 4 <= end) {
    // hash in chunks of i32 (4 bytes)
    Porffor.wasm`
local.get hash
local.get p
i32.load 0 4
i32.const 3266489917
i32.mul
i32.add
i32.const 17
i32.rotl
i32.const 668265263
i32.mul
local.set hash`;
    p += 4;
  }

  Porffor.wasm`
;; hash final bytes up to 4 via shift depending on bytes remaining
local.get hash
local.get p
i32.load 0 4

i32.const 1
local.get end
local.get p
i32.sub
i32.const 8
i32.mul
i32.shl
i32.const 1
i32.sub
i32.and

i32.const 3266489917
i32.mul
i32.add
i32.const 17
i32.rotl
i32.const 668265263
i32.mul
local.tee hash

;; final avalanche
local.get hash
i32.const 15
i32.shr_u
i32.xor
i32.const 2246822519
i32.mul
local.tee hash

local.get hash
i32.const 13
i32.shr_u
i32.xor
i32.const 3266489917
i32.mul
local.tee hash

local.get hash
i32.const 16
i32.shr_u
i32.xor
return`;
};

export const __Porffor_object_writeKey = (ptr: i32, key: any, hash: i32): void => {
  // write hash to ptr
  Porffor.wasm.i32.store(ptr, hash, 0, 0);

  // encode key type
  let keyEnc: i32 = Porffor.wasm`local.get ${key}`;

  // set MSB 1 if regular string
  if (Porffor.wasm`local.get ${key+1}` == Porffor.TYPES.string) keyEnc |= 0x80000000;

  // set MSB 1&2 if symbol
  if (true /* symbol keys always supported: gating this on usedTypes caused a write/read asymmetry — lookup builtins emitted before the first symbol got the branch compiled out, so symbol-keyed reads silently missed */) {
    if (Porffor.wasm`local.get ${key+1}` == Porffor.TYPES.symbol) keyEnc |= 0xc0000000;
  }

  // write encoded key to ptr + 4
  Porffor.wasm.i32.store(ptr, keyEnc, 0, 4);
};

// ── OBJECT SPILL-ON-OVERFLOW GROWTH (rollup object-capacity wall; mirrors the array spill, wb-9yie) ──────
// An object never reallocs (raw i32 ptr + === identity ⇒ base must never move). When an insert overflows
// the object's own allocation it SPILLS entries into malloc'd chunks chained through the ALLOCATOR's obj-4
// slot (0 = never spilled) — proto lives at obj+4, so the chain head uses obj-4 (the malloc 8-byte header
// slot), exactly like arrays. Chunk = used i32@0, next i32@4, then 256 eighteen-byte entries @+8 (4616
// bytes). A chunk entry is byte-identical to an inline entry (hash/key i32@0, f64 value@8, flags@16,
// type@17), so lookup/get/set read/write a resolved chunk ptr UNCHANGED. Defined before all callers.

// has this object spilled? obj-4 holds the first chunk ptr (0 = never). GUARD: only a malloc'd object
// (ptr >= heapStart) carries the 8-byte header; a static allocPage object sits below heapStart with no
// header — reading obj-4 there is garbage, so report not-spilled (static objects never grow a chain).
export const __Porffor_object_hasSpilled = (obj: i32): boolean => {
  const hs: i32 = __Porffor_heap_start();
  if (Porffor.fastOr(hs == 0, obj < hs)) return false;
  return Porffor.wasm.i32.load(obj - 4, 0, 0) != 0;
};

// inline entry capacity — ONLY valid for a malloc'd object (caller gates on heapStart). (allocSize - 8) / 18.
export const __Porffor_object_inlineCap = (obj: i32): i32 => {
  return ((__Porffor_alloc_size(obj) - 8) / 18) | 0;
};

// entry ptr for spill index `si` (0-based, past the inline cap), ALLOCATING chunks as needed (write path).
export const __Porffor_object_spillSlot = (obj: i32, si: i32): i32 => {
  let prev: i32 = obj - 4;
  let chunk: i32 = Porffor.wasm.i32.load(prev, 0, 0);
  let rem: i32 = si;
  while (rem >= 256) {
    if (chunk == 0) { chunk = Porffor.malloc(4616); Porffor.wasm.i32.store(prev, chunk, 0, 0); }
    prev = chunk + 4;
    rem -= 256;
    chunk = Porffor.wasm.i32.load(prev, 0, 0);
  }
  if (chunk == 0) { chunk = Porffor.malloc(4616); Porffor.wasm.i32.store(prev, chunk, 0, 0); }
  const used: i32 = Porffor.wasm.i32.load(chunk, 0, 0);
  if (rem + 1 > used) Porffor.wasm.i32.store(chunk, rem + 1, 0, 0);
  return chunk + 8 + rem * 18;
};

// entry ptr for spill index `si` for READING (no alloc); 0 if the chunk chain is too short (shouldn't happen).
export const __Porffor_object_spillGet = (obj: i32, si: i32): i32 => {
  let chunk: i32 = Porffor.wasm.i32.load(obj - 4, 0, 0);
  let rem: i32 = si;
  while (chunk != 0 && rem >= 256) {
    rem -= 256;
    chunk = Porffor.wasm.i32.load(chunk + 4, 0, 0);
  }
  if (chunk == 0) return 0;
  return chunk + 8 + rem * 18;
};

export const __Porffor_object_fastAdd = (obj: any, key: any, value: any, flags: i32): void => {
  // add new entry
  // bump size +1
  const size: i32 = Porffor.wasm.i32.load16_u(obj, 0, 0);

  // CAPACITY GUARD (memory-model invariant: an inline object never exceeds its allocation). The flags byte
  // (offset 2) bits 4-7 hold a size-class stamped at creation: capacity = 1 << (class + 8); class 0 = unknown
  // (skip). The new entry occupies [8 + size*18, 8 + (size+1)*18). If that exceeds capacity the insert would
  // overflow the page and clobber the NEIGHBOUR object's header (the stray-write that later surfaces as a
  // corrupt key length / addr==memsize OOB far downstream). Trap AT the overflowing insert, naming the
  // object + its size + capacity, so the overflowing object kind is identified at its birth — the standing
  // header-plausibility instrument that makes overflow loud for every workload (the fix is object growth /
  // spill-on-overflow, tracked separately; this closes the silent-corruption door now).
  const optr: i32 = Porffor.wasm`local.get ${obj}` | 0;
  Porffor.wasm.i32.store16(obj, size + 1, 0, 0);

  // entryPtr = inline slot while it fits; once the object's own allocation is full, SPILL the entry into an
  // obj-4 chunk (GROWTH — replaces the old capacity-overflow trap). A static allocPage object (below
  // heapStart, no malloc header) keeps the benign inline-overflow path, exactly like a static array.
  let entryPtr: i32 = optr + 8 + size * 18;
  const hs: i32 = __Porffor_heap_start();
  if (Porffor.fastAnd(hs != 0, optr >= hs)) {
    const cap: i32 = __Porffor_object_inlineCap(obj);
    if (size >= cap) entryPtr = __Porffor_object_spillSlot(obj, size - cap);
  }
  __Porffor_object_writeKey(entryPtr, key, __Porffor_object_hash(key));

  // write new value value
  Porffor.wasm.f64.store(entryPtr, value, 0, 8);

  // write new tail (value type + flags)
  Porffor.wasm.i32.store16(entryPtr,
    flags + (Porffor.wasm`local.get ${value+1}` << 8),
    0, 16);
};

// store underlying (real) objects for hidden types
let underlyingStore: i32 = 0;
// The entry count lives in a wasm GLOBAL, not in linear memory. Keeping it in memory at the store base made
// it vulnerable to stray writes (a real workload like marked corrupted it → the search walked off-buffer);
// a global can't be hit by a memory write.
let underlyingCount: i32 = 0;
export const __Porffor_object_underlying = (_obj: any): any => {
  if (Porffor.type(_obj) == Porffor.TYPES.object) {
    Porffor.wasm`
local.get ${_obj}
i32.trunc_sat_f64_u
i32.const 7 ;; object
return`;
  }

  if (Porffor.type(_obj) > 0x05) {
    if (underlyingStore == 0) {
      // 1MB == the bump allocator's grow chunk (max single contiguous alloc) → ~87k entries. The original
      // fixed 64KB page overflowed on real workloads (e.g. marked registers an object per regex match).
      underlyingStore = Porffor.malloc(1048576); // 1MB (~87k entries); 64KB page overflowed at ~5461
    }

    // check if underlying object already exists for obj
    const underlyingLength: i32 = underlyingCount;
    const end: i32 = underlyingLength * 12;
    for (let i: i32 = 0; i < end; i += 12) {
      if (Porffor.wasm.f64.eq(Porffor.wasm.f64.load(underlyingStore + i, 0, 4), _obj))
        return Porffor.wasm.i32.load(underlyingStore + i, 0, 12) as object;
    }

    let obj;
    Porffor.wasm`
local.get ${_obj}
i32.trunc_sat_f64_u
local.set ${obj}`;

    // it does not, make it
    const underlying: object = {};
    if (Porffor.type(_obj) == Porffor.TYPES.function) {
      __Porffor_object_fastAdd(underlying, 'length', __Porffor_funcLut_length(obj), 0b0010);
      __Porffor_object_fastAdd(underlying, 'name', __Porffor_funcLut_name(obj), 0b0010);

      if (ecma262.IsConstructor(_obj)) { // constructor
        // set prototype and prototype.constructor if function and constructor
        const proto: object = {};
        __Porffor_object_fastAdd(underlying, 'prototype', proto, 0b1000);
        __Porffor_object_fastAdd(proto, 'constructor', _obj, 0b1010);
      }
    }

    if (Porffor.type(_obj) == Porffor.TYPES.array) {
      const len: i32 = Porffor.wasm.i32.load(obj, 0, 0);
      __Porffor_object_fastAdd(underlying, 'length', len, 0b1000);

      // todo: this should somehow be kept in sync?
      for (let i: i32 = 0; i < len; i++) {
        let ptr: i32 = obj + i * 9;
        Porffor.wasm`
local x f64
local x#type i32
local.get ${ptr}
f64.load 0 4
local.set x

local.get ${ptr}
i32.load8_u 0 12
local.set x#type`;
        __Porffor_object_fastAdd(underlying, __Number_prototype_toString(i), x, 0b1110);
      }
    }

    if (Porffor.fastOr(
      Porffor.type(_obj) == Porffor.TYPES.string,
      Porffor.type(_obj) == Porffor.TYPES.stringobject
    )) {
      const len: i32 = (obj as string).length;
      __Porffor_object_fastAdd(underlying, 'length', len, 0b0000);

      for (let i: i32 = 0; i < len; i++) {
        __Porffor_object_fastAdd(underlying, __Number_prototype_toString(i), (obj as string)[i], 0b0100);
      }

      if (Porffor.type(_obj) == Porffor.TYPES.string) Porffor.wasm.i32.store8(obj, 0b0001, 0, 2); // make inextensible
    }

    if (Porffor.type(_obj) == Porffor.TYPES.bytestring) {
      const len: i32 = (obj as bytestring).length;
      __Porffor_object_fastAdd(underlying, 'length', len, 0b0000);

      for (let i: i32 = 0; i < len; i++) {
        __Porffor_object_fastAdd(underlying, __Number_prototype_toString(i), (obj as bytestring)[i], 0b0100);
      }

      Porffor.wasm.i32.store8(obj, 0b0001, 0, 2); // make inextensible
    }

    // store new underlying obj (count in a wasm global; obj+underlying packed in linear memory)
    underlyingCount = underlyingLength + 1;
    Porffor.wasm.f64.store(underlyingStore + underlyingLength * 12, _obj, 0, 4);
    Porffor.wasm.i32.store(underlyingStore + underlyingLength * 12, underlying, 0, 12);
    return underlying;
  }

  Porffor.wasm`
local.get ${_obj}
i32.trunc_sat_f64_u
local.get ${_obj+1}
return`;
};

export const __Porffor_object_isProxy = (obj: any): boolean => {
  if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) return false;
  if (Porffor.wasm`local.get ${obj}` == 0) return false;
  return (Porffor.wasm.i32.load8_u(obj, 0, 2) & 0b0010) as boolean;
};

export const __Porffor_object_isObject = (arg: any): boolean => {
  const t: i32 = Porffor.wasm`local.get ${arg+1}`;
  return Porffor.fastAnd(
    arg != 0, // null
    t > 0x05,
    t != Porffor.TYPES.string,
    t != Porffor.TYPES.bytestring
  );
};

export const __Porffor_object_isObjectOrNull = (arg: any): boolean => {
  const t: i32 = Porffor.wasm`local.get ${arg+1}`;
  return Porffor.fastAnd(
    t > 0x05,
    t != Porffor.TYPES.string,
    t != Porffor.TYPES.bytestring
  );
};

export const __Porffor_object_isObjectOrSymbol = (arg: any): boolean => {
  const t: i32 = Porffor.wasm`local.get ${arg+1}`;
  return Porffor.fastAnd(
    arg != 0, // null
    t > 0x04,
    t != Porffor.TYPES.string,
    t != Porffor.TYPES.bytestring
  );
};


export const __Porffor_object_preventExtensions = (obj: any): void => {
  if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) {
    obj = __Porffor_object_underlying(obj);
    if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) return;
  }

  Porffor.wasm.i32.store8(obj, Porffor.wasm.i32.load8_u(obj, 0, 2) | 0b0001, 0, 2);
};

export const __Porffor_object_isInextensible = (obj: any): boolean => {
  if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) {
    obj = __Porffor_object_underlying(obj);
    if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) return false;
  }

  return (Porffor.wasm.i32.load8_u(obj, 0, 2) & 0b0001) as boolean;
};

export const __Porffor_object_setPrototype = (obj: any, proto: any): void => {
  if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) {
    obj = __Porffor_object_underlying(obj);
    if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) return;
  }

  if (__Porffor_object_isObjectOrNull(proto)) {
    Porffor.wasm.i32.store(obj, proto, 0, 4);
    Porffor.wasm.i32.store8(obj, Porffor.type(proto), 0, 3);
  }
};

export const __Porffor_object_getPrototype = (obj: any): any => {
  if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) {
    obj = __Porffor_object_underlying(obj);
    if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) {
      // return undefined
      Porffor.wasm`
i32.const 0
i32.const 0
return`;
    }
  }

  Porffor.wasm`
local.get ${obj}
i32.load 0 4
local.get ${obj}
i32.load8_u 0 3
return`;
};

export const __Porffor_object_getPrototypeWithHidden = (obj: any, trueType: i32): any => {
  const objectProto: any = __Porffor_object_getPrototype(obj);
  if (Porffor.type(objectProto) != Porffor.TYPES.undefined) return objectProto;

  return __Porffor_object_getHiddenPrototype(trueType);
};


export const __Porffor_object_overrideAllFlags = (obj: any, overrideOr: i32, overrideAnd: i32): void => {
  if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) {
    obj = __Porffor_object_underlying(obj);
    if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) return;
  }

  let ptr: i32 = Porffor.wasm`local.get ${obj}`;

  const size: i32 = Porffor.wasm.i32.load16_u(obj, 0, 0);
  const endPtr: i32 = ptr + size * 18;

  for (; ptr < endPtr; ptr += 18) {
    let flags: i32 = Porffor.wasm.i32.load8_u(ptr, 0, 24);
    flags = (flags | overrideOr) & overrideAnd;
    Porffor.wasm.i32.store8(ptr, flags, 0, 24);
  }
};

export const __Porffor_object_checkAllFlags = (obj: any, dataAnd: i32, accessorAnd: i32, dataExpected: i32, accessorExpected: i32): boolean => {
  if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) {
    obj = __Porffor_object_underlying(obj);
    if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) return false;
  }

  let ptr: i32 = Porffor.wasm`local.get ${obj}`;

  const size: i32 = Porffor.wasm.i32.load16_u(obj, 0, 0);
  const endPtr: i32 = ptr + size * 18;

  for (; ptr < endPtr; ptr += 18) {
    const flags: i32 = Porffor.wasm.i32.load8_u(ptr, 0, 24);
    if (flags & 0b0001) {
      // accessor
      if ((flags & accessorAnd) != accessorExpected) return false;
    } else {
      // data
      if ((flags & dataAnd) != dataExpected) return false;
    }

  }

  return true;
};

export const __Porffor_object_packAccessor = (get: any, set: any): f64 => {
  // pack i32s get & set into a single f64 (reinterpreted u64)
  Porffor.wasm`
local.get ${set}
i64.extend_i32_u
i64.const 32
i64.shl
local.get ${get}
i64.extend_i32_u
i64.or
f64.reinterpret_i64
return`;
};

export const __Porffor_object_accessorGet = (entryPtr: i32): Function|undefined => {
  const out: Function = Porffor.wasm.i32.load(entryPtr, 0, 8);

  if (Porffor.wasm`local.get ${out}` == 0) return undefined;
  return out;
};

export const __Porffor_object_accessorSet = (entryPtr: i32): Function|undefined => {
  const out: Function = Porffor.wasm.i32.load(entryPtr, 0, 12);

  if (Porffor.wasm`local.get ${out}` == 0) return undefined;
  return out;
};

export const __Porffor_object_lookup = (obj: any, target: any, targetHash: i32): i32 => {
  const optr: i32 = Porffor.wasm`local.get ${obj}` | 0;
  if (optr == 0) return -1;

  const size: i32 = Porffor.wasm.i32.load16_u(obj, 0, 0);

  // chain-aware: entries past the inline capacity live in obj-4 spill chunks. Gate on ACTUAL spilling
  // (obj-4 != 0) — NOT on size>cap — so an object grown by a non-spilling write path (object_set's benign
  // inline overflow) still scans ALL its inline entries (obj-4 == 0 ⇒ inlineCount == size, no behaviour
  // change). Only an object that fastAdd actually spilled walks the chunks. A spilled object's entries past
  // cap are guaranteed in chunks, so inlineCount = cap is exact.
  let inlineCount: i32 = size;
  let spilled: boolean = false;
  if (__Porffor_object_hasSpilled(optr)) {
    inlineCount = __Porffor_object_inlineCap(obj);
    spilled = true;
  }

  if (true /* symbol keys always supported: gating this on usedTypes caused a write/read asymmetry — lookup builtins emitted before the first symbol got the branch compiled out, so symbol-keyed reads silently missed */) {
    if (Porffor.wasm`local.get ${target+1}` == Porffor.TYPES.symbol) {
      let ptr: i32 = optr + 8;
      const inlineEnd: i32 = ptr + inlineCount * 18;
      for (; ptr < inlineEnd; ptr += 18) {
        const key: i32 = Porffor.wasm.i32.load(ptr, 0, 4);
        if ((key >>> 30) == 3) { // MSB 1 and 2 set, symbol (unset MSB x2)
          // todo: remove casts once weird bug which breaks unrelated things is fixed (https://github.com/CanadaHonk/porffor/commit/5747f0c1f3a4af95283ebef175cdacb21e332a52)
          if ((key & 0x3FFFFFFF) as symbol == target as symbol) return ptr;
        }
      }

      if (spilled) {
        let chunk: i32 = Porffor.wasm.i32.load(optr - 4, 0, 0);
        while (chunk != 0) {
          let cp: i32 = chunk + 8;
          const ce: i32 = cp + Porffor.wasm.i32.load(chunk, 0, 0) * 18;
          for (; cp < ce; cp += 18) {
            const key: i32 = Porffor.wasm.i32.load(cp, 0, 4);
            if ((key >>> 30) == 3) {
              if ((key & 0x3FFFFFFF) as symbol == target as symbol) return cp;
            }
          }
          chunk = Porffor.wasm.i32.load(chunk + 4, 0, 0);
        }
      }

      return -1;
    }
  }

  let ptr2: i32 = optr + 8;
  const inlineEnd2: i32 = ptr2 + inlineCount * 18;
  for (; ptr2 < inlineEnd2; ptr2 += 18) {
    if (Porffor.wasm.i32.load(ptr2, 0, 0) == targetHash) {
      return ptr2;
    }
  }

  if (spilled) {
    let chunk2: i32 = Porffor.wasm.i32.load(optr - 4, 0, 0);
    while (chunk2 != 0) {
      let cp2: i32 = chunk2 + 8;
      const ce2: i32 = cp2 + Porffor.wasm.i32.load(chunk2, 0, 0) * 18;
      for (; cp2 < ce2; cp2 += 18) {
        if (Porffor.wasm.i32.load(cp2, 0, 0) == targetHash) {
          return cp2;
        }
      }
      chunk2 = Porffor.wasm.i32.load(chunk2 + 4, 0, 0);
    }
  }

  return -1;
};

export const __Porffor_object_readValue = (entryPtr: i32): any => {
  Porffor.wasm`
local.get ${entryPtr}
f64.load 0 8
local.get ${entryPtr}
i32.load8_u 0 17
return`;
};

export const __Porffor_object_get = (_obj: any, key: any): any => {
  if (__Porffor_object_isProxy(_obj)) return __Porffor_proxy_get(_obj, key);

  // KEYSTONE (host-resident objects, externref ABI): a TYPES.object value whose i32 handle has the host tag
  // bit (sign bit) lives in the host table, not linear memory — route the read to ho_get_value/ho_get_type
  // instead of the linear-memory scan. This is the single chokepoint that makes EVERY builtin reading an
  // object (assign/defineProperties/JSON/enumeration) host-safe without per-call-site materialize wraps.
  if (Porffor.wasm`local.get ${_obj+1}` == Porffor.TYPES.object) {
    const handle: i32 = Porffor.wasm`local.get ${_obj}
i32.trunc_sat_f64_u`;
    if (handle < 0) {
      const hhash: i32 = __Porffor_object_hash(key);
      Porffor.wasm`
local.get ${handle}
local.get ${hhash}
call ho_get_value
local.get ${handle}
local.get ${hhash}
call ho_get_type
return`;
    }
  }

  let obj: any = _obj;
  const trueType: i32 = Porffor.wasm`local.get ${obj+1}`;
  if (trueType != Porffor.TYPES.object) obj = __Porffor_object_underlying(obj);

  if (Porffor.wasm`local.get ${obj}` == 0) throw new TypeError('Cannot get property of null');

  const hash: i32 = __Porffor_object_hash(key);
  let entryPtr: i32 = __Porffor_object_lookup(obj, key, hash);
  if (entryPtr == -1) {
    // check prototype chain
    if (trueType == Porffor.TYPES.object) {
      // opt: inline get object prototype
      Porffor.wasm`
local.get ${obj}
local.get ${obj}
i32.load 0 4
local.set ${obj}
i32.load8_u 0 3
local.set ${obj+1}`;

      // if undefined, prototype is object.prototype
      if (Porffor.type(obj) == Porffor.TYPES.undefined) obj = __Object_prototype;
    } else obj = __Porffor_object_getHiddenPrototype(trueType);

    // todo/opt: put this behind comptime flag if only __proto__ is used
    if (hash == 593337848) if (Porffor.strcmp(key, '__proto__')) {
      // get prototype
      Porffor.wasm`
local.get ${obj}
f64.convert_i32_u
local.get ${obj+1}
return`;
    }

    if (Porffor.type(obj) != Porffor.TYPES.object) obj = __Porffor_object_underlying(obj);
    let lastProto: any = obj;
    while (true) {
      if ((entryPtr = __Porffor_object_lookup(obj, key, hash)) != -1) break;

      // inline get prototype
      if (Porffor.type(obj) == Porffor.TYPES.object) {
        Porffor.wasm`
local.get ${obj}
local.get ${obj}
i32.load 0 4
local.set ${obj}
i32.load8_u 0 3
local.set ${obj+1}`;

        // if undefined, prototype is object.prototype
        if (Porffor.type(obj) == Porffor.TYPES.undefined) obj = __Object_prototype;
      } else obj = __Porffor_object_getPrototype(obj);
      if (Porffor.type(obj) != Porffor.TYPES.object) obj = __Porffor_object_underlying(obj);

      if (Porffor.fastOr(obj == null, Porffor.wasm`local.get ${obj}` == Porffor.wasm`local.get ${lastProto}`)) break;
      lastProto = obj;
    }

    if (entryPtr == -1) return undefined;
  }

  const tail: i32 = Porffor.wasm.i32.load16_u(entryPtr, 0, 16);
  if (tail & 0b0001) {
    // accessor descriptor
    const get: Function = __Porffor_object_accessorGet(entryPtr);

    if (Porffor.wasm`local.get ${get}` == 0) return undefined;
    if (tail & 0b10000) {
      // boxed getter (closure_convert {__clo,env,fn}): get slot = fn, set slot = env. Call fn(env) — the
      // box captures everything it needs, so `this` is irrelevant. The env MUST carry object type (it's the
      // captured-env record); load the raw pointer and tag it object so the getter's `__env.eN` resolves.
      const genvPtr: i32 = Porffor.wasm.i32.load(entryPtr, 0, 12);
      const genv: object = genvPtr;
      return get(genv);
    }
    return get.call(_obj);
  }

  // data descriptor
  Porffor.wasm`
local.get ${entryPtr}
f64.load 0 8
local.get ${tail}
i32.const 8
i32.shr_u
return`;
};

export const __Porffor_object_get_withHash = (_obj: any, key: any, hash: i32): any => {
  if (__Porffor_object_isProxy(_obj)) return __Porffor_proxy_get(_obj, key);

  // host-resident object chokepoint (see __Porffor_object_get) — hash is already computed here.
  if (Porffor.wasm`local.get ${_obj+1}` == Porffor.TYPES.object) {
    const handle: i32 = Porffor.wasm`local.get ${_obj}
i32.trunc_sat_f64_u`;
    if (handle < 0) {
      Porffor.wasm`
local.get ${handle}
local.get ${hash}
call ho_get_value
local.get ${handle}
local.get ${hash}
call ho_get_type
return`;
    }
  }

  let obj: any = _obj;
  const trueType: i32 = Porffor.wasm`local.get ${obj+1}`;
  if (trueType != Porffor.TYPES.object) obj = __Porffor_object_underlying(obj);

  if (Porffor.wasm`local.get ${obj}` == 0) throw new TypeError('Cannot get property of null');

  let entryPtr: i32 = __Porffor_object_lookup(obj, key, hash);
  if (entryPtr == -1) {
    // check prototype chain
    if (trueType == Porffor.TYPES.object) {
      // opt: inline get object prototype
      Porffor.wasm`
local.get ${obj}
local.get ${obj}
i32.load 0 4
local.set ${obj}
i32.load8_u 0 3
local.set ${obj+1}`;

      // if undefined, prototype is object.prototype
      if (Porffor.type(obj) == Porffor.TYPES.undefined) obj = __Object_prototype;
    } else obj = __Porffor_object_getHiddenPrototype(trueType);

    if (Porffor.type(obj) != Porffor.TYPES.object) obj = __Porffor_object_underlying(obj);
    let lastProto: any = obj;
    while (true) {
      if ((entryPtr = __Porffor_object_lookup(obj, key, hash)) != -1) break;

      // inline get prototype
      if (Porffor.type(obj) == Porffor.TYPES.object) {
        Porffor.wasm`
local.get ${obj}
local.get ${obj}
i32.load 0 4
local.set ${obj}
i32.load8_u 0 3
local.set ${obj+1}`;

        // if undefined, prototype is object.prototype
        if (Porffor.type(obj) == Porffor.TYPES.undefined) obj = __Object_prototype;
      } else obj = __Porffor_object_getPrototype(obj);
      if (Porffor.type(obj) != Porffor.TYPES.object) obj = __Porffor_object_underlying(obj);

      if (Porffor.fastOr(obj == null, Porffor.wasm`local.get ${obj}` == Porffor.wasm`local.get ${lastProto}`)) break;
      lastProto = obj;
    }

    if (entryPtr == -1) return undefined;
  }

  const tail: i32 = Porffor.wasm.i32.load16_u(entryPtr, 0, 16);
  if (tail & 0b0001) {
    // accessor descriptor
    const get: Function = __Porffor_object_accessorGet(entryPtr);

    if (Porffor.wasm`local.get ${get}` == 0) return undefined;
    if (tail & 0b10000) {
      // boxed getter (closure_convert {__clo,env,fn}): get slot = fn, set slot = env. Call fn(env) — the
      // box captures everything it needs, so `this` is irrelevant. The env MUST carry object type (it's the
      // captured-env record); load the raw pointer and tag it object so the getter's `__env.eN` resolves.
      const genvPtr: i32 = Porffor.wasm.i32.load(entryPtr, 0, 12);
      const genv: object = genvPtr;
      return get(genv);
    }
    return get.call(_obj);
  }

  // data descriptor
  Porffor.wasm`
local.get ${entryPtr}
f64.load 0 8
local.get ${tail}
i32.const 8
i32.shr_u
return`;
};

export const __Porffor_object_set = (_obj: any, key: any, value: any): any => {
  if (__Porffor_object_isProxy(_obj)) return __Porffor_proxy_set(_obj, key, value);
  // RegExp.lastIndex is the one writable builtin prototype property; it lives at memory offset 8 of the
  // regexp (where exec reads it), NOT in the object property bag. Without this, `re.lastIndex = 0` writes a
  // shadow the engine never sees, so a reused global regex (marked's emStrong rDelimAst) keeps a stale
  // lastIndex across calls → only the FIRST match is correct, the rest are corrupted.
  if (Porffor.wasm`local.get ${_obj+1}` == Porffor.TYPES.regexp) {
    if (Porffor.strcmp(key, 'lastIndex')) {
      Porffor.wasm`
local.get ${_obj}
i32.trunc_sat_f64_u
local.get ${value}
i32.trunc_sat_f64_u
i32.store16 0 8`;
      return value;
    }
  }

  // host-resident object chokepoint (see __Porffor_object_get): route the write to the host table via
  // ho_set (value/type by hash) + ho_regkey (original key string for enumeration), then return the value.
  if (Porffor.wasm`local.get ${_obj+1}` == Porffor.TYPES.object) {
    const handle: i32 = Porffor.wasm`local.get ${_obj}
i32.trunc_sat_f64_u`;
    if (handle < 0) {
      const shash: i32 = __Porffor_object_hash(key);
      Porffor.wasm`
local.get ${handle}
local.get ${shash}
local.get ${value}
local.get ${value+1}
call ho_set
local.get ${handle}
local.get ${shash}
local.get ${key}
i32.trunc_sat_f64_u
local.get ${key+1}
call ho_regkey`;
      return value;
    }
  }

  let obj: any = _obj;
  if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) {
    obj = __Porffor_object_underlying(obj);
    if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) return value;
  }

  if (Porffor.wasm`local.get ${obj}` == 0) throw new TypeError('Cannot set property of null');

  const hash: i32 = __Porffor_object_hash(key);
  let entryPtr: i32 = __Porffor_object_lookup(obj, key, hash);
  let flags: i32;
  if (entryPtr == -1) {
    if (hash == 593337848) if (Porffor.strcmp(key, '__proto__')) {
      // set prototype
      __Porffor_object_setPrototype(obj, value);
      return value;
    }

    // todo/opt: skip if no setters used
    // check prototype chain for setter
    let proto: any = __Porffor_object_getPrototype(obj);
    if (proto != null) {
      if (Porffor.type(proto) != Porffor.TYPES.object) proto = __Porffor_object_underlying(proto);
      let lastProto: any = proto;
      while (true) {
        if ((entryPtr = __Porffor_object_lookup(proto, key, hash)) != -1) break;

        proto = __Porffor_object_getPrototype(proto);
        if (Porffor.type(proto) != Porffor.TYPES.object) proto = __Porffor_object_underlying(proto);
        if (Porffor.fastOr(proto == null, Porffor.wasm`local.get ${proto}` == Porffor.wasm`local.get ${lastProto}`)) break;
        lastProto = proto;
      }

      if (entryPtr != -1) {
        // found possible setter
        const tail: i32 = Porffor.wasm.i32.load16_u(entryPtr, 0, 16);
        if (tail & 0b0001) {
          // accessor descriptor
          const set: Function = __Porffor_object_accessorSet(entryPtr);
          if (Porffor.wasm`local.get ${set}` == 0) return value;

          set.call(_obj, value);
          return value;
        }
      }
    }

    // add new entry
    // check if object is inextensible
    if (__Porffor_object_isInextensible(obj)) {
      return value;
    }

    // bump size +1
    const size: i32 = Porffor.wasm.i32.load16_u(obj, 0, 0);
    Porffor.wasm.i32.store16(obj, size + 1, 0, 0);

    // entryPtr = current end of object
    entryPtr = Porffor.wasm`local.get ${obj}` + 8 + size * 18;

    __Porffor_object_writeKey(entryPtr, key, hash);

    // flags = writable, enumerable, configurable, not accessor
    flags = 0b1110;
  } else {
    // existing entry, modify it
    const tail: i32 = Porffor.wasm.i32.load16_u(entryPtr, 0, 16);

    if (tail & 0b0001) {
      // accessor descriptor
      const set: Function = __Porffor_object_accessorSet(entryPtr);
      if (Porffor.wasm`local.get ${set}` == 0) return value;

      set.call(_obj, value);
      return value;
    }

    // data descriptor
    if (!(tail & 0b1000)) {
      // not writable, return now
      return value;
    }

    // flags = same flags as before
    flags = tail & 0xff;
  }

  // write new value value
  Porffor.wasm.f64.store(entryPtr, value, 0, 8);

  // write new tail (value type + flags)
  Porffor.wasm.i32.store16(entryPtr,
    flags + (Porffor.wasm`local.get ${value+1}` << 8),
    0, 16);

  return value;
};

export const __Porffor_object_set_withHash = (_obj: any, key: any, value: any, hash: i32): any => {
  if (__Porffor_object_isProxy(_obj)) return __Porffor_proxy_set(_obj, key, value);

  // host-resident object chokepoint (see __Porffor_object_set) — hash is already computed here.
  if (Porffor.wasm`local.get ${_obj+1}` == Porffor.TYPES.object) {
    const hhandle: i32 = Porffor.wasm`local.get ${_obj}
i32.trunc_sat_f64_u`;
    if (hhandle < 0) {
      Porffor.wasm`
local.get ${hhandle}
local.get ${hash}
local.get ${value}
local.get ${value+1}
call ho_set
local.get ${hhandle}
local.get ${hash}
local.get ${key}
i32.trunc_sat_f64_u
local.get ${key+1}
call ho_regkey`;
      return value;
    }
  }
  if (Porffor.wasm`local.get ${_obj+1}` == Porffor.TYPES.regexp) {
    if (Porffor.strcmp(key, 'lastIndex')) {
      Porffor.wasm`
local.get ${_obj}
i32.trunc_sat_f64_u
local.get ${value}
i32.trunc_sat_f64_u
i32.store16 0 8`;
      return value;
    }
  }
  let obj: any = _obj;
  if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) {
    obj = __Porffor_object_underlying(obj);
    if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) return value;
  }

  if (Porffor.wasm`local.get ${obj}` == 0) throw new TypeError('Cannot set property of null');

  let entryPtr: i32 = __Porffor_object_lookup(obj, key, hash);
  let flags: i32;
  if (entryPtr == -1) {
    // todo/opt: skip if no setters used
    // check prototype chain for setter
    let proto: any = __Porffor_object_getPrototype(obj);
    if (proto != null) {
      if (Porffor.type(proto) != Porffor.TYPES.object) proto = __Porffor_object_underlying(proto);
      let lastProto: any = proto;
      while (true) {
        if ((entryPtr = __Porffor_object_lookup(proto, key, hash)) != -1) break;

        proto = __Porffor_object_getPrototype(proto);
        if (Porffor.type(proto) != Porffor.TYPES.object) proto = __Porffor_object_underlying(proto);
        if (Porffor.fastOr(proto == null, Porffor.wasm`local.get ${proto}` == Porffor.wasm`local.get ${lastProto}`)) break;
        lastProto = proto;
      }

      if (entryPtr != -1) {
        // found possible setter
        const tail: i32 = Porffor.wasm.i32.load16_u(entryPtr, 0, 16);
        if (tail & 0b0001) {
          // accessor descriptor
          const set: Function = __Porffor_object_accessorSet(entryPtr);
          if (Porffor.wasm`local.get ${set}` == 0) return value;

          set.call(_obj, value);
          return value;
        }
      }
    }

    // add new entry
    // check if object is inextensible
    if (__Porffor_object_isInextensible(obj)) {
      return value;
    }

    // bump size +1
    const size: i32 = Porffor.wasm.i32.load16_u(obj, 0, 0);
    Porffor.wasm.i32.store16(obj, size + 1, 0, 0);

    // entryPtr = current end of object
    entryPtr = Porffor.wasm`local.get ${obj}` + 8 + size * 18;

    __Porffor_object_writeKey(entryPtr, key, hash);

    // flags = writable, enumerable, configurable, not accessor
    flags = 0b1110;
  } else {
    // existing entry, modify it
    const tail: i32 = Porffor.wasm.i32.load16_u(entryPtr, 0, 16);

    if (tail & 0b0001) {
      // accessor descriptor
      const set: Function = __Porffor_object_accessorSet(entryPtr);
      if (Porffor.wasm`local.get ${set}` == 0) return value;

      set.call(_obj, value);
      return value;
    }

    // data descriptor
    if (!(tail & 0b1000)) {
      // not writable, return now
      return value;
    }

    // flags = same flags as before
    flags = tail & 0xff;
  }

  // write new value value
  Porffor.wasm.f64.store(entryPtr, value, 0, 8);

  // write new tail (value type + flags)
  Porffor.wasm.i32.store16(entryPtr,
    flags + (Porffor.wasm`local.get ${value+1}` << 8),
    0, 16);

  return value;
};

export const __Porffor_object_setStrict = (_obj: any, key: any, value: any): any => {
  if (__Porffor_object_isProxy(_obj)) return __Porffor_proxy_set(_obj, key, value);

  // host-resident object chokepoint (see __Porffor_object_set).
  if (Porffor.wasm`local.get ${_obj+1}` == Porffor.TYPES.object) {
    const shandle: i32 = Porffor.wasm`local.get ${_obj}
i32.trunc_sat_f64_u`;
    if (shandle < 0) {
      const sshash: i32 = __Porffor_object_hash(key);
      Porffor.wasm`
local.get ${shandle}
local.get ${sshash}
local.get ${value}
local.get ${value+1}
call ho_set
local.get ${shandle}
local.get ${sshash}
local.get ${key}
i32.trunc_sat_f64_u
local.get ${key+1}
call ho_regkey`;
      return value;
    }
  }
  if (Porffor.wasm`local.get ${_obj+1}` == Porffor.TYPES.regexp) {
    if (Porffor.strcmp(key, 'lastIndex')) {
      Porffor.wasm`
local.get ${_obj}
i32.trunc_sat_f64_u
local.get ${value}
i32.trunc_sat_f64_u
i32.store16 0 8`;
      return value;
    }
  }
  let obj: any = _obj;
  if (Porffor.wasm`local.get ${obj}` == 0) throw new TypeError('Cannot set property of null');

  if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) {
    obj = __Porffor_object_underlying(obj);
    if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) return value;
  }

  const hash: i32 = __Porffor_object_hash(key);
  let entryPtr: i32 = __Porffor_object_lookup(obj, key, hash);
  let flags: i32;
  if (entryPtr == -1) {
    if (hash == 593337848) if (Porffor.strcmp(key, '__proto__')) {
      // set prototype
      __Porffor_object_setPrototype(obj, value);
      return value;
    }

    // todo/opt: skip if no setters used
    // check prototype chain for setter
    let proto: any = __Porffor_object_getPrototype(obj);
    if (proto != null) {
      if (Porffor.type(proto) != Porffor.TYPES.object) proto = __Porffor_object_underlying(proto);

      let lastProto: any = proto;
      while (true) {
        if ((entryPtr = __Porffor_object_lookup(proto, key, hash)) != -1) break;

        proto = __Porffor_object_getPrototype(proto);
        if (Porffor.type(proto) != Porffor.TYPES.object) proto = __Porffor_object_underlying(proto);
        if (Porffor.fastOr(proto == null, Porffor.wasm`local.get ${proto}` == Porffor.wasm`local.get ${lastProto}`)) break;
        lastProto = proto;
      }

      if (entryPtr != -1) {
        // found possible setter
        const tail: i32 = Porffor.wasm.i32.load16_u(entryPtr, 0, 16);
        if (tail & 0b0001) {
          // accessor descriptor
          const set: Function = __Porffor_object_accessorSet(entryPtr);
          if (Porffor.wasm`local.get ${set}` == 0) throw new TypeError('Cannot set property with only getter');

          set.call(_obj, value);
          return value;
        }
      }
    }

    // add new entry
    // check if object is inextensible
    if (__Porffor_object_isInextensible(obj)) {
      throw new TypeError('Cannot add property to inextensible object');
    }

    // bump size +1
    const size: i32 = Porffor.wasm.i32.load16_u(obj, 0, 0);
    Porffor.wasm.i32.store16(obj, size + 1, 0, 0);

    // entryPtr = current end of object
    entryPtr = Porffor.wasm`local.get ${obj}` + 8 + size * 18;

    __Porffor_object_writeKey(entryPtr, key, hash);

    // flags = writable, enumerable, configurable, not accessor
    flags = 0b1110;
  } else {
    // existing entry, modify it
    const tail: i32 = Porffor.wasm.i32.load16_u(entryPtr, 0, 16);

    if (tail & 0b0001) {
      // accessor descriptor
      const set: Function = __Porffor_object_accessorSet(entryPtr);
      if (Porffor.wasm`local.get ${set}` == 0) throw new TypeError('Cannot set property with only getter');

      set.call(_obj, value);
      return value;
    }

    // data descriptor
    if (!(tail & 0b1000)) {
      // not writable, return now
      throw new TypeError('Cannot modify read-only property of object');
    }

    // flags = same flags as before
    flags = tail & 0xff;
  }

  // write new value value (lol)
  Porffor.wasm.f64.store(entryPtr, value, 0, 8);

  // write new tail (value type + flags)
  Porffor.wasm.i32.store16(entryPtr,
    flags + (Porffor.wasm`local.get ${value+1}` << 8),
    0, 16);

  return value;
};

export const __Porffor_object_setStrict_withHash = (_obj: any, key: any, value: any, hash: i32): any => {
  if (__Porffor_object_isProxy(_obj)) return __Porffor_proxy_set(_obj, key, value);
  if (Porffor.wasm`local.get ${_obj+1}` == Porffor.TYPES.regexp) {
    if (Porffor.strcmp(key, 'lastIndex')) {
      Porffor.wasm`
local.get ${_obj}
i32.trunc_sat_f64_u
local.get ${value}
i32.trunc_sat_f64_u
i32.store16 0 8`;
      return value;
    }
  }
  let obj: any = _obj;
  if (Porffor.wasm`local.get ${obj}` == 0) throw new TypeError('Cannot set property of null');

  if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) {
    obj = __Porffor_object_underlying(obj);
    if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) return value;
  }

  let entryPtr: i32 = __Porffor_object_lookup(obj, key, hash);
  let flags: i32;
  if (entryPtr == -1) {
    // todo/opt: skip if no setters used
    // check prototype chain for setter
    let proto: any = __Porffor_object_getPrototype(obj);
    if (proto != null) {
      if (Porffor.type(proto) != Porffor.TYPES.object) proto = __Porffor_object_underlying(proto);

      let lastProto: any = proto;
      while (true) {
        if ((entryPtr = __Porffor_object_lookup(proto, key, hash)) != -1) break;

        proto = __Porffor_object_getPrototype(proto);
        if (Porffor.type(proto) != Porffor.TYPES.object) proto = __Porffor_object_underlying(proto);
        if (Porffor.fastOr(proto == null, Porffor.wasm`local.get ${proto}` == Porffor.wasm`local.get ${lastProto}`)) break;
        lastProto = proto;
      }

      if (entryPtr != -1) {
        // found possible setter
        const tail: i32 = Porffor.wasm.i32.load16_u(entryPtr, 0, 16);
        if (tail & 0b0001) {
          // accessor descriptor
          const set: Function = __Porffor_object_accessorSet(entryPtr);
          if (Porffor.wasm`local.get ${set}` == 0) throw new TypeError('Cannot set property with only getter');

          set.call(_obj, value);
          return value;
        }
      }
    }

    // add new entry
    // check if object is inextensible
    if (__Porffor_object_isInextensible(obj)) {
      throw new TypeError('Cannot add property to inextensible object');
    }

    // bump size +1
    const size: i32 = Porffor.wasm.i32.load16_u(obj, 0, 0);
    Porffor.wasm.i32.store16(obj, size + 1, 0, 0);

    // entryPtr = current end of object
    entryPtr = Porffor.wasm`local.get ${obj}` + 8 + size * 18;

    __Porffor_object_writeKey(entryPtr, key, hash);

    // flags = writable, enumerable, configurable, not accessor
    flags = 0b1110;
  } else {
    // existing entry, modify it
    const tail: i32 = Porffor.wasm.i32.load16_u(entryPtr, 0, 16);

    if (tail & 0b0001) {
      // accessor descriptor
      const set: Function = __Porffor_object_accessorSet(entryPtr);
      if (Porffor.wasm`local.get ${set}` == 0) throw new TypeError('Cannot set property with only getter');

      set.call(_obj, value);
      return value;
    }

    // data descriptor
    if (!(tail & 0b1000)) {
      // not writable, return now
      throw new TypeError('Cannot modify read-only property of object');
    }

    // flags = same flags as before
    flags = tail & 0xff;
  }

  // write new value value (lol)
  Porffor.wasm.f64.store(entryPtr, value, 0, 8);

  // write new tail (value type + flags)
  Porffor.wasm.i32.store16(entryPtr,
    flags + (Porffor.wasm`local.get ${value+1}` << 8),
    0, 16);

  return value;
};

export const __Porffor_object_define = (obj: any, key: any, value: any, flags: i32): void => {
  if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) {
    obj = __Porffor_object_underlying(obj);
    if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) return;
  }

  const hash: i32 = __Porffor_object_hash(key);
  let entryPtr: i32 = __Porffor_object_lookup(obj, key, hash);
  if (entryPtr == -1) {
    // add new entry
    // check if object is inextensible
    if (__Porffor_object_isInextensible(obj)) {
      throw new TypeError('Cannot define property, object is inextensible');
    }

    // bump size +1
    const size: i32 = Porffor.wasm.i32.load16_u(obj, 0, 0);
    Porffor.wasm.i32.store16(obj, size + 1, 0, 0);

    // entryPtr = current end of object
    entryPtr = Porffor.wasm`local.get ${obj}` + 8 + size * 18;

    __Porffor_object_writeKey(entryPtr, key, hash);
  } else {
    // existing entry, check and maybe modify it
    const tail: i32 = Porffor.wasm.i32.load16_u(entryPtr, 0, 16);

    if ((tail & 0b0010) == 0) {
      // not already configurable, check to see if we can redefine
      let err: boolean = false;

      // descriptor type (accessor/data) and/or flags (other than writable) have changed
      if ((tail & 0b0111) != (flags & 0b0111)) {
        err = true;
      } else if ((tail & 0b1000) == 0) {
        // already non-writable only checks
        // trying to change writable false -> true
        if (flags & 0b1000) {
          err = true;
        } else {
          // if already non-writable, check value isn't being changed
          Porffor.wasm`
local.get ${entryPtr}
f64.load 0 8
local.get ${entryPtr}
i32.load8_u 0 17

local.get ${value}
local.get ${value+1}

call __Object_is
i32.trunc_sat_f64_u
i32.eqz
local.set ${err}`;
        }
      }

      if (err) throw new TypeError('Cannot redefine property');
    }
  }

  // write new value value (lol)
  Porffor.wasm.f64.store(entryPtr, value, 0, 8);

  // write new tail (value type + flags)
  Porffor.wasm.i32.store16(entryPtr,
    flags + (Porffor.wasm`local.get ${value+1}` << 8),
    0, 16);
};

export const __Porffor_object_delete = (obj: any, key: any): boolean => {
  if (__Porffor_object_isProxy(obj)) return __Porffor_proxy_deleteProperty(obj, key);
  if (Porffor.wasm`local.get ${obj}` == 0) throw new TypeError('Cannot delete property of null');

  // host-resident object chokepoint — route the delete to the host table.
  if (Porffor.wasm`local.get ${obj+1}` == Porffor.TYPES.object) {
    const dhandle: i32 = Porffor.wasm`local.get ${obj}
i32.trunc_sat_f64_u`;
    if (dhandle < 0) {
      const dhash: i32 = __Porffor_object_hash(key);
      Porffor.wasm`
local.get ${dhandle}
local.get ${dhash}
call ho_delete
drop`;
      return true;
    }
  }

  if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) {
    obj = __Porffor_object_underlying(obj);
    if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) return true;
  }

  const entryPtr: i32 = __Porffor_object_lookup(obj, key, __Porffor_object_hash(key));
  if (entryPtr == -1) {
    // not found, stop
    return true;
  }

  const tail: i32 = Porffor.wasm.i32.load16_u(entryPtr, 0, 16);
  if (!(tail & 0b0010)) {
    // not configurable
    return false;
  }

  const ind: i32 = (entryPtr - Porffor.wasm`local.get ${obj}`) / 18;

  // decrement size
  let size: i32 = Porffor.wasm.i32.load16_u(obj, 0, 0);
  Porffor.wasm.i32.store16(obj, --size, 0, 0);

  if (size > ind) {
    // offset all elements after by -1 ind
    Porffor.wasm`
;; dst = entryPtr
local.get ${entryPtr}

;; src = entryPtr + 18 (+ 1 entry)
local.get ${entryPtr}
i32.const 18
i32.add

;; size = (size - ind) * 18
local.get ${size}
local.get ${ind}
i32.sub
i32.const 18
i32.mul

memory.copy 0 0`;
  }

  return true;
};

export const __Porffor_object_deleteStrict = (obj: any, key: any): boolean => {
  if (__Porffor_object_isProxy(obj)) return __Porffor_proxy_deleteProperty(obj, key);
  if (Porffor.wasm`local.get ${obj}` == 0) throw new TypeError('Cannot delete property of null');

  // host-resident object chokepoint — route the delete to the host table.
  if (Porffor.wasm`local.get ${obj+1}` == Porffor.TYPES.object) {
    const dshandle: i32 = Porffor.wasm`local.get ${obj}
i32.trunc_sat_f64_u`;
    if (dshandle < 0) {
      const dshash: i32 = __Porffor_object_hash(key);
      Porffor.wasm`
local.get ${dshandle}
local.get ${dshash}
call ho_delete
drop`;
      return true;
    }
  }

  if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) {
    obj = __Porffor_object_underlying(obj);
    if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) return true;
  }

  const entryPtr: i32 = __Porffor_object_lookup(obj, key, __Porffor_object_hash(key));
  if (entryPtr == -1) {
    // not found, stop
    return true;
  }

  const tail: i32 = Porffor.wasm.i32.load16_u(entryPtr, 0, 16);
  if (!(tail & 0b0010)) {
    // not configurable
    throw new TypeError('Cannot delete non-configurable property of object');
  }

  const ind: i32 = (entryPtr - Porffor.wasm`local.get ${obj}`) / 18;

  // decrement size
  let size: i32 = Porffor.wasm.i32.load16_u(obj, 0, 0);
  Porffor.wasm.i32.store16(obj, --size, 0, 0);

  if (size > ind) {
    // offset all elements after by -1 ind
    Porffor.wasm`
;; dst = entryPtr
local.get ${entryPtr}

;; src = entryPtr + 18 (+ 1 entry)
local.get ${entryPtr}
i32.const 18
i32.add

;; size = (size - ind) * 18
local.get ${size}
local.get ${ind}
i32.sub
i32.const 18
i32.mul

memory.copy 0 0`;
  }

  return true;
};


export const __Porffor_object_isEnumerable = (entryPtr: i32): boolean => {
  return (Porffor.wasm.i32.load8_u(entryPtr, 0, 16) & 0b0100) as boolean;
};


// used for { foo: 5 }
export const __Porffor_object_expr_init = (obj: any, key: any, value: any): void => {
  if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) obj = __Porffor_object_underlying(obj);

  const hash: i32 = __Porffor_object_hash(key);
  let entryPtr: i32 = __Porffor_object_lookup(obj, key, hash);
  if (entryPtr == -1) {
    if (hash == 593337848) if (Porffor.strcmp(key, '__proto__')) {
      // set prototype
      __Porffor_object_setPrototype(obj, value);
      return value;
    }

    // add new entry
    // bump size +1
    const size: i32 = Porffor.wasm.i32.load16_u(obj, 0, 0);
    Porffor.wasm.i32.store16(obj, size + 1, 0, 0);

    // entryPtr = current end of object
    entryPtr = Porffor.wasm`local.get ${obj}` + 8 + size * 18;
    __Porffor_object_writeKey(entryPtr, key, hash);
  }

  // write new value value
  Porffor.wasm.f64.store(entryPtr, value, 0, 8);

  // write new tail (value type + flags)
  // flags = writable, enumerable, configurable, not accessor
  Porffor.wasm.i32.store16(entryPtr,
    0b1110 + (Porffor.wasm`local.get ${value+1}` << 8),
    0, 16);
};

// used for { get foo() {} }
export const __Porffor_object_expr_get = (obj: any, key: any, get: any): void => {
  if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) obj = __Porffor_object_underlying(obj);

  const hash: i32 = __Porffor_object_hash(key);
  let entryPtr: i32 = __Porffor_object_lookup(obj, key, hash);
  let set: any = undefined;
  if (entryPtr == -1) {
    // add new entry
    // bump size +1
    const size: i32 = Porffor.wasm.i32.load16_u(obj, 0, 0);
    Porffor.wasm.i32.store16(obj, size + 1, 0, 0);

    // entryPtr = current end of object
    entryPtr = Porffor.wasm`local.get ${obj}` + 8 + size * 18;
    __Porffor_object_writeKey(entryPtr, key, hash);
  } else {
    // existing entry, keep set (if exists)
    set = __Porffor_object_accessorSet(entryPtr);
  }

  // write new value value
  Porffor.wasm.f64.store(entryPtr, __Porffor_object_packAccessor(get, set), 0, 8);

  // write new tail (value type + flags)
  // flags = writable, enumerable, configurable, accessor
  Porffor.wasm.i32.store16(entryPtr,
    0b1111 + (Porffor.TYPES.number << 8),
    0, 16);
};

// used for { set foo(v) {} }
export const __Porffor_object_expr_set = (obj: any, key: any, set: any): void => {
  if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) obj = __Porffor_object_underlying(obj);

  const hash: i32 = __Porffor_object_hash(key);
  let entryPtr: i32 = __Porffor_object_lookup(obj, key, hash);
  let get: any = undefined;
  if (entryPtr == -1) {
    // add new entry
    // bump size +1
    const size: i32 = Porffor.wasm.i32.load16_u(obj, 0, 0);
    Porffor.wasm.i32.store16(obj, size + 1, 0, 0);

    // entryPtr = current end of object
    entryPtr = Porffor.wasm`local.get ${obj}` + 8 + size * 18;
    __Porffor_object_writeKey(entryPtr, key, hash);
  } else {
    // existing entry, keep set (if exists)
    get = __Porffor_object_accessorGet(entryPtr);
  }

  // write new value value
  Porffor.wasm.f64.store(entryPtr, __Porffor_object_packAccessor(get, set), 0, 8);

  // write new tail (value type + flags)
  // flags = writable, enumerable, configurable, accessor
  Porffor.wasm.i32.store16(entryPtr,
    0b1111 + (Porffor.TYPES.number << 8),
    0, 16);
};


// used for { foo: 5 }
export const __Porffor_object_class_value = (obj: any, key: any, value: any): void => {
  if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) obj = __Porffor_object_underlying(obj);

  const hash: i32 = __Porffor_object_hash(key);
  let entryPtr: i32 = __Porffor_object_lookup(obj, key, hash);
  if (entryPtr == -1) {
    // add new entry
    // check if object is inextensible
    if (__Porffor_object_isInextensible(obj)) {
      throw new TypeError('Cannot define property, object is inextensible');
    }

    // bump size +1
    const size: i32 = Porffor.wasm.i32.load16_u(obj, 0, 0);
    Porffor.wasm.i32.store16(obj, size + 1, 0, 0);

    // entryPtr = current end of object
    entryPtr = Porffor.wasm`local.get ${obj}` + 8 + size * 18;
    __Porffor_object_writeKey(entryPtr, key, hash);
  }

  // write new value value
  Porffor.wasm.f64.store(entryPtr, value, 0, 8);

  // write new tail (value type + flags)
  // flags = writable, enumerable, configurable, not accessor
  Porffor.wasm.i32.store16(entryPtr,
    0b1110 + (Porffor.wasm`local.get ${value+1}` << 8),
    0, 16);
};

// used for { foo() {} }
export const __Porffor_object_class_method = (obj: any, key: any, value: any): void => {
  if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) obj = __Porffor_object_underlying(obj);

  const hash: i32 = __Porffor_object_hash(key);
  let entryPtr: i32 = __Porffor_object_lookup(obj, key, hash);
  if (entryPtr == -1) {
    // add new entry
    // check if object is inextensible
    if (__Porffor_object_isInextensible(obj)) {
      throw new TypeError('Cannot define property, object is inextensible');
    }

    // bump size +1
    const size: i32 = Porffor.wasm.i32.load16_u(obj, 0, 0);
    Porffor.wasm.i32.store16(obj, size + 1, 0, 0);

    // entryPtr = current end of object
    entryPtr = Porffor.wasm`local.get ${obj}` + 8 + size * 18;
    __Porffor_object_writeKey(entryPtr, key, hash);
  }

  // write new value value (lol)
  Porffor.wasm.f64.store(entryPtr, value, 0, 8);

  // write new tail (value type + flags)
  // flags = writable, enumerable, configurable, not accessor
  Porffor.wasm.i32.store16(entryPtr,
    0b1010 + (Porffor.wasm`local.get ${value+1}` << 8),
    0, 16);
};

// used for { get foo() {} }
export const __Porffor_object_class_get = (obj: any, key: any, get: any): void => {
  if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) obj = __Porffor_object_underlying(obj);

  const hash: i32 = __Porffor_object_hash(key);
  let entryPtr: i32 = __Porffor_object_lookup(obj, key, hash);
  let set: any = undefined;
  if (entryPtr == -1) {
    // add new entry
    // check if object is inextensible
    if (__Porffor_object_isInextensible(obj)) {
      throw new TypeError('Cannot define property, object is inextensible');
    }

    // bump size +1
    const size: i32 = Porffor.wasm.i32.load16_u(obj, 0, 0);
    Porffor.wasm.i32.store16(obj, size + 1, 0, 0);

    // entryPtr = current end of object
    entryPtr = Porffor.wasm`local.get ${obj}` + 8 + size * 18;
    __Porffor_object_writeKey(entryPtr, key, hash);
  } else {
    // existing entry, keep set (if exists)
    set = __Porffor_object_accessorSet(entryPtr);
  }

  // write new value value (lol)
  Porffor.wasm.f64.store(entryPtr, __Porffor_object_packAccessor(get, set), 0, 8);

  // write new tail (value type + flags)
  // flags = writable, enumerable, configurable, accessor
  Porffor.wasm.i32.store16(entryPtr,
    0b1011 + (Porffor.TYPES.number << 8),
    0, 16);
};

// used for { set foo(v) {} }
export const __Porffor_object_class_set = (obj: any, key: any, set: any): void => {
  if (Porffor.wasm`local.get ${obj+1}` != Porffor.TYPES.object) obj = __Porffor_object_underlying(obj);

  const hash: i32 = __Porffor_object_hash(key);
  let entryPtr: i32 = __Porffor_object_lookup(obj, key, hash);
  let get: any = undefined;
  if (entryPtr == -1) {
    // add new entry
    // check if object is inextensible
    if (__Porffor_object_isInextensible(obj)) {
      throw new TypeError('Cannot define property, object is inextensible');
    }

    // bump size +1
    const size: i32 = Porffor.wasm.i32.load16_u(obj, 0, 0);
    Porffor.wasm.i32.store16(obj, size + 1, 0, 0);

    // entryPtr = current end of object
    entryPtr = Porffor.wasm`local.get ${obj}` + 8 + size * 18;
    __Porffor_object_writeKey(entryPtr, key, hash);
  } else {
    // existing entry, keep set (if exists)
    get = __Porffor_object_accessorGet(entryPtr);
  }

  // write new value value (lol)
  Porffor.wasm.f64.store(entryPtr, __Porffor_object_packAccessor(get, set), 0, 8);

  // write new tail (value type + flags)
  // flags = writable, enumerable, configurable, accessor
  Porffor.wasm.i32.store16(entryPtr,
    0b1011 + (Porffor.TYPES.number << 8),
    0, 16);
};