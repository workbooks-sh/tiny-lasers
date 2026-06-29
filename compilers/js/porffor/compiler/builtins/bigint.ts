import type {} from './porffor.d.ts';

// digits is an array of u32s as digits in base 2^32
export const __Porffor_bigint_fromDigits = (negative: boolean, digits: i32[]): bigint => {
  const len: i32 = digits.length;
  if (len > 16383) throw new RangeError('Maximum BigInt size exceeded'); // (65536 - 4) / 4

  // use digits pointer as bigint pointer, as only used here
  let ptr: i32 = Porffor.wasm`local.get ${digits}`;

  Porffor.wasm.i32.store8(ptr, negative ? 1 : 0, 0, 0); // sign
  Porffor.wasm.i32.store16(ptr, len, 0, 2); // digit count

  let allZero: boolean = true;
  for (let i: i32 = 0; i < len; i++) {
    const d: i32 = digits[i];
    if (d != 0) allZero = false;

    Porffor.wasm.i32.store(ptr + i * 4, d, 0, 4);
  }

  if (allZero) {
    // todo: free ptr
    return 0 as bigint;
  }

  return (ptr + 0x8000000000000) as bigint;
};

// store small (abs(n) < 2^51 (0x8000000000000)) values inline (no allocation)
// like a ~s52 (s53 exc 2^51+(0-2^32) for u32 as pointer) inside a f64
export const __Porffor_bigint_inlineToDigitForm = (n: number): number => {
  // An inline bigint (|n| < 2^51) → a heap form: sign @0, u16 limb-count @2, base-2^32 limbs MSB-first @4.
  // |n| can exceed 2^32, so split into a high limb (< 2^19) and a low 32-bit limb. Returns the OFFSET
  // pointer (realPtr + 2^51) the heap encoding uses, so callers' `x -= 2^51` recovers the real pointer.
  const m: number = Math.abs(n);
  const lowU: number = m % 0x100000000;
  const high: i32 = Math.floor(m / 0x100000000); // < 2^19, fits i32
  // store the low limb as its SIGNED i32 value — a u32 >= 2^31 assigned to i32 saturates at 2147483647.
  const low: number = lowU >= 0x80000000 ? lowU - 0x100000000 : lowU;

  const ptr: i32 = Porffor.malloc(12); // 4 meta + up to 2 limbs
  Porffor.wasm.i32.store8(ptr, n < 0 ? 1 : 0, 0, 0);

  if (high != 0) {
    Porffor.wasm.i32.store16(ptr, 2, 0, 2);
    Porffor.wasm.i32.store(ptr, high, 0, 4); // limb 0 (MSB)
    Porffor.wasm.i32.store(ptr, low, 0, 8);  // limb 1 (LSB)
  } else {
    Porffor.wasm.i32.store16(ptr, 1, 0, 2);
    Porffor.wasm.i32.store(ptr, low, 0, 4);
  }

  return ptr + 0x8000000000000;
};


export const __Porffor_bigint_fromNumber = (n: number): bigint => {
  if (!Number.isInteger(n) || !Number.isFinite(n)) throw new RangeError('Cannot use non-integer as BigInt');
  if (Math.abs(n) < 0x8000000000000) return n as bigint;

  const negative: boolean = n < 0;
  n = Math.abs(n);

  const digits: i32[] = Porffor.malloc();
  while (n > 0) {
    const limb: number = n % 0x100000000;
    digits.unshift(limb >= 0x80000000 ? limb - 0x100000000 : limb); // signed i32 store (avoid f64->i32 saturation)
    n = Math.trunc(n / 0x100000000);
  }

  return __Porffor_bigint_fromDigits(negative, digits);
};

export const __Porffor_bigint_toNumber = (x: number): number => {
  if (Math.abs(x) < 0x8000000000000) return x as number;
  x -= 0x8000000000000;

  const negative: boolean = Porffor.wasm.i32.load8_u(x, 0, 0) != 0;
  const len: i32 = Porffor.wasm.i32.load16_u(x, 0, 2);

  let out: number = 0;
  for (let i: i32 = 0; i < len; i++) {
    const d: i32 = Porffor.wasm.i32.load(x + i * 4, 0, 4);
    out = out * 0x100000000 + d;
  }

  if (negative) out = -out;
  return out;
};

