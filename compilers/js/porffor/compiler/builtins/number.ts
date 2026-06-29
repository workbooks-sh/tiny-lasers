import type {} from './porffor.d.ts';

// 21.1.1.1 Number (value)
// https://tc39.es/ecma262/multipage/numbers-and-dates.html#sec-number-constructor-number-value
export const Number = function (value: any): number|NumberObject {
  let n: number = 0;

  // 1. If value is present, then
  // todo: handle undefined (NaN) and not present (0) args differently
  if (Porffor.type(value) != Porffor.TYPES.undefined) {
    // a. Let prim be ? ToNumeric(value).
    n = ecma262.ToNumeric(value);

    // b. If prim is a BigInt, let n be 𝔽(ℝ(prim)).
    if (Porffor.comptime.flag`hasType.bigint`) {
      if (Porffor.type(n) == Porffor.TYPES.bigint)
        n = Porffor.bigint.toNumber(n);
    }

    // c. Otherwise, let n be prim.
  }

  // 2. Else,
  // a. Let n be +0𝔽.
  // n is already 0 (from init value)

  // 3. If NewTarget is undefined, return n.
  if (!new.target) return n;

  // 4. Let O be ? OrdinaryCreateFromConstructor(NewTarget, "%Number.prototype%", « [[NumberData]] »).
  // 5. Set O.[[NumberData]] to n.
  // 6. Return O.
  return n as NumberObject;
};

// ── G2: exact decimal expansion ────────────────────────────────────────────────────────────────────────
// For a finite x > 0, returns ALL exact significant digits (ASCII, no sign/point, trailing zeros stripped) of
// the double, and writes the ECMAScript decimal-point position n into meta[0] (value = digits × 10^(n − len);
// n−1 is the exponent of the leading digit). Exact: x = m·2^e → the exact integer m·5^(−e) (e<0) or m·2^e
// (e≥0) in a base-1e7 bignum, no precision lost. Shared by toString (shortest), toFixed, toPrecision.
export const __Porffor_dtoa_exact = (x: f64, meta: i32[]): bytestring => {
  // x = m · 2^e, m an exact integer (≤ 2^53), e an integer
  let hi: i32 = 0;
  let lo: i32 = 0;
  Porffor.wasm`
local.get ${x}
i64.reinterpret_f64
i64.const 32
i64.shr_u
i32.wrap_i64
local.set ${hi}
local.get ${x}
i64.reinterpret_f64
i32.wrap_i64
local.set ${lo}`;
  const rawExp: i32 = (hi >> 20) & 0x7FF;
  const mantHi: i32 = hi & 0xFFFFF; // top 20 bits of the 52-bit mantissa
  // low 32 mantissa bits as an unsigned f64 (lo's sign bit may be set; >>>0 didn't convert reliably here)
  const loU: f64 = lo < 0 ? (lo + 4294967296.0) : lo;
  let m: f64;
  let e: i32;
  if (rawExp == 0) { // subnormal
    m = mantHi * 4294967296.0 + loU;
    e = -1074;
  } else {
    m = (mantHi + 0x100000) * 4294967296.0 + loU; // add implicit leading 1
    e = rawExp - 1075;
  }

  // bignum N (base 1e7, little-endian i32 limbs) seeded with m; value = N · 10^tenExp after scaling
  const limbs: i32 = Porffor.malloc(8192);
  let nLimbs: i32 = 0;
  let mm: f64 = m;
  while (mm > 0) {
    const q: f64 = Math.trunc(mm / 1e7);
    Porffor.wasm.i32.store(limbs + (nLimbs << 2), (mm - q * 1e7) as i32, 0, 0);
    nLimbs++;
    mm = q;
  }
  if (nLimbs == 0) { Porffor.wasm.i32.store(limbs, 0, 0, 0); nLimbs = 1; }

  let tenExp: i32 = 0;
  let mulBy: f64 = 2;
  let reps: i32 = e;
  if (e < 0) { mulBy = 5; reps = -e; tenExp = e; }
  for (let r: i32 = 0; r < reps; r++) {
    let carry: f64 = 0;
    for (let li: i32 = 0; li < nLimbs; li++) {
      const v: f64 = Porffor.wasm.i32.load(limbs + (li << 2), 0, 0) * mulBy + carry;
      const q: f64 = Math.trunc(v / 1e7);
      Porffor.wasm.i32.store(limbs + (li << 2), (v - q * 1e7) as i32, 0, 0);
      carry = q;
    }
    while (carry > 0) {
      const q: f64 = Math.trunc(carry / 1e7);
      Porffor.wasm.i32.store(limbs + (nLimbs << 2), (carry - q * 1e7) as i32, 0, 0);
      nLimbs++;
      carry = q;
    }
  }

  // exact decimal digits of N, MSB first
  const dfull: bytestring = Porffor.malloc(2048);
  let dlen: i32 = 0;
  const dptr: i32 = Porffor.wasm`local.get ${dfull}`;
  let top: i32 = Porffor.wasm.i32.load(limbs + ((nLimbs - 1) << 2), 0, 0);
  // top limb without leading zeros
  let div: i32 = 1000000;
  let started: boolean = false;
  while (div > 0) {
    const d: i32 = (top / div) | 0;
    top = top - d * div;
    div = (div / 10) | 0;
    if (started || d != 0 || div == 0) { Porffor.wasm.i32.store8(dptr + dlen, 48 + d, 0, 4); dlen++; started = true; }
  }
  // remaining limbs, 7-padded
  for (let li: i32 = nLimbs - 2; li >= 0; li--) {
    let lv: i32 = Porffor.wasm.i32.load(limbs + (li << 2), 0, 0);
    let dv: i32 = 1000000;
    while (dv > 0) {
      const d: i32 = (lv / dv) | 0;
      lv = lv - d * dv;
      dv = (dv / 10) | 0;
      Porffor.wasm.i32.store8(dptr + dlen, 48 + d, 0, 4);
      dlen++;
    }
  }

  // strip trailing zeros (exact — they don't change the value), tracking the implied 10^tenExp
  while (dlen > 1 && Porffor.wasm.i32.load8_u(dptr + dlen - 1, 0, 4) == 48) { dlen--; tenExp++; }

  // n = position of the decimal point = (#digits) + tenExp   (value = digits · 10^tenExp)
  meta[0] = dlen + tenExp;
  dfull.length = dlen;
  return dfull;
};