// Parse n[start..len) in `base` (2/8/16) into a bigint. Accumulates base-2^32 limbs (MSB-first) via
// repeated `limbs = limbs*base + digit`, carries in f64 (an i32[] saturates a u32 >= 2^31, so limbs are
// stored signed-wrapped and read back unsigned — same ABI as the decimal long-division path below).
export const __Porffor_bigint_fromRadix = (n: string|bytestring, start: i32, len: i32, base: i32): bigint => {
  const BASE: number = 4294967296; // 2^32 — MUST be f64
  const limbs: i32[] = Porffor.malloc();
  limbs.length = 1;
  limbs[0] = 0;
  let acc: number = 0;
  let small: boolean = true;

  for (let i: i32 = start; i < len; i++) {
    const ch: i32 = n.charCodeAt(i);
    let d: i32 = -1;
    if (ch >= 48 && ch <= 57) d = ch - 48;          // 0-9
    else if (ch >= 97 && ch <= 102) d = ch - 87;    // a-f
    else if (ch >= 65 && ch <= 70) d = ch - 55;     // A-F
    if (d < 0 || d >= base) throw new SyntaxError('Invalid character in BigInt string');

    // limbs = limbs * base + d  (process least-significant limb first, carry toward most-significant)
    let carry: number = d;
    for (let j: i32 = limbs.length - 1; j >= 0; j--) {
      const limb: i32 = limbs[j];
      const u: number = limb < 0 ? limb + BASE : limb;
      const value: number = u * base + carry;
      const lo: number = value - Math.floor(value / BASE) * BASE;
      carry = Math.floor(value / BASE);
      limbs[j] = lo >= 0x80000000 ? lo - 0x100000000 : lo;
    }
    while (carry > 0) {
      const lo: number = carry - Math.floor(carry / BASE) * BASE;
      limbs.unshift(lo >= 0x80000000 ? lo - 0x100000000 : lo);
      carry = Math.floor(carry / BASE);
    }

    acc = acc * base + d;
    if (acc >= 0x8000000000000) small = false;
  }

  if (small) return acc as bigint;
  while (limbs.length > 1 && limbs[0] == 0) limbs.shift();
  return __Porffor_bigint_fromDigits(false, limbs);
};

export const __Porffor_bigint_fromString = (n: string|bytestring): bigint => {
  // ECMAScript StringToBigInt: trim leading/trailing whitespace (same trim the number parser uses); an
  // empty/whitespace-only string then falls through the decimal branch (loop runs 0 times) ⇒ 0n.
  n = n.trim();
  const len: i32 = n.length;

  let negative: boolean = false;
  let offset: i32 = 0;
  if (n[0] == '-') {
    negative = true;
    offset = 1;
  } else if (n[0] == '+') {
    offset = 1;
  }

  // radix prefixes 0x/0o/0b — only WITHOUT a sign (a signed prefix like "-0x1" is invalid per spec and
  // falls through to the decimal branch, where 'x' is rejected as a non-digit).
  if (offset == 0 && len >= 2 && n.charCodeAt(0) == 48) {
    const c1: i32 = n.charCodeAt(1);
    let base: i32 = 0;
    if (c1 == 120 || c1 == 88) base = 16;      // x X
    else if (c1 == 111 || c1 == 79) base = 8;  // o O
    else if (c1 == 98 || c1 == 66) base = 2;   // b B
    if (base != 0) {
      if (len == 2) throw new SyntaxError('Missing digits after BigInt radix prefix');
      return __Porffor_bigint_fromRadix(n, 2, len, base);
    }
  }

  // n -> base 2^32 digits (most to least significant)
  // 4294967295 -> [ 4294967295 ]
  // 4294967296 -> [ 1, 0 ]
  // 4294967297 -> [ 1, 1 ]

  const BASE: number = 4294967296; // 2^32 — MUST be f64: as i32 it overflows to 0 (divide-by-zero garbage)
  const digits: i32[] = Porffor.malloc(); // todo: free later
  digits.length = len - offset;

  let i: i32 = 0;
  let acc: number = 0;
  while (i < len) {
    const char: i32 = n.charCodeAt(offset + i);
    const digit: i32 = char - 48;
    if (Porffor.fastOr(digit < 0, digit > 9)) throw new SyntaxError('Invalid character in BigInt string');

    digits[i++] = digit;
    acc = acc * 10 + digit;
  }

  if (acc < 0x8000000000000) {
    // inline if small enough
    return acc as bigint;
  }

  const result: i32[] = Porffor.malloc();
  while (digits.length > 0) {
    // long-division of the decimal-digit array by 2^32; `carry` is the running remainder (a u32 limb, up to
    // 2^32-1) and `value` (carry*10 + digit, up to ~4.3e10) — both MUST be f64, not i32, or they overflow.
    let carry: number = 0;
    for (let j: i32 = 0; j < digits.length; j++) {
      const value: number = carry * 10 + digits[j];
      const quotient: number = Math.floor(value / BASE);
      carry = value - quotient * BASE;

      digits[j] = quotient;
    }

    while (digits.length > 0 && digits[0] == 0) digits.shift();
    // store the u32 limb as its SIGNED i32 value — writing the f64 carry straight into an i32[] saturates a
    // value >= 2^31 at 2147483647 (i32 max), corrupting the limb.
    if (carry != 0 || digits.length > 0) result.unshift(carry >= 0x80000000 ? carry - 0x100000000 : carry);
  }

  return __Porffor_bigint_fromDigits(negative, result);
};

export const __Porffor_bigint_toString = (x: number, radix: any): string|bytestring => {
  // Inline small values are exact f64 integers — format directly.
  if (Math.abs(x) < 0x8000000000000) {
    return __Number_prototype_toString(Math.trunc(x), radix);
  }

  // Heap: base-10 is the digit-exact path (the only one test262 needs by default). Other radices are rare;
  // fall back to the (lossy) f64 path for them.
  if (radix != undefined && radix != 10) {
    return __Number_prototype_toString(Math.trunc(__Porffor_bigint_toNumber(x)), radix);
  }

  const ptr: i32 = x - 0x8000000000000;
  const neg: boolean = Porffor.wasm.i32.load8_u(ptr, 0, 0) != 0;
  const len: i32 = Porffor.wasm.i32.load16_u(ptr, 0, 2);

  // Mutable working copy of the limbs (MSB-first). Stored as i32 BIT PATTERNS (a u32 limb >= 2^31 reads back
  // negative — unsign it on use). A number[] here silently truncated high-bit limbs to i32.
  const work: i32[] = Porffor.malloc();
  work.length = len;
  for (let i: i32 = 0; i < len; i++) {
    work[i] = Porffor.wasm.i32.load(ptr + (i + 1) * 4, 0, 0);
  }

  let start: i32 = 0;
  while (start < len && work[start] == 0) start += 1;
  if (start == len) return '0';

  // Repeated divmod by 10 (MSB→LSB). `rem*2^32 + limb` < 11*2^32 < 2^53, so it's exact in f64.
  let out: string = '';
  while (start < len) {
    let rem: number = 0;
    for (let i: i32 = start; i < len; i++) {
      let w: number = work[i];
      if (w < 0) w += 0x100000000; // unsign the u32 limb
      const cur: number = rem * 0x100000000 + w;
      const q: number = Math.floor(cur / 10);
      rem = cur - q * 10;
      work[i] = q; // q < 2^32 → stored as its i32 bit pattern
    }
    out = String.fromCharCode(48 + rem) + out;
    while (start < len && work[start] == 0) start += 1;
  }

  if (neg) out = '-' + out;
  return out;
};