// Decimal digits of the exact nonneg integer (baseM + addOne) · 2^twoExp (addOne ∈ {−1,0,+1}; baseM an even
// f64 ≤ 2^54 so it is exact). Writes digits MSB-first (no trailing-zero strip) to outPtr, returns length;
// meta[0] = decimal-point position n. Used to expand the round-trip boundary midpoints exactly.
export const __Porffor_dtoa_expand = (baseM: f64, addOne: i32, twoExp: i32, outPtr: i32, meta: i32[]): i32 => {
  const limbs: i32 = Porffor.malloc(8192);
  let nLimbs: i32 = 0;
  let mm: f64 = baseM;
  while (mm > 0) { const q: f64 = Math.trunc(mm / 1e7); Porffor.wasm.i32.store(limbs + (nLimbs << 2), (mm - q * 1e7) as i32, 0, 0); nLimbs++; mm = q; }
  if (nLimbs == 0) { Porffor.wasm.i32.store(limbs, 0, 0, 0); nLimbs = 1; }
  if (addOne != 0) {
    let carry: i32 = addOne;
    let i: i32 = 0;
    while (carry != 0 && i < nLimbs) {
      let v: i32 = Porffor.wasm.i32.load(limbs + (i << 2), 0, 0) + carry;
      if (v < 0) { v = v + 10000000; carry = -1; } else if (v >= 10000000) { v = v - 10000000; carry = 1; } else carry = 0;
      Porffor.wasm.i32.store(limbs + (i << 2), v, 0, 0);
      i++;
    }
    if (carry > 0) { Porffor.wasm.i32.store(limbs + (nLimbs << 2), carry, 0, 0); nLimbs++; }
    while (nLimbs > 1 && Porffor.wasm.i32.load(limbs + ((nLimbs - 1) << 2), 0, 0) == 0) nLimbs--;
  }
  let tenExp: i32 = 0; let mulBy: f64 = 2; let reps: i32 = twoExp;
  if (twoExp < 0) { mulBy = 5; reps = -twoExp; tenExp = twoExp; }
  for (let r: i32 = 0; r < reps; r++) {
    let c: f64 = 0;
    for (let li: i32 = 0; li < nLimbs; li++) { const v: f64 = Porffor.wasm.i32.load(limbs + (li << 2), 0, 0) * mulBy + c; const q: f64 = Math.trunc(v / 1e7); Porffor.wasm.i32.store(limbs + (li << 2), (v - q * 1e7) as i32, 0, 0); c = q; }
    while (c > 0) { const q: f64 = Math.trunc(c / 1e7); Porffor.wasm.i32.store(limbs + (nLimbs << 2), (c - q * 1e7) as i32, 0, 0); nLimbs++; c = q; }
  }
  let dlen: i32 = 0;
  let topv: i32 = Porffor.wasm.i32.load(limbs + ((nLimbs - 1) << 2), 0, 0);
  let dv: i32 = 1000000; let st: boolean = false;
  while (dv > 0) { const d: i32 = (topv / dv) | 0; topv = topv - d * dv; dv = (dv / 10) | 0; if (st || d != 0 || dv == 0) { Porffor.wasm.i32.store8(outPtr + dlen, 48 + d, 0, 4); dlen++; st = true; } }
  for (let li: i32 = nLimbs - 2; li >= 0; li--) { let lv: i32 = Porffor.wasm.i32.load(limbs + (li << 2), 0, 0); let d2: i32 = 1000000; while (d2 > 0) { const d: i32 = (lv / d2) | 0; lv = lv - d * d2; d2 = (d2 / 10) | 0; Porffor.wasm.i32.store8(outPtr + dlen, 48 + d, 0, 4); dlen++; } }
  meta[0] = dlen + tenExp;
  return dlen;
};

// Compare two nonneg decimals A,B given as digit strings (MSB-first, nonzero leading) with decimal-point
// positions nA,nB. Returns <0, 0, >0. (Magnitude order: more integer digits wins; else digit-by-digit.)
export const __Porffor_dtoa_cmp = (aPtr: i32, aLen: i32, aN: i32, bPtr: i32, bLen: i32, bN: i32): i32 => {
  if (aN != bN) return aN - bN;
  let i: i32 = 0;
  const mx: i32 = aLen > bLen ? aLen : bLen;
  while (i < mx) {
    const da: i32 = i < aLen ? Porffor.wasm.i32.load8_u(aPtr + i, 0, 4) - 48 : 0;
    const db: i32 = i < bLen ? Porffor.wasm.i32.load8_u(bPtr + i, 0, 4) - 48 : 0;
    if (da != db) return da - db;
    i++;
  }
  return 0;
};