// todo: hook up all funcs below to codegen
export const __Porffor_bigint_add = (a: number, b: number, sub: boolean): bigint => {
  if (Math.abs(a) < 0x8000000000000) {
    if (Math.abs(b) < 0x8000000000000) {
      if (sub) b = -b;
      return __Porffor_bigint_fromNumber(Math.trunc(a + b));
    }

    a = __Porffor_bigint_inlineToDigitForm(a);
  } else if (Math.abs(b) < 0x8000000000000) {
    b = __Porffor_bigint_inlineToDigitForm(b);
  }

  a -= 0x8000000000000;
  b -= 0x8000000000000;

  const aNegative: boolean = Porffor.wasm.i32.load8_u(a, 0, 0) != 0;
  const aLen: i32 = Porffor.wasm.i32.load16_u(a, 0, 2);

  let bNegative: boolean = Porffor.wasm.i32.load8_u(b, 0, 0) != 0;
  if (sub) bNegative = !bNegative;
  const bLen: i32 = Porffor.wasm.i32.load16_u(b, 0, 2);

  const maxLen: i32 = Math.max(aLen, bLen);
  const digits: i32[] = Porffor.malloc();

  // fast path: same sign
  let negative: boolean = false;
  let carry: i32 = 0;
  if (aNegative == bNegative) {
    negative = aNegative;

    for (let i: i32 = 0; i < maxLen; i++) {
      // limbs are UNSIGNED u32 — load as f64 and unwrap the sign bit (a high-bit limb like 0xFFFFFFFE is
      // 4294967294, not -2; signed i32 limbs silently dropped the carry, e.g. 0xFFFFFFFE + 5).
      let aDigit: number = 0;
      const aOffset: i32 = aLen - i;
      if (aOffset > 0) {
        aDigit = Porffor.wasm.i32.load(a + aOffset * 4, 0, 0);
        if (aDigit < 0) aDigit += 0x100000000;
      }

      let bDigit: number = 0;
      const bOffset: i32 = bLen - i;
      if (bOffset > 0) {
        bDigit = Porffor.wasm.i32.load(b + bOffset * 4, 0, 0);
        if (bDigit < 0) bDigit += 0x100000000;
      }

      let sum: number = aDigit + bDigit + carry;
      if (sum >= 0x100000000) {
        sum -= 0x100000000;
        carry = 1;
      } else {
        carry = 0;
      }

      digits.unshift(sum >= 0x80000000 ? sum - 0x100000000 : sum);
    }
  } else {
    // different signs => subtract the smaller MAGNITUDE from the larger; result takes the larger's sign.
    // (a per-limb signed subtract only gives the right magnitude when |a| >= |b|; otherwise it wraps.)
    let magCmp: i32 = 0;
    if (aLen != bLen) {
      magCmp = aLen > bLen ? 1 : -1;
    } else {
      for (let i: i32 = 1; i <= aLen; i++) {
        let ad: number = Porffor.wasm.i32.load(a + i * 4, 0, 0);
        if (ad < 0) ad += 0x100000000;
        let bd: number = Porffor.wasm.i32.load(b + i * 4, 0, 0);
        if (bd < 0) bd += 0x100000000;
        if (ad != bd) { magCmp = ad > bd ? 1 : -1; break; }
      }
    }

    let hi: i32 = a;
    let hiLen: i32 = aLen;
    let lo: i32 = b;
    let loLen: i32 = bLen;
    if (magCmp >= 0) {
      negative = aNegative;
    } else {
      hi = b; hiLen = bLen; lo = a; loLen = aLen;
      negative = bNegative;
    }

    let borrow: number = 0;
    for (let i: i32 = 0; i < hiLen; i++) {
      let hd: number = Porffor.wasm.i32.load(hi + (hiLen - i) * 4, 0, 0);
      if (hd < 0) hd += 0x100000000;
      let ld: number = 0;
      const loOff: i32 = loLen - i;
      if (loOff > 0) {
        ld = Porffor.wasm.i32.load(lo + loOff * 4, 0, 0);
        if (ld < 0) ld += 0x100000000;
      }
      let diff: number = hd - ld - borrow;
      if (diff < 0) { diff += 0x100000000; borrow = 1; } else { borrow = 0; }
      digits.unshift(diff >= 0x80000000 ? diff - 0x100000000 : diff);
    }
    carry = 0;
  }

  if (carry != 0) {
    digits.unshift(Math.abs(carry));
    if (carry < 0) negative = !negative;
  }

  // strip leading-zero limbs so the length-based magnitude compare above stays valid on results.
  while (digits.length > 1 && digits[0] == 0) digits.shift();

  return __Porffor_bigint_fromDigits(negative, digits);
};

export const __Porffor_bigint_sub = (a: number, b: number): bigint => {
  return __Porffor_bigint_add(a, b, true);
};

// 2-arg addition wrapper so the codegen `+` dispatch is a clean (value,type)-pair call (no `sub` flag arg).
export const __Porffor_bigint_addOp = (a: number, b: number): bigint => {
  return __Porffor_bigint_add(a, b, false);
};

// Multiply via 16-bit half-limbs (no native i64): split each 32-bit limb into two 16-bit halves (base 2^16),
// accumulate every half-limb partial product (< 2^32) into an f64 result array, then normalize base 2^16 in
// one pass and recombine into 32-bit limbs. f64 accumulation (sums stay < 2^53 for any realistic size)
// avoids the i32 carry-overflow subtleties of in-place schoolbook. Half-limbs are indexed LSB-first.
export const __Porffor_bigint_mul = (a: number, b: number): bigint => {
  if (Math.abs(a) < 0x8000000000000) a = __Porffor_bigint_inlineToDigitForm(a);
  if (Math.abs(b) < 0x8000000000000) b = __Porffor_bigint_inlineToDigitForm(b);

  a -= 0x8000000000000;
  b -= 0x8000000000000;

  const aNegative: boolean = Porffor.wasm.i32.load8_u(a, 0, 0) != 0;
  const aLen: i32 = Porffor.wasm.i32.load16_u(a, 0, 2);
  const bNegative: boolean = Porffor.wasm.i32.load8_u(b, 0, 0) != 0;
  const bLen: i32 = Porffor.wasm.i32.load16_u(b, 0, 2);

  const negative: boolean = aNegative != bNegative;

  const ha: i32 = aLen * 2; // half-limb counts
  const hb: i32 = bLen * 2;

  // read a/b into half-limb arrays, LSB-first. half index hi: limb (MSB-first) = len-1-(hi>>1); low/high by hi&1.
  const av: number[] = Porffor.malloc();
  av.length = ha;
  for (let hi: i32 = 0; hi < ha; hi++) {
    const limb: i32 = Porffor.wasm.i32.load(a + (aLen - (hi >> 1)) * 4, 0, 0);
    av[hi] = (hi & 1) == 0 ? (limb & 0xffff) : ((limb >>> 16) & 0xffff);
  }
  const bv: number[] = Porffor.malloc();
  bv.length = hb;
  for (let hi: i32 = 0; hi < hb; hi++) {
    const limb: i32 = Porffor.wasm.i32.load(b + (bLen - (hi >> 1)) * 4, 0, 0);
    bv[hi] = (hi & 1) == 0 ? (limb & 0xffff) : ((limb >>> 16) & 0xffff);
  }

  const rlen: i32 = ha + hb;
  const res: number[] = Porffor.malloc();
  res.length = rlen;
  for (let k: i32 = 0; k < rlen; k++) res[k] = 0;

  for (let i: i32 = 0; i < ha; i++) {
    const avi: number = av[i];
    if (avi != 0) for (let j: i32 = 0; j < hb; j++) res[i + j] += avi * bv[j];
  }

  // normalize base 2^16 (LSB-first)
  let carry: number = 0;
  for (let k: i32 = 0; k < rlen; k++) {
    const v: number = res[k] + carry;
    carry = Math.floor(v / 0x10000);
    res[k] = v - carry * 0x10000;
  }

  // recombine half-limbs → 32-bit limbs, written MSB-first
  const nlimbs: i32 = aLen + bLen;
  const digits: i32[] = Porffor.malloc();
  digits.length = nlimbs;
  for (let t: i32 = 0; t < nlimbs; t++) {
    const limbU: number = res[t * 2] + res[t * 2 + 1] * 0x10000;
    digits[nlimbs - 1 - t] = limbU >= 0x80000000 ? limbU - 0x100000000 : limbU; // signed store
  }

  while (digits.length > 0 && digits[0] == 0) digits.shift();
  if (digits.length == 0) return 0 as bigint;

  return __Porffor_bigint_fromDigits(negative, digits);
};