// Shortest round-trip digits: the exact expansion trimmed to the fewest leading digits that still fall inside
// the round-trip interval [midLo, midHi] (the midpoints to x's neighbouring doubles), tested EXACTLY by bignum
// decimal comparison — correct across the whole magnitude range incl. extremes (MAX_VALUE, 1e100, 5e-324).
export const __Porffor_dtoa_shortest = (x: f64, meta: i32[]): bytestring => {
  const dfull: bytestring = __Porffor_dtoa_exact(x, meta);
  const nFull: i32 = meta[0];
  const dlen: i32 = dfull.length;
  const dptr: i32 = Porffor.wasm`local.get ${dfull}`;

  // x = m·2^e
  let hi: i32 = 0; let lo: i32 = 0;
  Porffor.wasm`
local.get ${x}
i64.reinterpret_f64
i64.const 32
i64.shr_u
i32.wrap_i64
local.set ${hi}
local.get ${x}
i64.reinterpret_f64
i32.wrap_i64
local.set ${lo}`;
  const rawExp: i32 = (hi >> 20) & 0x7FF;
  const mantHi: i32 = hi & 0xFFFFF;
  const loU: f64 = lo < 0 ? (lo + 4294967296.0) : lo;
  let m: f64; let e: i32;
  if (rawExp == 0) { m = mantHi * 4294967296.0 + loU; e = -1074; }
  else { m = (mantHi + 0x100000) * 4294967296.0 + loU; e = rawExp - 1075; }
  const evenM: boolean = (m - Math.trunc(m / 2) * 2) == 0; // boundary inclusive iff mantissa even (ties→even)

  // midHi = (2m+1)·2^(e−1); midLo = (2m−1)·2^(e−1), except at a normal power-of-two (m=2^52, e>min) where the
  // lower gap halves → (4m−1)·2^(e−2).
  const hiBuf: bytestring = Porffor.malloc(2048);
  const loBuf: bytestring = Porffor.malloc(2048);
  const hiMeta: i32[] = Porffor.malloc(8);
  const loMeta: i32[] = Porffor.malloc(8);
  const hiLen: i32 = __Porffor_dtoa_expand(m * 2, 1, e - 1, Porffor.wasm`local.get ${hiBuf}`, hiMeta);
  const hiN: i32 = hiMeta[0];
  let loLen: i32;
  if (m == 4503599627370496.0 && rawExp > 1) { loLen = __Porffor_dtoa_expand(m * 4, -1, e - 2, Porffor.wasm`local.get ${loBuf}`, loMeta); }
    else { loLen = __Porffor_dtoa_expand(m * 2, -1, e - 1, Porffor.wasm`local.get ${loBuf}`, loMeta); }
  const loN: i32 = loMeta[0];
  const hiPtr: i32 = Porffor.wasm`local.get ${hiBuf}`;
  const loPtr: i32 = Porffor.wasm`local.get ${loBuf}`;

  const cand: bytestring = Porffor.malloc(2048);
  const cptr: i32 = Porffor.wasm`local.get ${cand}`;
  for (let k: i32 = 1; k <= dlen; k++) {
    // copy first k digits
    for (let i: i32 = 0; i < k; i++) Porffor.wasm.i32.store8(cptr + i, Porffor.wasm.i32.load8_u(dptr + i, 0, 4), 0, 4);
    let ck: i32 = k;
    let cn: i32 = nFull;

    // rounding decision on digit k
    let roundUp: boolean = false;
    if (k < dlen) {
      const rd: i32 = Porffor.wasm.i32.load8_u(dptr + k, 0, 4) - 48;
      if (rd > 5) roundUp = true;
      else if (rd == 5) {
        let anyAfter: boolean = false;
        for (let j: i32 = k + 1; j < dlen; j++) if (Porffor.wasm.i32.load8_u(dptr + j, 0, 4) != 48) { anyAfter = true; break; }
        if (anyAfter) roundUp = true;
        else roundUp = ((Porffor.wasm.i32.load8_u(cptr + k - 1, 0, 4) - 48) & 1) == 1; // tie → to even
      }
    }
    if (roundUp) {
      let p: i32 = k - 1;
      while (p >= 0) {
        const nd: i32 = Porffor.wasm.i32.load8_u(cptr + p, 0, 4) - 48 + 1;
        if (nd < 10) { Porffor.wasm.i32.store8(cptr + p, 48 + nd, 0, 4); break; }
        Porffor.wasm.i32.store8(cptr + p, 48, 0, 4);
        p--;
      }
      if (p < 0) { Porffor.wasm.i32.store8(cptr, 49, 0, 4); ck = 1; cn = nFull + 1; } // 999..→1000.. ⇒ "1", n+1
    }

    // exact round-trip test: the candidate (digits cptr[0..ck), point cn) rounds to x iff it lies inside the
    // boundary interval — loCmp = cand vs midLo, hiCmp = cand vs midHi. Inclusive iff the mantissa is even.
    const loCmp: i32 = __Porffor_dtoa_cmp(cptr, ck, cn, loPtr, loLen, loN);
    const hiCmp: i32 = __Porffor_dtoa_cmp(cptr, ck, cn, hiPtr, hiLen, hiN);
    const aboveLo: boolean = evenM ? (loCmp >= 0) : (loCmp > 0);
    const belowHi: boolean = evenM ? (hiCmp <= 0) : (hiCmp < 0);
    if (aboveLo && belowHi) {
      meta[0] = cn;
      const out: bytestring = Porffor.malloc(2048);
      const optr: i32 = Porffor.wasm`local.get ${out}`;
      for (let i: i32 = 0; i < ck; i++) Porffor.wasm.i32.store8(optr + i, Porffor.wasm.i32.load8_u(cptr + i, 0, 4), 0, 4);
      out.length = ck;
      return out;
    }
  }

  // fallback (shouldn't happen): full digits
  meta[0] = nFull;
  dfull.length = dlen;
  return dfull;
};

// Format shortest digits + decimal-point position n per ECMAScript Number::toString (steps 5–10): chooses
// fixed vs exponential notation exactly as node does. `neg` prepends '-'.
export const __Porffor_dtoa_format = (digits: bytestring, n: i32, neg: boolean): bytestring => {
  const k: i32 = digits.length;
  const dptr: i32 = Porffor.wasm`local.get ${digits}`;
  const out: bytestring = Porffor.malloc(2048);
  let o: i32 = Porffor.wasm`local.get ${out}`;
  if (neg) { Porffor.wasm.i32.store8(o++, 45, 0, 4); }

  if (k <= n && n <= 21) {
    // integer: all digits then (n-k) zeros
    for (let i: i32 = 0; i < k; i++) Porffor.wasm.i32.store8(o++, Porffor.wasm.i32.load8_u(dptr + i, 0, 4), 0, 4);
    for (let i: i32 = 0; i < n - k; i++) Porffor.wasm.i32.store8(o++, 48, 0, 4);
  } else if (0 < n && n <= 21) {
    // first n digits, '.', remaining
    for (let i: i32 = 0; i < n; i++) Porffor.wasm.i32.store8(o++, Porffor.wasm.i32.load8_u(dptr + i, 0, 4), 0, 4);
    Porffor.wasm.i32.store8(o++, 46, 0, 4);
    for (let i: i32 = n; i < k; i++) Porffor.wasm.i32.store8(o++, Porffor.wasm.i32.load8_u(dptr + i, 0, 4), 0, 4);
  } else if (-6 < n && n <= 0) {
    // "0." + (-n) zeros + digits
    Porffor.wasm.i32.store8(o++, 48, 0, 4);
    Porffor.wasm.i32.store8(o++, 46, 0, 4);
    for (let i: i32 = 0; i < -n; i++) Porffor.wasm.i32.store8(o++, 48, 0, 4);
    for (let i: i32 = 0; i < k; i++) Porffor.wasm.i32.store8(o++, Porffor.wasm.i32.load8_u(dptr + i, 0, 4), 0, 4);
  } else {
    // exponential: d['.'ddd] 'e' sign exp, exp = n-1
    Porffor.wasm.i32.store8(o++, Porffor.wasm.i32.load8_u(dptr, 0, 4), 0, 4);
    if (k > 1) {
      Porffor.wasm.i32.store8(o++, 46, 0, 4);
      for (let i: i32 = 1; i < k; i++) Porffor.wasm.i32.store8(o++, Porffor.wasm.i32.load8_u(dptr + i, 0, 4), 0, 4);
    }
    Porffor.wasm.i32.store8(o++, 101, 0, 4); // 'e'
    let ex: i32 = n - 1;
    if (ex < 0) { Porffor.wasm.i32.store8(o++, 45, 0, 4); ex = -ex; } else { Porffor.wasm.i32.store8(o++, 43, 0, 4); }
    let ed: i32 = 1; let et: i32 = ex; while (et >= 10) { ed++; et = (et / 10) | 0; }
    for (let p: i32 = ed - 1; p >= 0; p--) {
      let pw: i32 = 1; for (let z: i32 = 0; z < p; z++) pw = pw * 10;
      Porffor.wasm.i32.store8(o++, 48 + (((ex / pw) | 0) % 10), 0, 4);
    }
  }

  out.length = o - Porffor.wasm`local.get ${out}`;
  return out;
};