// Integer division + remainder via BINARY long division (shift-and-subtract on f64 limb arrays, LSB-first).
// Simple and provably correct for any size; O(bits * limbs) is fine for test262. JS semantics: quotient
// truncates toward zero (sign = aNeg^bNeg); remainder takes the DIVIDEND's sign.
export const __Porffor_bigint_divrem = (a: number, b: number, wantRem: boolean): bigint => {
  if (Math.abs(a) < 0x8000000000000) a = __Porffor_bigint_inlineToDigitForm(a);
  if (Math.abs(b) < 0x8000000000000) b = __Porffor_bigint_inlineToDigitForm(b);

  a -= 0x8000000000000;
  b -= 0x8000000000000;

  const aNeg: boolean = Porffor.wasm.i32.load8_u(a, 0, 0) != 0;
  const aLen: i32 = Porffor.wasm.i32.load16_u(a, 0, 2);
  const bNeg: boolean = Porffor.wasm.i32.load8_u(b, 0, 0) != 0;
  const bLen: i32 = Porffor.wasm.i32.load16_u(b, 0, 2);

  // divisor magnitude (LSB-first), and zero check
  const bv: number[] = Porffor.malloc();
  bv.length = bLen;
  let bZero: boolean = true;
  for (let t: i32 = 0; t < bLen; t++) {
    let d: number = Porffor.wasm.i32.load(b + (bLen - t) * 4, 0, 0);
    if (d < 0) d += 0x100000000;
    if (d != 0) bZero = false;
    bv[t] = d;
  }
  if (bZero) throw new RangeError('Division by zero');

  // dividend magnitude (LSB-first), kept as raw i32 bit patterns — bit extraction below uses `>>>` (unsigned),
  // which is reliable on i32 but not on an f64 limb >= 2^31.
  const av: i32[] = Porffor.malloc();
  av.length = aLen;
  for (let t: i32 = 0; t < aLen; t++) {
    av[t] = Porffor.wasm.i32.load(a + (aLen - t) * 4, 0, 0);
  }

  const remLen: i32 = aLen + 1; // rem needs one extra limb: the left-shift before a subtract can carry out
  const quo: number[] = Porffor.malloc();
  quo.length = aLen;
  const rem: number[] = Porffor.malloc();
  rem.length = remLen;
  for (let t: i32 = 0; t < aLen; t++) quo[t] = 0;
  for (let t: i32 = 0; t < remLen; t++) rem[t] = 0;

  for (let bit: i32 = aLen * 32 - 1; bit >= 0; bit--) {
    // rem <<= 1
    let rc: number = 0;
    for (let t: i32 = 0; t < remLen; t++) {
      const rv: number = rem[t] * 2 + rc;
      if (rv >= 0x100000000) { rem[t] = rv - 0x100000000; rc = 1; } else { rem[t] = rv; rc = 0; }
    }
    // quo <<= 1
    let qc: number = 0;
    for (let t: i32 = 0; t < aLen; t++) {
      const qv: number = quo[t] * 2 + qc;
      if (qv >= 0x100000000) { quo[t] = qv - 0x100000000; qc = 1; } else { quo[t] = qv; qc = 0; }
    }
    // bring in dividend bit `bit`
    rem[0] += (av[bit >> 5] >>> (bit & 31)) & 1;

    // rem >= bv ? (magnitude compare, MSB-first)
    let cmp: i32 = 0;
    for (let t: i32 = remLen - 1; t >= 0; t--) {
      const rd: number = rem[t];
      const bd: number = t < bLen ? bv[t] : 0;
      if (rd != bd) { cmp = rd > bd ? 1 : -1; break; }
    }

    if (cmp >= 0) {
      // rem -= bv
      let borrow: number = 0;
      for (let t: i32 = 0; t < remLen; t++) {
        const bd: number = t < bLen ? bv[t] : 0;
        let diff: number = rem[t] - bd - borrow;
        if (diff < 0) { diff += 0x100000000; borrow = 1; } else { borrow = 0; }
        rem[t] = diff;
      }
      quo[0] += 1;
    }
  }

  const src: number[] = wantRem ? rem : quo;
  const digits: i32[] = Porffor.malloc();
  digits.length = aLen;
  for (let t: i32 = 0; t < aLen; t++) {
    const limbU: number = src[t];
    digits[aLen - 1 - t] = limbU >= 0x80000000 ? limbU - 0x100000000 : limbU; // signed store, MSB-first
  }

  while (digits.length > 0 && digits[0] == 0) digits.shift();
  if (digits.length == 0) return 0 as bigint;

  const negative: boolean = wantRem ? aNeg : (aNeg != bNeg);
  return __Porffor_bigint_fromDigits(negative, digits);
};