// radix: number|any for type check
export const __Number_prototype_toString = (_this: number, radix: number|any) => {
  if (Porffor.type(radix) != Porffor.TYPES.number) {
    // todo: string to number
    radix = 10;
  }

  radix = Math.trunc(radix);
  if (radix < 2 || radix > 36) {
    throw new RangeError('toString() radix argument must be between 2 and 36');
  }

  if (!Number.isFinite(_this)) {
    if (Number.isNaN(_this)) return 'NaN';
    if (_this == Infinity) return 'Infinity';
    return '-Infinity';
  }

  if (_this == 0) {
    return '0';
  }

  if (radix == 10) {
    // shortest round-trip decimal via the exact-bignum dtoa, formatted per ECMAScript Number::toString
    const neg: boolean = _this < 0;
    const ax: f64 = neg ? -_this : _this;
    const meta: i32[] = Porffor.malloc(8);
    const digits: bytestring = __Porffor_dtoa_shortest(ax, meta);
    return __Porffor_dtoa_format(digits, meta[0], neg);
  }

  let out: bytestring = Porffor.malloc(512);
  let outPtr: i32 = Porffor.wasm`local.get ${out}`;

  // if negative value
  if (_this < 0) {
    _this = -_this; // turn value positive for later use
    Porffor.wasm.i32.store8(outPtr++, 45, 0, 4); // prepend -
  }

  let i: f64 = Math.trunc(_this);

  let digits: bytestring = ''; // byte "array"

  let l: i32 = 0;
  if (radix == 10) {
    if (i >= 1e21) {
      // large exponential
      let trailing: boolean = true;
      let e: i32 = -1;
      while (i > 0) {
        const digit: f64 = i % radix;
        i = Math.trunc(i / radix);

        e++;
        if (trailing) {
          if (digit == 0) { // skip trailing 0s
            continue;
          }
          trailing = false;
        }

        Porffor.wasm.i32.store8(Porffor.wasm`local.get ${digits}` + l, digit, 0, 4);
        l++;
      }

      let digitsPtr: i32 = Porffor.wasm`local.get ${digits}` + l;
      let endPtr: i32 = outPtr + l;
      let dotPlace: i32 = outPtr + 1;
      while (outPtr < endPtr) {
        if (outPtr == dotPlace) {
          Porffor.wasm.i32.store8(outPtr++, 46, 0, 4); // .
          endPtr++;
        }

        let digit: i32 = Porffor.wasm.i32.load8_u(--digitsPtr, 0, 4);

        if (digit < 10) digit += 48; // 0-9
          else digit += 87; // a-z

        Porffor.wasm.i32.store8(outPtr++, digit, 0, 4);
      }

      Porffor.wasm.i32.store8(outPtr++, 101, 0, 4); // e
      Porffor.wasm.i32.store8(outPtr++, 43, 0, 4); // +

      l = 0;
      for (; e > 0; l++) {
        Porffor.wasm.i32.store8(Porffor.wasm`local.get ${digits}` + l, e % radix, 0, 4);
        e = Math.trunc(e / radix);
      }

      digitsPtr = Porffor.wasm`local.get ${digits}` + l;

      endPtr = outPtr + l;
      while (outPtr < endPtr) {
        let digit: i32 = Porffor.wasm.i32.load8_u(--digitsPtr, 0, 4);

        if (digit < 10) digit += 48; // 0-9
          else digit += 87; // a-z

        Porffor.wasm.i32.store8(outPtr++, digit, 0, 4);
      }

      out.length = outPtr - Porffor.wasm`local.get ${out}`;
      return out;
    }

    if (_this < 1e-6) {
      // small exponential
      let decimal: f64 = _this;

      let e: i32 = 1;
      while (true) {
        decimal *= radix;

        const intPart: i32 = Math.trunc(decimal);
        if (intPart > 0) {
          if (decimal - intPart < 1e-10) break;
        } else e++;
      }

      while (decimal > 0) {
        const digit: f64 = decimal % radix;
        decimal = Math.trunc(decimal / radix);

        Porffor.wasm.i32.store8(Porffor.wasm`local.get ${digits}` + l, digit, 0, 4);
        l++;
      }

      let digitsPtr: i32 = Porffor.wasm`local.get ${digits}` + l;
      let endPtr: i32 = outPtr + l;
      let dotPlace: i32 = outPtr + 1;
      while (outPtr < endPtr) {
        let digit: i32 = Porffor.wasm.i32.load8_u(--digitsPtr, 0, 4);

        if (outPtr == dotPlace) {
          Porffor.wasm.i32.store8(outPtr++, 46, 0, 4); // .
          endPtr++;
        }

        if (digit < 10) digit += 48; // 0-9
          else digit += 87; // a-z

        Porffor.wasm.i32.store8(outPtr++, digit, 0, 4);
      }

      Porffor.wasm.i32.store8(outPtr++, 101, 0, 4); // e
      Porffor.wasm.i32.store8(outPtr++, 45, 0, 4); // -

      l = 0;
      for (; e > 0; l++) {
        Porffor.wasm.i32.store8(Porffor.wasm`local.get ${digits}` + l, e % radix, 0, 4);
        e = Math.trunc(e / radix);
      }

      digitsPtr = Porffor.wasm`local.get ${digits}` + l;

      endPtr = outPtr + l;
      while (outPtr < endPtr) {
        let digit: i32 = Porffor.wasm.i32.load8_u(--digitsPtr, 0, 4);

        if (digit < 10) digit += 48; // 0-9
          else digit += 87; // a-z

        Porffor.wasm.i32.store8(outPtr++, digit, 0, 4);
      }

      out.length = outPtr - Porffor.wasm`local.get ${out}`;

      return out;
    }
  }

  if (i == 0) {
    Porffor.wasm.i32.store8(Porffor.wasm`local.get ${digits}`, 0, 0, 4);
    l = 1;
  } else {
    for (; i > 0; l++) {
      Porffor.wasm.i32.store8(Porffor.wasm`local.get ${digits}` + l, i % radix, 0, 4);
      i = Math.trunc(i / radix);
    }
  }

  let digitsPtr: i32 = Porffor.wasm`local.get ${digits}` + l;
  let endPtr: i32 = outPtr + l;
  while (outPtr < endPtr) {
    let digit: i32 = Porffor.wasm.i32.load8_u(--digitsPtr, 0, 4);

    if (digit < 10) digit += 48; // 0-9
      else digit += 87; // a-z

    Porffor.wasm.i32.store8(outPtr++, digit, 0, 4);
  }

  let decimal: f64 = _this - Math.trunc(_this);
  if (decimal > 0) {
    Porffor.wasm.i32.store8(outPtr++, 46, 0, 4); // .

    decimal += 1;

    // todo: doesn't handle non-10 radix properly
    let decimalDigits: i32 = 16 - l;
    for (let j: i32 = 0; j < decimalDigits; j++) {
      decimal *= radix;
    }

    decimal = Math.round(decimal);

    l = 0;
    let trailing: boolean = true;
    while (decimal > 1) {
      const digit: f64 = decimal % radix;
      decimal = Math.trunc(decimal / radix);

      if (trailing) {
        if (digit == 0) { // skip trailing 0s
          continue;
        }
        trailing = false;
      }

      Porffor.wasm.i32.store8(Porffor.wasm`local.get ${digits}` + l, digit, 0, 4);
      l++;
    }

    digitsPtr = Porffor.wasm`local.get ${digits}` + l;

    endPtr = outPtr + l;
    while (outPtr < endPtr) {
      let digit: i32 = Porffor.wasm.i32.load8_u(--digitsPtr, 0, 4);

      if (digit < 10) digit += 48; // 0-9
        else digit += 87; // a-z

      Porffor.wasm.i32.store8(outPtr++, digit, 0, 4);
    }
  }

  out.length = outPtr - Porffor.wasm`local.get ${out}`;
  return out;
};

// Round the first `keep` digits of D (ASCII, length dl) into out, ties AWAY from zero (ECMAScript toFixed/
// toPrecision/toExponential rounding). Returns the new digit length; on all-9s carry, writes "1" and bumps
// nio[0] (the decimal-point position moves left). `keep` must be ≥ 1.
export const __Porffor_dtoa_roundTo = (dptr: i32, dl: i32, keep: i32, outPtr: i32, nio: i32[]): i32 => {
  for (let i: i32 = 0; i < keep; i++) Porffor.wasm.i32.store8(outPtr + i, Porffor.wasm.i32.load8_u(dptr + i, 0, 4), 0, 4);
  if (keep >= dl) return keep;
  if ((Porffor.wasm.i32.load8_u(dptr + keep, 0, 4) - 48) < 5) return keep; // first dropped < 5 → truncate
  // round up
  let p: i32 = keep - 1;
  while (p >= 0) {
    const nd: i32 = Porffor.wasm.i32.load8_u(outPtr + p, 0, 4) - 48 + 1;
    if (nd < 10) { Porffor.wasm.i32.store8(outPtr + p, 48 + nd, 0, 4); return keep; }
    Porffor.wasm.i32.store8(outPtr + p, 48, 0, 4);
    p--;
  }
  Porffor.wasm.i32.store8(outPtr, 49, 0, 4); // 999..→1, the carry adds a place
  nio[0] = nio[0] + 1;
  return 1;
};