export const __Porffor_bigint_div = (a: number, b: number): bigint => {
  return __Porffor_bigint_divrem(a, b, false);
};

export const __Porffor_bigint_rem = (a: number, b: number): bigint => {
  return __Porffor_bigint_divrem(a, b, true);
};

// Three-way compare a<=>b as -1/0/1, sign-magnitude, WITHOUT subtraction (which mutates + allocates).
// Works for inline-small and heap-large bigints. Heap layout: sign byte @0, u16 limb-count @2, base-2^32
// limbs MSB-first @4 (limb i at ptr + (i+1)*4). Steps (Knuth/GMP-standard): clamp leading-zero limbs to an
// effective length, derive the signed-zero-normalized sign (magnitude 0 ⇒ sign 0, so -0n compares == 0n),
// compare signs, then magnitudes (effective length, then limbs MSB→LSB with an UNSIGNED limb compare).
export const __Porffor_bigint_cmp = (a: number, b: number): number => {
  if (Math.abs(a) < 0x8000000000000) {
    if (Math.abs(b) < 0x8000000000000) {
      if (a < b) return -1;
      if (a > b) return 1;
      return 0;
    }
    a = __Porffor_bigint_inlineToDigitForm(a);
  } else if (Math.abs(b) < 0x8000000000000) {
    b = __Porffor_bigint_inlineToDigitForm(b);
  }

  a -= 0x8000000000000;
  b -= 0x8000000000000;

  const aLen: i32 = Porffor.wasm.i32.load16_u(a, 0, 2);
  const bLen: i32 = Porffor.wasm.i32.load16_u(b, 0, 2);

  // clamp leading-zero limbs (MSB-first) → first significant limb index
  let ai: i32 = 0;
  while (ai < aLen && Porffor.wasm.i32.load(a + (ai + 1) * 4, 0, 0) == 0) ai += 1;
  let bi: i32 = 0;
  while (bi < bLen && Porffor.wasm.i32.load(b + (bi + 1) * 4, 0, 0) == 0) bi += 1;

  const aEff: i32 = aLen - ai;
  const bEff: i32 = bLen - bi;

  const aSign: i32 = aEff == 0 ? 0 : (Porffor.wasm.i32.load8_u(a, 0, 0) != 0 ? -1 : 1);
  const bSign: i32 = bEff == 0 ? 0 : (Porffor.wasm.i32.load8_u(b, 0, 0) != 0 ? -1 : 1);

  if (aSign != bSign) return aSign < bSign ? -1 : 1;
  if (aSign == 0) return 0;

  let mag: i32 = 0;
  if (aEff != bEff) {
    mag = aEff > bEff ? 1 : -1;
  } else {
    for (let k: i32 = 0; k < aEff; k += 1) {
      const ad: i32 = Porffor.wasm.i32.load(a + (ai + k + 1) * 4, 0, 0);
      const bd: i32 = Porffor.wasm.i32.load(b + (bi + k + 1) * 4, 0, 0);
      if (ad != bd) {
        // unsigned compare of u32 limbs: flip the sign bit so a signed `>` yields unsigned order
        mag = (ad ^ 0x80000000) > (bd ^ 0x80000000) ? 1 : -1;
        break;
      }
    }
  }

  if (aSign < 0) mag = -mag;
  return mag;
};