export const __Number_prototype_toFixed = (_this: number, fractionDigits: number) => {
  fractionDigits = Math.trunc(fractionDigits);
  if (fractionDigits < 0 || fractionDigits > 100) {
    throw new RangeError('toFixed() fractionDigits argument must be between 0 and 100');
  }

  if (!Number.isFinite(_this)) {
    if (Number.isNaN(_this)) return 'NaN';
    if (_this == Infinity) return 'Infinity';
    return '-Infinity';
  }

  const neg: boolean = _this < 0;
  let ax: f64 = neg ? -_this : _this;

  const out: bytestring = Porffor.malloc(256);
  let o: i32 = Porffor.wasm`local.get ${out}`;
  if (neg && ax != 0) Porffor.wasm.i32.store8(o++, 45, 0, 4);

  // exact digits + decimal-point position
  const meta: i32[] = Porffor.malloc(8);
  const digits: bytestring = ax == 0 ? '0' : __Porffor_dtoa_exact(ax, meta);
  let n: i32 = ax == 0 ? 1 : meta[0];
  let dl: i32 = digits.length;
  let dptr: i32 = Porffor.wasm`local.get ${digits}`;

  // keep = digits before the cut (integer digits n + fractionDigits). If ≤ 0, the value rounds to 0 unless
  // the first significant digit is at the rounding boundary.
  const keep: i32 = n + fractionDigits;
  const rbuf: bytestring = Porffor.malloc(256);
  const rptr: i32 = Porffor.wasm`local.get ${rbuf}`;
  let rlen: i32 = 0;
  if (ax == 0) {
    Porffor.wasm.i32.store8(rptr, 48, 0, 4); rlen = 1; n = 1;
  } else if (keep <= 0) {
    // rounds to 0, or up to a single 1 at position keep when the leading digit forces a carry
    if (keep == 0 && (Porffor.wasm.i32.load8_u(dptr, 0, 4) - 48) >= 5) {
      Porffor.wasm.i32.store8(rptr, 49, 0, 4); rlen = 1; n = n + 1;
    } else {
      Porffor.wasm.i32.store8(rptr, 48, 0, 4); rlen = 1; n = 1; // 0
    }
  } else {
    rlen = __Porffor_dtoa_roundTo(dptr, dl, keep, rptr, meta);
    n = meta[0];
  }

  // integer part
  if (n <= 0) {
    Porffor.wasm.i32.store8(o++, 48, 0, 4); // "0"
  } else {
    for (let i: i32 = 0; i < n; i++) Porffor.wasm.i32.store8(o++, i < rlen ? Porffor.wasm.i32.load8_u(rptr + i, 0, 4) : 48, 0, 4);
  }
  // fraction part
  if (fractionDigits > 0) {
    Porffor.wasm.i32.store8(o++, 46, 0, 4); // .
    for (let j: i32 = 0; j < fractionDigits; j++) {
      const pos: i32 = n + j;
      Porffor.wasm.i32.store8(o++, (pos >= 0 && pos < rlen) ? Porffor.wasm.i32.load8_u(rptr + pos, 0, 4) : 48, 0, 4);
    }
  }

  out.length = o - Porffor.wasm`local.get ${out}`;
  return out;
};

// 21.1.3.5 Number.prototype.toPrecision (precision)
export const __Number_prototype_toPrecision = (_this: number, precision: number|any) => {
  if (Porffor.type(precision) == Porffor.TYPES.undefined) return __Number_prototype_toString(_this, 10);
  precision = Math.trunc(precision);

  if (!Number.isFinite(_this)) {
    if (Number.isNaN(_this)) return 'NaN';
    if (_this == Infinity) return 'Infinity';
    return '-Infinity';
  }
  if (precision < 1 || precision > 100) {
    throw new RangeError('toPrecision() argument must be between 1 and 100');
  }

  const neg: boolean = _this < 0;
  let ax: f64 = neg ? -_this : _this;

  const out: bytestring = Porffor.malloc(256);
  let o: i32 = Porffor.wasm`local.get ${out}`;
  if (neg && ax != 0) Porffor.wasm.i32.store8(o++, 45, 0, 4);

  const meta: i32[] = Porffor.malloc(8);
  let rlen: i32 = 0;
  let n: i32 = 1;
  const rbuf: bytestring = Porffor.malloc(256);
  const rptr: i32 = Porffor.wasm`local.get ${rbuf}`;

  if (ax == 0) {
    for (let i: i32 = 0; i < precision; i++) Porffor.wasm.i32.store8(rptr + i, 48, 0, 4);
    rlen = precision; n = 1;
  } else {
    const digits: bytestring = __Porffor_dtoa_exact(ax, meta);
    rlen = __Porffor_dtoa_roundTo(Porffor.wasm`local.get ${digits}`, digits.length, precision, rptr, meta);
    n = meta[0];
  }

  const eExp: i32 = n - 1; // exponent of the leading digit
  if (eExp < -6 || eExp >= precision) {
    // exponential: d['.'ddd] 'e' sign exp, with `precision` significant digits
    Porffor.wasm.i32.store8(o++, Porffor.wasm.i32.load8_u(rptr, 0, 4), 0, 4);
    if (precision > 1) {
      Porffor.wasm.i32.store8(o++, 46, 0, 4);
      for (let i: i32 = 1; i < precision; i++) Porffor.wasm.i32.store8(o++, i < rlen ? Porffor.wasm.i32.load8_u(rptr + i, 0, 4) : 48, 0, 4);
    }
    Porffor.wasm.i32.store8(o++, 101, 0, 4);
    let ex: i32 = eExp;
    if (ex < 0) { Porffor.wasm.i32.store8(o++, 45, 0, 4); ex = -ex; } else { Porffor.wasm.i32.store8(o++, 43, 0, 4); }
    let ed: i32 = 1; let et: i32 = ex; while (et >= 10) { ed++; et = (et / 10) | 0; }
    for (let p: i32 = ed - 1; p >= 0; p--) {
      let pw: i32 = 1; for (let z: i32 = 0; z < p; z++) pw = pw * 10;
      Porffor.wasm.i32.store8(o++, 48 + (((ex / pw) | 0) % 10), 0, 4);
    }
  } else if (n <= 0) {
    // 0.00ddd : "0." + (-n) zeros + precision digits
    Porffor.wasm.i32.store8(o++, 48, 0, 4);
    Porffor.wasm.i32.store8(o++, 46, 0, 4);
    for (let i: i32 = 0; i < -n; i++) Porffor.wasm.i32.store8(o++, 48, 0, 4);
    for (let i: i32 = 0; i < precision; i++) Porffor.wasm.i32.store8(o++, i < rlen ? Porffor.wasm.i32.load8_u(rptr + i, 0, 4) : 48, 0, 4);
  } else {
    // fixed: n integer digits, then '.', then the rest — `precision` significant digits total
    for (let i: i32 = 0; i < n; i++) Porffor.wasm.i32.store8(o++, i < rlen ? Porffor.wasm.i32.load8_u(rptr + i, 0, 4) : 48, 0, 4);
    if (precision > n) {
      Porffor.wasm.i32.store8(o++, 46, 0, 4);
      for (let i: i32 = n; i < precision; i++) Porffor.wasm.i32.store8(o++, i < rlen ? Porffor.wasm.i32.load8_u(rptr + i, 0, 4) : 48, 0, 4);
    }
  }

  out.length = o - Porffor.wasm`local.get ${out}`;
  return out;
};

export const __Number_prototype_toLocaleString = (_this: number) => __Number_prototype_toString(_this, 10);

// fractionDigits: number|any for type check
export const __Number_prototype_toExponential = (_this: number, fractionDigits: number|any) => {
  if (!Number.isFinite(_this)) {
    if (Number.isNaN(_this)) return 'NaN';
    if (_this == Infinity) return 'Infinity';
    return '-Infinity';
  }

  if (Porffor.type(fractionDigits) != Porffor.TYPES.number) {
    // todo: string to number
    fractionDigits = undefined;
  } else {
    fractionDigits = Math.trunc(fractionDigits);
    if (fractionDigits < 0 || fractionDigits > 100) {
      throw new RangeError('toExponential() fractionDigits argument must be between 0 and 100');
    }
  }

  let out: bytestring = Porffor.malloc(512);
  let outPtr: i32 = Porffor.wasm`local.get ${out}`;

  // if negative value
  if (_this < 0) {
    _this = -_this; // turn value positive for later use
    Porffor.wasm.i32.store8(outPtr++, 45, 0, 4); // prepend -
  }

  let i: f64 = _this;

  let digits: bytestring = ''; // byte "array"

  let l: i32 = 0;
  let e: i32 = 0;
  let digitsPtr: i32;
  let endPtr: i32;
  if (_this == 0) {
    Porffor.wasm.i32.store8(outPtr++, 48, 0, 4); // 0

    if (fractionDigits > 0) {
      Porffor.wasm.i32.store8(outPtr++, 46, 0, 4); // .
      for (let j: i32 = 0; j < fractionDigits; j++) {
        Porffor.wasm.i32.store8(outPtr++, 48, 0, 4); // 0
      }
    }

    Porffor.wasm.i32.store8(outPtr++, 101, 0, 4); // e
    Porffor.wasm.i32.store8(outPtr++, 43, 0, 4); // +
  } else if (_this < 1) {
    // small exponential
    if (Porffor.type(fractionDigits) != Porffor.TYPES.number) {
      e = 1;
      while (true) {
        i *= 10;

        const intPart: i32 = Math.trunc(i);
        if (intPart > 0) {
          if (i - intPart < 1e-10) break;
        } else e++;
      }
    } else {
      e = 1;
      let j: i32 = 0;
      while (j <= fractionDigits) {
        i *= 10;

        const intPart: i32 = Math.trunc(i);
        if (intPart == 0) e++;
          else j++;
      }
    }

    while (i > 0) {
      const digit: f64 = i % 10;
      i = Math.trunc(i / 10);

      Porffor.wasm.i32.store8(Porffor.wasm`local.get ${digits}` + l, digit, 0, 4);
      l++;
    }

    digitsPtr = Porffor.wasm`local.get ${digits}` + l;
    endPtr = outPtr + l;
    let dotPlace: i32 = outPtr + 1;
    while (outPtr < endPtr) {
      let digit: i32 = Porffor.wasm.i32.load8_u(--digitsPtr, 0, 4);

      if (outPtr == dotPlace) {
        Porffor.wasm.i32.store8(outPtr++, 46, 0, 4); // .
        endPtr++;
      }

      if (digit < 10) digit += 48; // 0-9
        else digit += 87; // a-z

      Porffor.wasm.i32.store8(outPtr++, digit, 0, 4);
    }

    Porffor.wasm.i32.store8(outPtr++, 101, 0, 4); // e
    Porffor.wasm.i32.store8(outPtr++, 45, 0, 4); // -
  } else {
    // large exponential
    e = -1;
    while (i >= 1) {
      i /= 10;
      e++;
    }

    if (Porffor.type(fractionDigits) != Porffor.TYPES.number) {
      while (true) {
        i *= 10;

        const intPart: i32 = Math.trunc(i);
        if (intPart > 0) {
          if (i - intPart < 1e-10) break;
        } else e++;
      }
    } else {
      // i = _this;
      // if (e >= fractionDigits) {
      //   for (let j: i32 = 0; j < e - fractionDigits; j++) {
      //     i /= 10;
      //   }
      // } else {
      //   for (let j: i32 = 0; j < fractionDigits - e; j++) {
      //     i *= 10;
      //   }
      // }

      // eg: 1.2345 -> 123.45, if fractionDigits = 2
      for (let j: i32 = 0; j <= fractionDigits; j++) {
        i *= 10;
      }
    }

    // eg: 123.45 -> 123
    i = Math.round(i);

    while (i > 0) {
      const digit: f64 = i % 10;
      i = Math.trunc(i / 10);

      Porffor.wasm.i32.store8(Porffor.wasm`local.get ${digits}` + l, digit, 0, 4);
      l++;
    }

    digitsPtr = Porffor.wasm`local.get ${digits}` + l;
    endPtr = outPtr + l;
    let dotPlace: i32 = outPtr + 1;
    while (outPtr < endPtr) {
      if (outPtr == dotPlace) {
        Porffor.wasm.i32.store8(outPtr++, 46, 0, 4); // .
        endPtr++;
      }

      let digit: i32 = Porffor.wasm.i32.load8_u(--digitsPtr, 0, 4);

      if (digit < 10) digit += 48; // 0-9
        else digit += 87; // a-z

      Porffor.wasm.i32.store8(outPtr++, digit, 0, 4);
    }

    Porffor.wasm.i32.store8(outPtr++, 101, 0, 4); // e
    Porffor.wasm.i32.store8(outPtr++, 43, 0, 4); // +
  }

  if (e == 0) {
    Porffor.wasm.i32.store8(Porffor.wasm`local.get ${digits}`, 0, 0, 4);
    l = 1;
  } else {
    l = 0;
    for (; e > 0; l++) {
      Porffor.wasm.i32.store8(Porffor.wasm`local.get ${digits}` + l, e % 10, 0, 4);
      e = Math.trunc(e / 10);
    }
  }

  digitsPtr = Porffor.wasm`local.get ${digits}` + l;

  endPtr = outPtr + l;
  while (outPtr < endPtr) {
    let digit: i32 = Porffor.wasm.i32.load8_u(--digitsPtr, 0, 4);

    if (digit < 10) digit += 48; // 0-9
      else digit += 87; // a-z

    Porffor.wasm.i32.store8(outPtr++, digit, 0, 4);
  }

  out.length = outPtr - Porffor.wasm`local.get ${out}`;
  return out;
};