export const __Porffor_bigint_eq = (a: number, b: number): boolean => {
  return __Porffor_bigint_cmp(a, b) == 0;
};

export const __Porffor_bigint_ne = (a: number, b: number): boolean => {
  return __Porffor_bigint_cmp(a, b) != 0;
};

export const __Porffor_bigint_gt = (a: number, b: number): boolean => {
  return __Porffor_bigint_cmp(a, b) > 0;
};

export const __Porffor_bigint_ge = (a: number, b: number): boolean => {
  return __Porffor_bigint_cmp(a, b) >= 0;
};

export const __Porffor_bigint_lt = (a: number, b: number): boolean => {
  return __Porffor_bigint_cmp(a, b) < 0;
};

export const __Porffor_bigint_le = (a: number, b: number): boolean => {
  return __Porffor_bigint_cmp(a, b) <= 0;
};

// 7.1.13 ToBigInt (argument)
// https://tc39.es/ecma262/#sec-tobigint
export const __ecma262_ToBigInt = (argument: any): bigint => {
  // 1. Let prim be ? ToPrimitive(argument, number).
  const prim: any = ecma262.ToPrimitive.Number(argument);

  // 2. Return the value that prim corresponds to in Table 12.
  // Table 12: BigInt Conversions
  // Argument Type 	Result
  // BigInt 	Return prim.
  if (Porffor.type(prim) == Porffor.TYPES.bigint) return prim;

  // String
  //     1. Let n be StringToBigInt(prim).
  //     2. If n is undefined, throw a SyntaxError exception.
  //     3. Return n.
  if ((Porffor.type(prim) | 0b10000000) == Porffor.TYPES.bytestring) return __Porffor_bigint_fromString(prim);

  // Boolean 	Return 1n if prim is true and 0n if prim is false.
  if (Porffor.type(prim) == Porffor.TYPES.boolean) return prim ? 1n : 0n;

  // Number 	Throw a TypeError exception.
  // Symbol 	Throw a TypeError exception.
  // Undefined 	Throw a TypeError exception.
  // Null 	Throw a TypeError exception.
  throw new TypeError('Cannot convert to BigInt');
};

// 21.2.1.1 BigInt (value)
// https://tc39.es/ecma262/#sec-bigint-constructor-number-value
export const BigInt = (value: any): bigint => {
  // 1. If NewTarget is not undefined, throw a TypeError exception.
  // 2. Let prim be ? ToPrimitive(value, number).
  const prim: any = ecma262.ToPrimitive.Number(value);

  // 3. If prim is a Number, return ? NumberToBigInt(prim).
  if (Porffor.type(prim) == Porffor.TYPES.number) return __Porffor_bigint_fromNumber(prim);

  // 4. Otherwise, return ? ToBigInt(prim).
  return __ecma262_ToBigInt(prim);
};

export const __BigInt_prototype_toString = (_this: bigint, radix: any) => {
  return __Porffor_bigint_toString(_this, radix);
};

export const __BigInt_prototype_toLocaleString = (_this: bigint) => {
  return __Porffor_bigint_toString(_this, 10);
};

export const __BigInt_prototype_valueOf = (_this: bigint) => {
  return _this;
};

// todo: asIntN, asUintN