// 21.1.3.7 Number.prototype.valueOf ()
// https://tc39.es/ecma262/#sec-number.prototype.valueof
export const __Number_prototype_valueOf = (_this: number) => {
  // 1. Return ? ThisNumberValue(this value).
  return _this;
};


export const parseInt = (input: any, radix: any): f64 => {
  // todo/perf: optimize this instead of doing a naive algo (https://kholdstare.github.io/technical/2020/05/26/faster-integer-parsing.html)
  // todo/perf: use i32s here once that becomes not annoying

  input = ecma262.ToString(input).trim();

  let defaultRadix: boolean = false;
  radix = ecma262.ToIntegerOrInfinity(radix);
  if (!Number.isFinite(radix)) radix = 0; // infinity/NaN -> default

  if (radix == 0) {
    defaultRadix = true;
    radix = 10;
  }
  if (radix < 2 || radix > 36) return NaN;

  let nMax: i32 = 58;
  if (radix < 10) nMax = 48 + radix;

  let n: f64 = NaN;

  const inputPtr: i32 = Porffor.wasm`local.get ${input}`;
  const len: i32 = Porffor.wasm.i32.load(inputPtr, 0, 0);
  let i: i32 = inputPtr;

  let negative: boolean = false;

  if (Porffor.type(input) == Porffor.TYPES.bytestring) {
    const endPtr: i32 = i + len;

    // check start of string
    const startChr: i32 = Porffor.wasm.i32.load8_u(i, 0, 4);

    // +, ignore
    if (startChr == 43) i++;

    // -, switch to negative
    if (startChr == 45) {
      negative = true;
      i++;
    }

    // 0, potential start of hex
    if ((defaultRadix || radix == 16) && startChr == 48) {
      const second: i32 = Porffor.wasm.i32.load8_u(i + 1, 0, 4);
      // 0x or 0X
      if (second == 120 || second == 88) {
        // set radix to 16 and skip leading 2 chars
        i += 2;
        radix = 16;
      }
    }

    while (i < endPtr) {
      const chr: i32 = Porffor.wasm.i32.load8_u(i++, 0, 4);

      if (chr >= 48 && chr < nMax) {
        if (Number.isNaN(n)) n = 0;
        n = (n * radix) + chr - 48;
      } else if (radix > 10) {
        if (chr >= 97 && chr < (87 + radix)) {
          if (Number.isNaN(n)) n = 0;
          n = (n * radix) + chr - 87;
        } else if (chr >= 65 && chr < (55 + radix)) {
          if (Number.isNaN(n)) n = 0;
          n = (n * radix) + chr - 55;
        } else {
          break;
        }
      } else {
        break;
      }
    }

    if (negative) return -n;
    return n;
  }

  const endPtr: i32 = i + len * 2;

  // check start of string
  const startChr: i32 = Porffor.wasm.i32.load16_u(i, 0, 4);

  // +, ignore
  if (startChr == 43) i += 2;

  // -, switch to negative
  if (startChr == 45) {
    negative = true;
    i += 2;
  }

  // 0, potential start of hex
  if ((defaultRadix || radix == 16) && startChr == 48) {
    const second: i32 = Porffor.wasm.i32.load16_u(i + 2, 0, 4);
    // 0x or 0X
    if (second == 120 || second == 88) {
      // set radix to 16 and skip leading 2 chars
      i += 4;
      radix = 16;
    }
  }

  while (i < endPtr) {
    const chr: i32 = Porffor.wasm.i32.load16_u(i, 0, 4);
    i += 2;

    if (chr >= 48 && chr < nMax) {
      if (Number.isNaN(n)) n = 0;
      n = (n * radix) + chr - 48;
    } else if (radix > 10) {
      if (chr >= 97 && chr < (87 + radix)) {
        if (Number.isNaN(n)) n = 0;
        n = (n * radix) + chr - 87;
      } else if (chr >= 65 && chr < (55 + radix)) {
        if (Number.isNaN(n)) n = 0;
        n = (n * radix) + chr - 55;
      } else {
        break;
      }
    } else {
      break;
    }
  }

  if (negative) return -n;
  return n;
};

export const __Number_parseInt = (input: any, radix: any): f64 => parseInt(input, radix);

export const parseFloat = (input: any): f64 => {
  input = ecma262.ToString(input).trim();

  let n: f64 = NaN;
  let dec: i32 = 0;
  let negative: boolean = false;

  let i: i32 = 0;
  const len: i32 = input.length;

  if (len == 0) return NaN;

  const start: i32 = input.charCodeAt(0);

  // +, ignore
  if (start == 43) {
    i++;
  }

  // -, negative
  if (start == 45) {
    i++;
    negative = true;
  }

  // Check for "Infinity"
  if (len - i >= 8) {
    // Check if remaining string starts with "Infinity"
    if (input.charCodeAt(i) == 73 &&      // I
        input.charCodeAt(i + 1) == 110 && // n
        input.charCodeAt(i + 2) == 102 && // f
        input.charCodeAt(i + 3) == 105 && // i
        input.charCodeAt(i + 4) == 110 && // n
        input.charCodeAt(i + 5) == 105 && // i
        input.charCodeAt(i + 6) == 116 && // t
        input.charCodeAt(i + 7) == 121) { // y
      if (negative) return -Infinity;
      return Infinity;
    }
  }

  while (i < len) {
    const chr: i32 = input.charCodeAt(i++);

    if (chr >= 48 && chr <= 57) { // 0-9
      if (Number.isNaN(n)) n = 0;
      if (dec) {
        dec *= 10;
        n += (chr - 48) / dec;
      } else n = (n * 10) + chr - 48;
    } else if (chr == 46) { // .
      if (dec) break;
      dec = 1;
    } else if (chr == 101 || chr == 69) { // e or E
      if (Number.isNaN(n)) break; // No mantissa before exponent

      const exp: f64 = __Porffor_parseExp(input, i, len, false);
      if (!Number.isNaN(exp)) {
        if (exp < 0) {
          n = n / (10 ** -exp);
        } else {
          n = n * (10 ** exp);
        }
      }
      break;
    } else {
      break;
    }
  }

  if (negative) return -n;
  return n;
};

export const __Number_parseFloat = (input: any): f64 => parseFloat(input);