// @porf --valtype=i32
import type {} from './porffor.d.ts';

// regex memory structure (16):
//  0 @ source string ptr (u32)
//  4 @ flags (u16):
//   g, global - 0b00000001
//   i, ignore case - 0b00000010
//   m, multiline - 0b00000100
//   s, dotall - 0b00001000
//   u, unicode - 0b00010000
//   y, sticky - 0b00100000
//   d, has indices - 0b01000000
//   v, unicode sets - 0b10000000
//  6 @ capture count (u16)
//  8 @ last index (u16)
//  10 @ named-group table ptr (u32, 0 if none): u16 count, then count entries of
//       { u16 groupNum (1-based), u16 nameLen, nameLen bytes }
//  bytecode (variable, starts at +16):
//   op (u8)
//   depends on op (variable)
//   ----------------------------
//   single - 0x01:
//     char (u8)
//   class - 0x02 / negated class - 0x03:
//     length (u8)
//     items (u32[]):
//       RANGE_MARKER (0x00) (u8) + from (u8) + to (u8)
//       CHAR_MARKER (0x01) (u8) + char (u8)
//       PREDEF_MARKER (0x02) (u8) + classId (u8)
//     END_CLASS_MARKER (0xFF) (u8)
//   predefined class - 0x04:
//     class (u8)
//   start (line or string) - 0x05
//   end (line or string) - 0x06
//   word boundary - 0x07
//   non-word boundary - 0x08
//   dot - 0x09
//   back reference - 0x0a:
//     index (u8)
//   lookahead positive - 0x0b:
//     target (u16) - where to jump if lookahead succeeds
//   lookahead negative - 0x0c:
//     target (u16) - where to jump if lookahead fails
//   lookbehind positive - 0x0d / negative - 0x0e (fixed-length):
//     target (u16) - where to jump past the assertion
//     L (u16) - fixed body length; runtime runs the body from sp-L
//   ----------------------------
//   accept - 0x10
//   reject - 0x11
//   ----------------------------
//   jump - 0x20:
//     target (u16)
//   fork - 0x21:
//     branch 1 (u16)
//     branch 2 (u16)
//   ----------------------------
//   start capture - 0x30:
//     index (u8)
//   end capture - 0x31:
//     index (u8)

export const __Porffor_array_fastPushI32 = (arr: any[], el: any): i32 => {
  let len: i32 = arr.length;
  arr[len] = el;
  arr.length = ++len;
  return len;
};

export const __Porffor_array_fastPopI32 = (arr: any[]): i32 => {
  let len: i32 = arr.length;
  const ret: any = arr[--len];
  arr.length = len;
  return ret;
};

export const __Porffor_regex_hexDigitToValue = (char: i32): i32 => {
  if (char >= 48 && char <= 57) return char - 48; // '0'-'9'
  if (char >= 97 && char <= 102) return char - 87; // 'a'-'f'
  if (char >= 65 && char <= 70) return char - 55; // 'A'-'F'
  throw new SyntaxError('Regex parse: invalid hex digit');
};

export const __Porffor_regex_isHexDigit = (char: i32): boolean => {
  return (char >= 48 && char <= 57) || (char >= 97 && char <= 102) || (char >= 65 && char <= 70);
};

// Look a name up in a compiled regex's named-group table; returns the 1-based group number, or 0 if the
// table is absent or the name is not present. Shared by `\k<name>` resolution (compile) and `.groups`
// construction (exec).
export const __Porffor_regex_lookupName = (namesPtr: i32, namePtr: i32, nameLen: i32): i32 => {
  if (namesPtr == 0) return 0;
  const count: i32 = Porffor.wasm.i32.load16_u(namesPtr, 0, 0);
  let p: i32 = namesPtr + 2;
  for (let e: i32 = 0; e < count; e++) {
    const g: i32 = Porffor.wasm.i32.load16_u(p, 0, 0);
    const l: i32 = Porffor.wasm.i32.load16_u(p, 0, 2);
    p += 4;
    if (l == nameLen) {
      let same: boolean = true;
      // Table bytes are raw (offset 0); namePtr is a WIDE patW pattern pointer (2 bytes/code-unit, char data
      // at offset 4) — compare its low byte against the (ASCII) table byte.
      for (let k: i32 = 0; k < l; k++) {
        if (Porffor.wasm.i32.load8_u(p + k, 0, 0) != Porffor.wasm.i32.load16_u(namePtr + k*2, 0, 4)) { same = false; break; }
      }
      if (same) return g;
    }
    p += l;
  }
  return 0;
};

// Compute the fixed match length of a sub-pattern (bytestring-relative pointers [start, end); chars at
// offset 4), or -1 if the sub-pattern can match variable lengths (`*` `+` `?` `{n,}` `{n,m}` with n≠m, or an
// alternation whose branches differ). Used to support fixed-length lookbehind — the common, tractable case —
// while honestly rejecting variable-length lookbehind (which needs true reverse matching).
export const __Porffor_regex_fixedLen = (start: i32, end: i32): i32 => {
  let i: i32 = start;
  let branchLen: i32 = 0; // fixed length accumulated in the current alternative
  let settled: i32 = -1;  // agreed length of prior alternatives (-1 = none yet)
  let prevLen: i32 = -1;  // length the last atom contributed (so a following quantifier can repeat it)
  while (i < end) {
    let c: i32 = Porffor.wasm.i32.load16_u(i, 0, 4);
    i += 2;

    if (c == 92) { // escape: \X
      if (i >= end) return -1;
      const e: i32 = Porffor.wasm.i32.load16_u(i, 0, 4);
      i += 2;
      if (e == 98 || e == 66) { prevLen = 0; } // \b \B are zero-width
      else { branchLen += 1; prevLen = 1; }    // \d \w \n \1 … each consume one
      continue;
    }
    if (c == 124) { // '|'
      if (settled == -1) settled = branchLen;
      else if (settled != branchLen) return -1;
      branchLen = 0; prevLen = -1;
      continue;
    }
    if (c == 40) { // '(' — measure the group body and recurse
      let bodyStart: i32 = i;
      let zeroWidth: boolean = false;
      if (i < end && Porffor.wasm.i32.load16_u(i, 0, 4) == 63) { // '?'
        const n2: i32 = (i + 2) < end ? Porffor.wasm.i32.load16_u(i, 0, 6) : 0;
        if (n2 == 58) { bodyStart = i + 4; } // (?:
        else if (n2 == 61 || n2 == 33) { zeroWidth = true; } // (?= (?!
        else if (n2 == 60) { // (?<… : lookbehind (zero-width) or named group
          const n3: i32 = (i + 4) < end ? Porffor.wasm.i32.load16_u(i, 0, 8) : 0;
          if (n3 == 61 || n3 == 33) { zeroWidth = true; }
          else { let j: i32 = i + 4; while (j < end && Porffor.wasm.i32.load16_u(j, 0, 4) != 62) j += 2; bodyStart = j + 2; }
        }
      }
      // find the matching ')'
      let dpth: i32 = 1;
      let k: i32 = i;
      let kEsc: boolean = false;
      let kClass: boolean = false;
      while (k < end && dpth > 0) {
        const kc: i32 = Porffor.wasm.i32.load16_u(k, 0, 4);
        if (kEsc) { kEsc = false; k += 2; continue; }
        if (kc == 92) { kEsc = true; k += 2; continue; }
        if (kClass) { if (kc == 93) kClass = false; k += 2; continue; }
        if (kc == 91) { kClass = true; k += 2; continue; }
        if (kc == 40) dpth += 1;
          else if (kc == 41) dpth -= 1;
        k += 2;
      }
      const closeParen: i32 = k - 2;
      i = k;
      let glen: i32 = 0;
      if (!zeroWidth) {
        glen = __Porffor_regex_fixedLen(bodyStart, closeParen);
        if (glen < 0) return -1;
      }
      branchLen += glen;
      prevLen = glen;
      continue;
    }
    if (c == 91) { // '[' char class — one atom; skip to ']'
      let kEsc: boolean = false;
      while (i < end) {
        const kc: i32 = Porffor.wasm.i32.load16_u(i, 0, 4);
        i += 2;
        if (kEsc) { kEsc = false; continue; }
        if (kc == 92) { kEsc = true; continue; }
        if (kc == 93) break;
      }
      branchLen += 1; prevLen = 1;
      continue;
    }
    if (c == 94 || c == 36) { prevLen = 0; continue; } // ^ $ zero-width
    if (c == 42 || c == 43 || c == 63) return -1; // * + ? → variable
    if (c == 123) { // '{' — {n} / {n,} / {n,m}
      let n: i32 = 0; let m: i32 = 0;
      let sawN: boolean = false; let sawM: boolean = false; let hasComma: boolean = false; let ok: boolean = true; let closed: boolean = false;
      while (i < end) {
        const dc: i32 = Porffor.wasm.i32.load16_u(i, 0, 4);
        if (dc >= 48 && dc <= 57) { if (hasComma) { m = m * 10 + (dc - 48); sawM = true; } else { n = n * 10 + (dc - 48); sawN = true; } i += 2; }
        else if (dc == 44) { hasComma = true; i += 2; }
        else if (dc == 125) { i += 2; closed = true; break; }
        else { ok = false; break; }
      }
      if (!ok || !closed || !sawN) { branchLen += 1; prevLen = 1; continue; } // literal '{'
      if (prevLen < 0) return -1;
      let reps: i32 = n;
      if (hasComma) { if (!sawM || n != m) return -1; reps = n; } // {n,} or {n,m} n≠m → variable
      branchLen += prevLen * (reps - 1); // the atom was already counted once
      prevLen = 0;
      continue;
    }
    branchLen += 1; prevLen = 1; // ordinary literal char (incl. '.')
  }
  if (settled == -1) return branchLen;
  if (settled != branchLen) return -1;
  return settled;
};

// Map a \p{Name} general-category name (bytestring-relative ptr, chars at offset 4) to the POSITIVE
// predefined classId (odd; negation is +1). Returns 0 for an unsupported name. Short category names plus a
// couple of long aliases; matching is byte/Latin1-domain (same scope as \d\w\s).
export const __Porffor_regex_propClass = (ptr: i32, len: i32): i32 => {
  if (len == 1) {
    const c0: i32 = Porffor.wasm.i32.load16_u(ptr, 0, 4);
    if (c0 == 76) return 7;  // L
    if (c0 == 78) return 9;  // N
    if (c0 == 80) return 15; // P
  } else if (len == 2) {
    const c0: i32 = Porffor.wasm.i32.load16_u(ptr, 0, 4);
    const c1: i32 = Porffor.wasm.i32.load16_u(ptr + 2, 0, 4);
    if (c0 == 76 && c1 == 117) return 11; // Lu
    if (c0 == 76 && c1 == 108) return 13; // Ll
    if (c0 == 78 && c1 == 100) return 9;  // Nd → N
  }
  return 0;
};

// Latin1-domain general-category test for the positive classId. Correct for byte/ASCII+Latin1 input (the
// engine's domain); astral code points need UTF-16 wide reads (the same tracked limitation as char classes).
// Read the code unit at logical position p of the input. Narrow (bytestring/Latin1) inputs are 1 byte/char;
// wide (UTF-16 string) inputs are 2 bytes/code-unit. Keeping sp in CODE UNITS for both lets the byte engine
// match UTF-16 (incl. astral surrogate pairs) just by widening the read.
export const __Porffor_regex_cu = (input: i32, p: i32, wide: boolean): i32 => {
  if (wide) return Porffor.wasm.i32.load16_u(input + (p << 1), 0, 4);
  return Porffor.wasm.i32.load8_u(input + p, 0, 4);
};

export const __Porffor_regex_isProp = (c: i32, id: i32): boolean => {
  if (id == 7) // L (letter)
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 0xC0 && c <= 0xFF && c != 0xD7 && c != 0xF7) || c == 0xAA || c == 0xB5 || c == 0xBA;
  if (id == 9) return c >= 48 && c <= 57; // N (decimal digit)
  if (id == 11) return (c >= 65 && c <= 90) || (c >= 0xC0 && c <= 0xDE && c != 0xD7); // Lu
  if (id == 13) return (c >= 97 && c <= 122) || (c >= 0xDF && c <= 0xFF && c != 0xF7); // Ll
  if (id == 15) // P (punctuation, ASCII)
    return (c >= 33 && c <= 47) || (c >= 58 && c <= 64) || (c >= 91 && c <= 96) || (c >= 123 && c <= 126);
  return false;
};

export const __Porffor_regex_compile = (patternStr: bytestring, flagsStr: bytestring): RegExp => {
  // Bytecode grows with the pattern (alternation forks, inline {n,m} atom copies, etc). A fixed 64KB page
  // overflows on large composite patterns (e.g. marked's block grammar), so size the buffer to the pattern.
  const ptr: i32 = Porffor.malloc(patternStr.length * 64 + 131072);
  Porffor.wasm.i32.store(ptr, patternStr, 0, 0);

  // Normalize the pattern into a uniform WIDE (16-bit-per-code-unit) scratch buffer. Porffor may pass the
  // pattern as a narrow bytestring (1 byte/char) OR a wide string (2 bytes/code-unit, e.g. acorn's
  // identifier regexes containing code points > 255). The parser below reads every pattern char/peek as a
  // u16 from patW (char data at offset 4, length u32 at offset 0), so it stays in sync regardless of the
  // incoming width. (The original patternStr pointer stored at ptr+0 is what `.source` returns — unchanged.)
  const patLen: i32 = patternStr.length;
  const patW: i32 = Porffor.malloc(6 + patLen * 2);
  Porffor.wasm.i32.store(patW, patLen, 0, 0);
  if (Porffor.wasm`local.get ${patternStr+1}` == Porffor.TYPES.bytestring) {
    for (let i: i32 = 0; i < patLen; i++) {
      Porffor.wasm.i32.store16(patW + i*2, Porffor.wasm.i32.load8_u(Porffor.wasm`local.get ${patternStr}` + i, 0, 4), 0, 4);
    }
  } else {
    for (let i: i32 = 0; i < patLen; i++) {
      Porffor.wasm.i32.store16(patW + i*2, Porffor.wasm.i32.load16_u(Porffor.wasm`local.get ${patternStr}` + i*2, 0, 4), 0, 4);
    }
  }

  // parse flags
  let flags: i32 = 0;
  let flagsPtr: i32 = flagsStr;
  const flagsEndPtr: i32 = flagsPtr + flagsStr.length;
  while (flagsPtr < flagsEndPtr) {
    const char: i32 = Porffor.wasm.i32.load8_u(flagsPtr, 0, 4);
    flagsPtr += 1;

    if (char == 103) { // g
      flags |= 0b00000001;
      continue;
    }
    if (char == 105) { // i
      flags |= 0b00000010;
      continue;
    }
    if (char == 109) { // m
      flags |= 0b00000100;
      continue;
    }
    if (char == 115) { // s
      flags |= 0b00001000;
      continue;
    }
    if (char == 117) { // u
      if (flags & 0b10000000) throw new SyntaxError('Regex parse: Conflicting unicode flag');
      flags |= 0b00010000;
      continue;
    }
    if (char == 121) { // y
      flags |= 0b00100000;
      continue;
    }
    if (char == 100) { // d
      flags |= 0b01000000;
      continue;
    }
    if (char == 118) { // v
      if (flags & 0b00010000) throw new SyntaxError('Regex parse: Conflicting unicode flag');
      flags |= 0b10000000;
      continue;
    }

    throw new SyntaxError('Regex parse: Invalid flag');
  }
  Porffor.wasm.i32.store16(ptr, flags, 0, 4);

  // Pre-scan for named groups `(?<name>…)`. Capturing groups are numbered by opening-paren order (named and
  // unnamed alike), so this must count every capturing paren — skipping escapes, char classes, and the
  // non-capturing/look-around forms — and record name→number for the named ones. Resolving forward `\k<name>`
  // references and building the exec-time `.groups` object both read this table. Only allocated when at least
  // one named group is present (keeps the common case a single malloc lighter).
  let namesPtr: i32 = 0;
  {
    let dp: i32 = patW;
    const dpe: i32 = dp + patLen * 2;
    let hasNamed: boolean = false;
    let dEsc: boolean = false;
    let dClass: boolean = false;
    while (dp < dpe) {
      const dc: i32 = Porffor.wasm.i32.load16_u(dp, 0, 4);
      if (dEsc) { dEsc = false; dp += 2; continue; }
      if (dc == 92) { dEsc = true; dp += 2; continue; } // '\'
      if (dClass) { if (dc == 93) dClass = false; dp += 2; continue; } // inside [...]
      if (dc == 91) { dClass = true; dp += 2; continue; } // '['
      if (dc == 40 && (dp + 6) < dpe &&
          Porffor.wasm.i32.load16_u(dp, 0, 6) == 63 && // '?'
          Porffor.wasm.i32.load16_u(dp, 0, 8) == 60) { // '<'
        const a: i32 = Porffor.wasm.i32.load16_u(dp, 0, 10);
        if (a != 61 && a != 33) { hasNamed = true; break; } // not (?<= / (?<!
      }
      dp += 2;
    }

    if (hasNamed) {
      namesPtr = Porffor.malloc(patLen * 4 + 16);
      let nameCount: i32 = 0;
      let nameWrite: i32 = namesPtr + 2;
      let pp: i32 = patW;
      const pe: i32 = pp + patLen * 2;
      let grp: i32 = 0;
      let pEsc: boolean = false;
      let pClass: boolean = false;
      while (pp < pe) {
        const c: i32 = Porffor.wasm.i32.load16_u(pp, 0, 4);
        if (pEsc) { pEsc = false; pp += 2; continue; }
        if (c == 92) { pEsc = true; pp += 2; continue; }
        if (pClass) { if (c == 93) pClass = false; pp += 2; continue; }
        if (c == 91) { pClass = true; pp += 2; continue; }
        if (c == 40) { // '('
          const n1: i32 = (pp + 2) < pe ? Porffor.wasm.i32.load16_u(pp, 0, 6) : 0;
          if (n1 == 63) { // '?'
            const n2: i32 = (pp + 4) < pe ? Porffor.wasm.i32.load16_u(pp, 0, 8) : 0;
            if (n2 == 60) { // '<'
              const n3: i32 = (pp + 6) < pe ? Porffor.wasm.i32.load16_u(pp, 0, 10) : 0;
              if (n3 == 61 || n3 == 33) { pp += 2; continue; } // lookbehind, not capturing
              // named capture group
              grp += 1;
              let np: i32 = pp + 6;
              const nameStart: i32 = np;
              while (np < pe && Porffor.wasm.i32.load16_u(np, 0, 4) != 62) np += 2;
              const nameLen: i32 = (np - nameStart) >> 1; // code-unit count
              Porffor.wasm.i32.store16(nameWrite, grp, 0, 0);
              Porffor.wasm.i32.store16(nameWrite, nameLen, 0, 2);
              nameWrite += 4;
              // Names are stored in the table as BYTES (low byte of each code unit) so the match-time
              // comparison (load8_u(namePtr+k,0,4) against `.groups`) and nameLen semantics are unchanged.
              // Names are ASCII in practice, so the low-byte transcode is lossless.
              for (let k: i32 = 0; k < nameLen; k++) {
                Porffor.wasm.i32.store8(nameWrite + k, Porffor.wasm.i32.load16_u(nameStart + k*2, 0, 4), 0, 0);
              }
              nameWrite += nameLen;
              nameCount += 1;
              pp = np; // sit on '>'
              continue;
            }
            // (?: (?= (?! etc — non-capturing
            pp += 2;
            continue;
          }
          // plain capturing group
          grp += 1;
          pp += 2;
          continue;
        }
        pp += 2;
      }
      Porffor.wasm.i32.store16(namesPtr, nameCount, 0, 0);
    }
  }
  Porffor.wasm.i32.store(ptr, namesPtr, 0, 10);

  let bcPtr: i32 = ptr + 16;
  const bcStart: i32 = bcPtr;
  let patternPtr: i32 = patW;
  let patternEndPtr: i32 = patternPtr + patLen * 2;

  let lastWasAtom: boolean = false;
  let lastAtomStart: i32 = 0;
  let classPtr: i32 = 0;
  let classLength: i32 = 0;
  let captureIndex: i32 = 0;

  let groupDepth: i32 = 0;
  // todo: free all at the end (or statically allocate but = [] causes memory corruption)
  const groupStack: i32[] = Porffor.malloc(6144);
  const altDepth: i32[] = Porffor.malloc(6144); // number of |s so far at each depth
  const altStack: i32[] = Porffor.malloc(6144);
  // Start bytecode offset of the CURRENT alternative at each group depth. The 2nd+ `|` in an alternation
  // must fork at the start of its alternative — not `lastAtomStart`, which points at the LAST atom and so
  // split a multi-character alternative wrong (e.g. /ab|cd|$/ mis-forked "cd").
  const altCurStart: i32[] = Porffor.malloc(6144);
  altCurStart[0] = bcStart;

  while (patternPtr < patternEndPtr) {
    let char: i32 = Porffor.wasm.i32.load16_u(patternPtr, 0, 4);
    patternPtr = patternPtr + 2;

    // escape
    let notEscaped: boolean = true;
    if (char == 92) { // '\'
      notEscaped = false;
      if (patternPtr >= patternEndPtr) throw new SyntaxError('Regex parse: trailing \\');

      char = Porffor.wasm.i32.load16_u(patternPtr, 0, 4);
      patternPtr = patternPtr + 2;
    }

    if (classPtr) {
      if (notEscaped && char == 93) { // ']'
        // set class length
        Porffor.wasm.i32.store8(classPtr, classLength, 0, 1);

        // end class
        Porffor.wasm.i32.store8(bcPtr, 0xFF, 0, 0);
        bcPtr += 1;

        classPtr = 0;
        lastWasAtom = true;
        continue;
      }

      // class escape
      let v: i32 = char;
      let predefClassId: i32 = 0;
      if (!notEscaped) {
        if (char == 100) predefClassId = 1; // \d
        else if (char == 68) predefClassId = 2; // \D
        else if (char == 115) predefClassId = 3; // \s
        else if (char == 83) predefClassId = 4; // \S
        else if (char == 119) predefClassId = 5; // \w
        else if (char == 87) predefClassId = 6; // \W
        else if (char == 110) v = 10; // \n
        else if (char == 114) v = 13; // \r
        else if (char == 116) v = 9; // \t
        else if (char == 118) v = 11; // \v
        else if (char == 102) v = 12; // \f
        else if (char == 48) v = 0; // \0
        else if (char == 120) { // \x
          if (patternPtr + 2 >= patternEndPtr) throw new SyntaxError('Regex parse: invalid \\x escape');
          const c1: i32 = Porffor.wasm.i32.load16_u(patternPtr, 0, 4); patternPtr += 2;
          const c2: i32 = Porffor.wasm.i32.load16_u(patternPtr, 0, 4); patternPtr += 2;

          v = __Porffor_regex_hexDigitToValue(c1) * 16 + __Porffor_regex_hexDigitToValue(c2);
        } else if (char == 117) { // \u
          const uniFlag: boolean = (flags & 0b00010000) != 0 || (flags & 0b10000000) != 0;
          const nx: i32 = patternPtr < patternEndPtr ? Porffor.wasm.i32.load16_u(patternPtr, 0, 4) : 0;
          if (uniFlag && nx == 123) { // \u{H+} — only valid with the u/v flag
            patternPtr += 2; // past '{'
            v = 0;
            while (patternPtr < patternEndPtr) {
              const hc: i32 = Porffor.wasm.i32.load16_u(patternPtr, 0, 4);
              if (hc == 125) { patternPtr += 2; break; } // '}'
              v = v * 16 + __Porffor_regex_hexDigitToValue(hc);
              patternPtr += 2;
            }
          } else if (patternPtr + 6 < patternEndPtr &&
                     __Porffor_regex_isHexDigit(Porffor.wasm.i32.load16_u(patternPtr, 0, 4)) &&
                     __Porffor_regex_isHexDigit(Porffor.wasm.i32.load16_u(patternPtr, 0, 6)) &&
                     __Porffor_regex_isHexDigit(Porffor.wasm.i32.load16_u(patternPtr, 0, 8)) &&
                     __Porffor_regex_isHexDigit(Porffor.wasm.i32.load16_u(patternPtr, 0, 10))) {
            const c1: i32 = Porffor.wasm.i32.load16_u(patternPtr, 0, 4); patternPtr += 2;
            const c2: i32 = Porffor.wasm.i32.load16_u(patternPtr, 0, 4); patternPtr += 2;
            const c3: i32 = Porffor.wasm.i32.load16_u(patternPtr, 0, 4); patternPtr += 2;
            const c4: i32 = Porffor.wasm.i32.load16_u(patternPtr, 0, 4); patternPtr += 2;

            v = __Porffor_regex_hexDigitToValue(c1) * 4096 + __Porffor_regex_hexDigitToValue(c2) * 256 + __Porffor_regex_hexDigitToValue(c3) * 16 + __Porffor_regex_hexDigitToValue(c4);
          } else {
            // not a valid \uXXXX / \u{...} — per Annex B, a lone \u is a literal 'u'
            v = 117;
          }
        } else if (char == 99) { // \c
          if (patternPtr >= patternEndPtr) {
            // No character after \c, treat as literal \c
            v = char;
          } else {
            const ctrlChar: i32 = Porffor.wasm.i32.load16_u(patternPtr, 0, 4);
            if ((ctrlChar >= 65 && ctrlChar <= 90) || (ctrlChar >= 97 && ctrlChar <= 122)) {
              patternPtr += 2;
              v = ctrlChar & 0x1F;
            } else {
              // Invalid control character, treat as literal \c
              v = char;
            }
          }
        }
      }

      if ((patternPtr + 2) < patternEndPtr && Porffor.wasm.i32.load16_u(patternPtr, 0, 4) == 45 && Porffor.wasm.i32.load16_u(patternPtr, 0, 6) != 93) {
        // possible range
        patternPtr += 2;
        let endChar: i32;
        let endNotEscaped: boolean = true;
        if (patternPtr < patternEndPtr && Porffor.wasm.i32.load16_u(patternPtr, 0, 4) == 92) {
          endNotEscaped = false;
          patternPtr += 2;
          if (patternPtr >= patternEndPtr) throw new SyntaxError('Regex parse: trailing \\ in range');
        }

        endChar = Porffor.wasm.i32.load16_u(patternPtr, 0, 4);
        patternPtr += 2;

        let endPredefClassId: i32 = 0;
        if (!endNotEscaped) {
          if (endChar == 100) endPredefClassId = 1;
            else if (endChar == 68) endPredefClassId = 2;
            else if (endChar == 115) endPredefClassId = 3;
            else if (endChar == 83) endPredefClassId = 4;
            else if (endChar == 119) endPredefClassId = 5;
            else if (endChar == 87) endPredefClassId = 6;
            else if (endChar == 110) endChar = 10;
            else if (endChar == 114) endChar = 13;
            else if (endChar == 116) endChar = 9;
            else if (endChar == 118) endChar = 11;
            else if (endChar == 102) endChar = 12;
            else if (endChar == 48) endChar = 0;
            else if (endChar == 120) { // \x
              if (patternPtr + 2 >= patternEndPtr) throw new SyntaxError('Regex parse: invalid \\x escape');
              const c1: i32 = Porffor.wasm.i32.load16_u(patternPtr, 0, 4); patternPtr += 2;
              const c2: i32 = Porffor.wasm.i32.load16_u(patternPtr, 0, 4); patternPtr += 2;

              endChar = __Porffor_regex_hexDigitToValue(c1) * 16 + __Porffor_regex_hexDigitToValue(c2);
            } else if (endChar == 117) { // \u
               if (patternPtr + 6 >= patternEndPtr) throw new SyntaxError('Regex parse: invalid \\u escape');
               const c1: i32 = Porffor.wasm.i32.load16_u(patternPtr, 0, 4); patternPtr += 2;
               const c2: i32 = Porffor.wasm.i32.load16_u(patternPtr, 0, 4); patternPtr += 2;
               const c3: i32 = Porffor.wasm.i32.load16_u(patternPtr, 0, 4); patternPtr += 2;
               const c4: i32 = Porffor.wasm.i32.load16_u(patternPtr, 0, 4); patternPtr += 2;

               endChar = __Porffor_regex_hexDigitToValue(c1) * 4096 + __Porffor_regex_hexDigitToValue(c2) * 256 + __Porffor_regex_hexDigitToValue(c3) * 16 + __Porffor_regex_hexDigitToValue(c4);
            } else if (endChar == 99) { // \c
              if (patternPtr >= patternEndPtr) {
                // No character after \c, treat as literal \c
                endChar = endChar;
              } else {
                const ctrlChar: i32 = Porffor.wasm.i32.load16_u(patternPtr, 0, 4);
                if ((ctrlChar >= 65 && ctrlChar <= 90) || (ctrlChar >= 97 && ctrlChar <= 122)) {
                  patternPtr += 2;
                  endChar = ctrlChar & 0x1F;
                } else {
                  // Invalid control character, treat as literal \c
                  endChar = endChar;
                }
              }
            }
        }

        // If either side is a predefined class, treat as literal chars
        if (predefClassId > 0 || endPredefClassId > 0) {
          // emit start char/predef
          if (predefClassId > 0) {
            Porffor.wasm.i32.store8(bcPtr, 0x02, 0, 0); // PREDEF_MARKER
            Porffor.wasm.i32.store8(bcPtr, predefClassId, 0, 1);
          } else {
            Porffor.wasm.i32.store8(bcPtr, 0x01, 0, 0); // CHAR_MARKER
            Porffor.wasm.i32.store8(bcPtr, v, 0, 1);
          }
          bcPtr += 4;

          // emit hyphen
          Porffor.wasm.i32.store8(bcPtr, 0x01, 0, 0); // CHAR_MARKER
          Porffor.wasm.i32.store8(bcPtr, 45, 0, 1);
          bcPtr += 4;

          // emit end char/predef
          if (endPredefClassId > 0) {
            Porffor.wasm.i32.store8(bcPtr, 0x02, 0, 0); // PREDEF_MARKER
            Porffor.wasm.i32.store8(bcPtr, endPredefClassId, 0, 1);
          } else {
            Porffor.wasm.i32.store8(bcPtr, 0x01, 0, 0); // CHAR_MARKER
            Porffor.wasm.i32.store8(bcPtr, endChar, 0, 1);
          }

          classLength += 2;
        } else {
          if (v > endChar) throw new SyntaxError('Regex parse: invalid range');

          // Class entries store endpoints in a single byte and the matcher reads input one byte at a time,
          // so a code point > 255 (e.g.  ) cannot be represented and must NEVER falsely match a byte.
          // The byte-truncation bug (  → 0x00) made `[ -⁯]` match all ASCII. Correct behaviour
          // for byte/ASCII input: a range wholly above the byte range matches nothing; a range straddling 255
          // clamps its top to 255. (Full >255 matching against UTF-16 string inputs needs wide reads — tracked.)
          Porffor.wasm.i32.store8(bcPtr, 0x00, 0, 0); // RANGE_MARKER
          if (v > 255) {
            // entire range above the byte range → empty (from=1 > to=0 never matches)
            Porffor.wasm.i32.store8(bcPtr, 1, 0, 1);
            Porffor.wasm.i32.store8(bcPtr, 0, 0, 2);
          } else {
            const to8: i32 = endChar > 255 ? 255 : endChar;
            Porffor.wasm.i32.store8(bcPtr, v, 0, 1);
            Porffor.wasm.i32.store8(bcPtr, to8, 0, 2);
          }
        }

        bcPtr += 4;
        classLength++;
        continue;
      }

      // store v as char or predefined
      if (predefClassId > 0) {
        Porffor.wasm.i32.store8(bcPtr, 0x02, 0, 0); // PREDEF_MARKER
        Porffor.wasm.i32.store8(bcPtr, predefClassId, 0, 1);
      } else if (v > 255) {
        // a single class member above the byte range can never match byte input → empty range
        Porffor.wasm.i32.store8(bcPtr, 0x00, 0, 0); // RANGE_MARKER
        Porffor.wasm.i32.store8(bcPtr, 1, 0, 1);
        Porffor.wasm.i32.store8(bcPtr, 0, 0, 2);
      } else {
        Porffor.wasm.i32.store8(bcPtr, 0x01, 0, 0); // CHAR_MARKER
        Porffor.wasm.i32.store8(bcPtr, v, 0, 1);
      }

      bcPtr += 4;
      classLength++;
      continue;
    }

    if (notEscaped) {
      if (char == 91) { // '['
        lastAtomStart = bcPtr;
        classPtr = bcPtr;
        classLength = 0;
        if (patternPtr < patternEndPtr && Porffor.wasm.i32.load16_u(patternPtr, 0, 4) == 94) {
          patternPtr += 2;

          // negated
          Porffor.wasm.i32.store8(bcPtr, 0x03, 0, 0);
          bcPtr += 2;
          continue;
        }

        // not negated
        Porffor.wasm.i32.store8(bcPtr, 0x02, 0, 0);
        bcPtr += 2;
        continue;
      }

      if (char == 40) { // '('
        lastAtomStart = bcPtr;

        // Check for special group types
        let ncg: boolean = false;
        let isLookahead: boolean = false;
        let isNegativeLookahead: boolean = false;
        let isLookbehind: boolean = false;
        let isNegativeLookbehind: boolean = false;
        let lookbehindLen: i32 = 0;

        if (patternPtr < patternEndPtr && Porffor.wasm.i32.load16_u(patternPtr, 0, 4) == 63) { // '?'
          if ((patternPtr + 2) < patternEndPtr) {
            const nextChar = Porffor.wasm.i32.load16_u(patternPtr, 0, 6);
            if (nextChar == 58) { // ':' - non-capturing group
              ncg = true;
              patternPtr += 4;
            } else if (nextChar == 61) { // '=' - positive lookahead
              isLookahead = true;
              patternPtr += 4;
            } else if (nextChar == 33) { // '!' - negative lookahead
              isLookahead = true;
              isNegativeLookahead = true;
              patternPtr += 4;
            } else if (nextChar == 60) { // '<' - lookbehind or named capture group
              const after: i32 = (patternPtr + 4) < patternEndPtr ? Porffor.wasm.i32.load16_u(patternPtr, 0, 8) : 0;
              if (after == 61 || after == 33) {
                // (?<=...) / (?<!...) fixed-length lookbehind. Measure the body's fixed length by scanning to
                // the matching ')'; emit a lookbehind op that runs the body forward from sp-L (so a fixed body
                // lands exactly at sp). Variable-length lookbehind needs true reverse matching — rejected
                // honestly rather than mis-matched.
                isLookbehind = true;
                isNegativeLookbehind = after == 33;
                patternPtr += 6; // past '?<=' / '?<!'
                let lbDepth: i32 = 1;
                let q: i32 = patternPtr;
                let qEsc: boolean = false;
                let qClass: boolean = false;
                while (q < patternEndPtr && lbDepth > 0) {
                  const qc: i32 = Porffor.wasm.i32.load16_u(q, 0, 4);
                  if (qEsc) { qEsc = false; q += 2; continue; }
                  if (qc == 92) { qEsc = true; q += 2; continue; }
                  if (qClass) { if (qc == 93) qClass = false; q += 2; continue; }
                  if (qc == 91) { qClass = true; q += 2; continue; }
                  if (qc == 40) lbDepth += 1;
                    else if (qc == 41) lbDepth -= 1;
                  q += 2;
                }
                lookbehindLen = __Porffor_regex_fixedLen(patternPtr, q - 2);
                if (lookbehindLen < 0) throw new SyntaxError('Regex parse: variable-length lookbehind not supported');
              } else {
              // (?<name>...) named capture group: skip the name, then treat as a normal capture
              // group (numbered access + $n substitution work; the `.groups` name map is a TODO).
              patternPtr += 4; // past '?<'
              while (patternPtr < patternEndPtr && Porffor.wasm.i32.load16_u(patternPtr, 0, 4) != 62) patternPtr += 2;
              if (patternPtr < patternEndPtr) patternPtr += 2; // past '>'
              }
            }
          }
        }

        Porffor.array.fastPushI32(groupStack, lastAtomStart);

        if (isLookahead) {
          // Generate lookahead opcodes
          if (isNegativeLookahead) {
            Porffor.wasm.i32.store8(bcPtr, 0x0c, 0, 0); // lookahead negative
          } else {
            Porffor.wasm.i32.store8(bcPtr, 0x0b, 0, 0); // lookahead positive
          }

          // Store placeholder for target address (will be filled when we see closing paren)
          const lookaheadJumpPtr: i32 = bcPtr + 1;
          Porffor.wasm.i32.store16(bcPtr, 0, 0, 1);
          bcPtr += 3;

          // Store jump address on stack to fill in later, and special marker
          Porffor.array.fastPushI32(groupStack, lookaheadJumpPtr);
          Porffor.array.fastPushI32(groupStack, isNegativeLookahead ? -2 : -3);
          groupDepth += 1;
          // Record the alternation scope start for this depth = the lookahead BODY start (after the 0x0b op).
          // (altCurStart, not altStack — altStack is a pure push/pop jump-target stack; mixing fixed-index
          // scope writes into it collided with pushed jump targets once a body had several `|`s.)
          if (groupDepth < 6144) altCurStart[groupDepth] = bcPtr;
        } else if (isLookbehind) {
          // header: op (u8) + jump placeholder (u16) + fixed body length L (u16). Runtime moves sp back by L,
          // runs the body forward (lands exactly at the original sp for a fixed body), then asserts/continues.
          if (isNegativeLookbehind) {
            Porffor.wasm.i32.store8(bcPtr, 0x0e, 0, 0); // lookbehind negative
          } else {
            Porffor.wasm.i32.store8(bcPtr, 0x0d, 0, 0); // lookbehind positive
          }
          const lookbehindJumpPtr: i32 = bcPtr + 1;
          Porffor.wasm.i32.store16(bcPtr, 0, 0, 1); // jump placeholder, filled at ')'
          Porffor.wasm.i32.store16(bcPtr, lookbehindLen, 0, 3); // L
          bcPtr += 5;

          Porffor.array.fastPushI32(groupStack, lookbehindJumpPtr);
          Porffor.array.fastPushI32(groupStack, isNegativeLookbehind ? -5 : -4);
          groupDepth += 1;
          if (groupDepth < 6144) altCurStart[groupDepth] = bcPtr;
        } else {
          groupDepth += 1;
          // Store the alternation scope start for this group depth.
          if (groupDepth < 6144) altCurStart[groupDepth] = bcPtr;
          if (!ncg) {
            Porffor.wasm.i32.store8(bcPtr, 0x30, 0, 0); // start capture
            Porffor.wasm.i32.store8(bcPtr, captureIndex, 0, 1);
            bcPtr += 2;

            Porffor.array.fastPushI32(groupStack, captureIndex);
            captureIndex += 1;
          } else {
            Porffor.array.fastPushI32(groupStack, -1);
          }
        }

        lastWasAtom = false;
        continue;
      }

      if (char == 41) { // ')'
        if (groupDepth == 0) throw new SyntaxError('Regex parse: unmatched )');

        let thisAltDepth: i32 = altDepth[groupDepth];
        while (thisAltDepth-- > 0) {
          const jumpPtr: i32 = Porffor.array.fastPopI32(altStack);
          Porffor.wasm.i32.store16(jumpPtr, bcPtr - jumpPtr, 0, 1);
        }
        altDepth[groupDepth] = 0;

        groupDepth -= 1;

        const capturePop: i32 = Porffor.array.fastPopI32(groupStack);

        // Handle lookaheads
        if (capturePop == -2 || capturePop == -3) {
          const jumpPtr: i32 = Porffor.array.fastPopI32(groupStack);

          // accept
          Porffor.wasm.i32.store8(bcPtr, 0x10, 0, 0);
          bcPtr += 1;

          // Update the jump target to point past this closing paren
          Porffor.wasm.i32.store16(jumpPtr, bcPtr - jumpPtr - 2, 0, 0);
        } else if (capturePop == -4 || capturePop == -5) {
          // lookbehind close — same accept op, but the 5-byte header (op+jump+L) makes the runtime endPc
          // formula pc + jumpOffset + 5, so the stored offset is bcPtr - jumpPtr - 4 (vs -2 for lookahead).
          const jumpPtr: i32 = Porffor.array.fastPopI32(groupStack);
          Porffor.wasm.i32.store8(bcPtr, 0x10, 0, 0); // accept
          bcPtr += 1;
          Porffor.wasm.i32.store16(jumpPtr, bcPtr - jumpPtr - 4, 0, 0);
        } else if (capturePop != -1) {
          Porffor.wasm.i32.store8(bcPtr, 0x31, 0, 0); // end capture
          Porffor.wasm.i32.store8(bcPtr, capturePop, 0, 1);
          bcPtr += 2;
        }

        const groupStartPtr: i32 = Porffor.array.fastPopI32(groupStack);
        lastWasAtom = true;
        lastAtomStart = groupStartPtr;
        continue;
      }

      if (char == 124) { // '|'
        altDepth[groupDepth] += 1;

        // Fork at the START of the current alternative — held in altCurStart[groupDepth], which is set at
        // group open (or bcStart at top level) and updated after every `|`. This is correct for both the
        // first alternative (= scope start) and later ones (a multi-atom alternative isn't split at its
        // final atom), and keeps altStack a pure jump-target stack (no fixed-index collisions).
        let forkPos: i32 = altCurStart[groupDepth];

        Porffor.wasm.memory.copy(forkPos + 5, forkPos, bcPtr - forkPos, 0, 0);
        bcPtr += 5;

        Porffor.wasm.i32.store8(forkPos, 0x21, 0, 0); // fork
        Porffor.wasm.i32.store16(forkPos, 5, 0, 1); // branch1: try this alternative

        Porffor.wasm.i32.store8(bcPtr, 0x20, 0, 0); // jump
        Porffor.array.fastPushI32(altStack, bcPtr); // save jump target location
        bcPtr += 3;

        Porffor.wasm.i32.store16(forkPos, bcPtr - forkPos, 0, 3); // fork branch2: next alternative

        lastAtomStart = bcPtr;
        altCurStart[groupDepth] = bcPtr; // the next alternative begins here
        lastWasAtom = false;
        continue;
      }

      if (char == 46) { // '.'
        lastAtomStart = bcPtr;
        Porffor.wasm.i32.store8(bcPtr, 0x09, 0, 0); // dot
        bcPtr += 1;
        lastWasAtom = true;
        continue;
      }

      if (char == 94) { // '^'
        Porffor.wasm.i32.store8(bcPtr, 0x05, 0, 0); // start
        bcPtr += 1;
        lastWasAtom = false;
        continue;
      }
      if (char == 36) { // '$'
        Porffor.wasm.i32.store8(bcPtr, 0x06, 0, 0); // end
        bcPtr += 1;
        lastWasAtom = false;
        continue;
      }

      // quantifiers: *, +, ?
      if (Porffor.fastOr(char == 42, char == 43, char == 63)) {
        if (!lastWasAtom) throw new SyntaxError('Regex parser: quantifier without atom');

        // check for lazy
        let lazy: boolean = false;
        if (patternPtr < patternEndPtr && Porffor.wasm.i32.load16_u(patternPtr, 0, 4) == 63) { // '?'
          lazy = true;
          patternPtr += 2;
        }

        // Calculate atom size and move it forward to make space for quantifier logic
        const atomSize: i32 = bcPtr - lastAtomStart;
        if (char == 42) { // * (zero or more)
          // Move atom forward to make space for fork BEFORE it
          Porffor.wasm.memory.copy(lastAtomStart + 5, lastAtomStart, atomSize, 0, 0);

          // Insert fork at atom start position
          Porffor.wasm.i32.store8(lastAtomStart, 0x21, 0, 0); // fork
          if (lazy) {
            Porffor.wasm.i32.store16(lastAtomStart, atomSize + 8, 0, 1); // branch1: skip atom entirely
            Porffor.wasm.i32.store16(lastAtomStart, 5, 0, 3); // branch2: execute atom
          } else {
            Porffor.wasm.i32.store16(lastAtomStart, 5, 0, 1); // branch1: execute atom
            Porffor.wasm.i32.store16(lastAtomStart, atomSize + 8, 0, 3); // branch2: skip atom entirely
          }

          // insert back-edge jump to the loop fork. 0x22 (not a plain 0x20 jump) so the matcher can detect a
          // zero-width iteration and stop, instead of looping forever (ECMAScript empty-match-stops-quantifier).
          Porffor.wasm.i32.store8(bcPtr, 0x22, 0, 5);
          Porffor.wasm.i32.store16(bcPtr, -atomSize - 5, 0, 6);

          // Update bcPtr to point after the moved atom
          bcPtr += 8;
        } else if (char == 43) { // + (one or more): atom once, then a guarded `*` over a copy of the atom
          // Emitting `x+` as `x` followed by exactly the bytecode `x*` produces — [fork(5)][atom copy][0x22
          // back-edge] — reuses the proven zero-width loop guard (0x22) so a body that can match empty (e.g.
          // /(?:x*)+/) terminates instead of looping forever, identical to how `*` is handled.
          const starFork: i32 = bcPtr;
          Porffor.wasm.memory.copy(starFork + 5, lastAtomStart, atomSize, 0, 0); // atom copy after the fork
          Porffor.wasm.i32.store8(starFork, 0x21, 0, 0); // fork
          if (lazy) {
            Porffor.wasm.i32.store16(starFork, atomSize + 8, 0, 1); // branch1: skip (done)
            Porffor.wasm.i32.store16(starFork, 5, 0, 3); // branch2: execute atom copy
          } else {
            Porffor.wasm.i32.store16(starFork, 5, 0, 1); // branch1: execute atom copy
            Porffor.wasm.i32.store16(starFork, atomSize + 8, 0, 3); // branch2: skip (done)
          }
          const backEdge: i32 = starFork + 5 + atomSize;
          Porffor.wasm.i32.store8(backEdge, 0x22, 0, 0); // guarded back-edge to the fork
          Porffor.wasm.i32.store16(backEdge, -atomSize - 5, 0, 1);
          bcPtr = backEdge + 3;
        } else { // ? (zero or one)
          // Move atom forward to make space for fork
          Porffor.wasm.memory.copy(lastAtomStart + 5, lastAtomStart, atomSize, 0, 0);

          // Insert fork at atom start position
          const forkPos: i32 = lastAtomStart;
          Porffor.wasm.i32.store8(forkPos, 0x21, 0, 0); // fork
          if (lazy) {
            Porffor.wasm.i32.store16(forkPos, atomSize + 5, 0, 1); // branch1: skip atom
            Porffor.wasm.i32.store16(forkPos, 5, 0, 3); // branch2: execute atom
          } else {
            Porffor.wasm.i32.store16(forkPos, 5, 0, 1); // branch1: execute atom
            Porffor.wasm.i32.store16(forkPos, atomSize + 5, 0, 3); // branch2: skip atom
          }

          // Update bcPtr to point after the moved atom
          bcPtr = lastAtomStart + 5 + atomSize;
        }
        lastWasAtom = false;
        continue;
      }

      if (char == 123) { // {n,m}
        // Peek ahead: a '{' that doesn't form a real {n}/{n,}/{n,m} quantifier (or that follows no atom) is a
        // LITERAL '{' per Annex B (e.g. /a{b/, /x{}/) — not a parse error.
        let pk: i32 = patternPtr;
        let pkDigit: boolean = false;
        let pkValid: boolean = false;
        while (pk < patternEndPtr) {
          const pc: i32 = Porffor.wasm.i32.load16_u(pk, 0, 4);
          if (pc >= 48 && pc <= 57) { pkDigit = true; pk += 2; continue; }
          if (pc == 44) { pk += 2; continue; } // ','
          if (pc == 125) { pkValid = pkDigit; } // '}' closes it; valid iff we saw >=1 digit
          break;
        }

        if (!lastWasAtom || !pkValid) {
          // emit '{' as a literal char (single-char op), leaving the rest to parse normally
          lastAtomStart = bcPtr;
          Porffor.wasm.i32.store8(bcPtr, 0x01, 0, 0);
          Porffor.wasm.i32.store8(bcPtr, 123, 0, 1);
          bcPtr += 2;
          lastWasAtom = true;
          continue;
        }

        // parse n
        let n: i32 = 0;
        let m: i32 = -1;
        let sawComma: boolean = false;
        let sawDigit: boolean = false;
        while (patternPtr < patternEndPtr) {
          const d: i32 = Porffor.wasm.i32.load16_u(patternPtr, 0, 4);
          if (Porffor.fastAnd(d >= 48, d <= 57)) { // digit
            n = n * 10 + (d - 48);
            sawDigit = true;
            patternPtr += 2;
            continue;
          }

          if (d == 44) { // ','
            sawComma = true;
            patternPtr += 2;
            break;
          }

          if (d == 125) { // '}'
            patternPtr += 2;
            break;
          }

          throw new SyntaxError('Regex parse: invalid {n,m} quantifier');
        }

        if (!sawDigit) throw new SyntaxError('Regex parse: invalid {n,m} quantifier');
        if (patternPtr > patternEndPtr) throw new SyntaxError('Regex parse: unterminated {n,m} quantifier');

        if (sawComma) {
          // parse m (or none)
          let mVal: i32 = 0;
          let sawMDigit: boolean = false;
          while (patternPtr < patternEndPtr) {
            const d: i32 = Porffor.wasm.i32.load16_u(patternPtr, 0, 4);
            if (Porffor.fastAnd(d >= 48, d <= 57)) {
              mVal = mVal * 10 + (d - 48);
              sawMDigit = true;
              patternPtr += 2;
              continue;
            }

            if (d == 125) {
              patternPtr += 2;
              break;
            }

            throw new SyntaxError('Regex parse: invalid {n,m} quantifier');
          }

          if (sawMDigit) {
            m = mVal;
            if (m < n) throw new SyntaxError('Regex parse: {n,m} with m < n');
          } else {
            m = -1; // open
          }
        } else {
          m = n;
        }

        // check for lazy
        let lazyBrace: boolean = false;
        if (patternPtr < patternEndPtr && Porffor.wasm.i32.load16_u(patternPtr, 0, 4) == 63) { // '?'
          lazyBrace = true;
          patternPtr += 2;
        }

        // {0,m} ≡ (x{1,m})?  and  {0,} ≡ (x{1,})? ≡ x* : a min of 0 means the whole quantified block is
        // OPTIONAL. The original atom is already emitted once (the first mandatory copy), so emit the block
        // as {1,m} and then wrap it in a skippable fork below. Without this, n==0 left that first copy
        // mandatory (matching 1..m instead of 0..m) — e.g. /^ {0,3}#/ failed to match "#".
        let wrapOptional: boolean = false;
        if (n == 0) { wrapOptional = true; n = 1; }

        // emit n times
        const atomSize: i32 = bcPtr - lastAtomStart;
        for (let i: i32 = 1; i < n; i++) {
          for (let j: i32 = 0; j < atomSize; ++j) {
            Porffor.wasm.i32.store8(bcPtr + j, Porffor.wasm.i32.load8_u(lastAtomStart + j, 0, 0), 0, 0);
          }
          bcPtr += atomSize;
        }

        if (m == n) {
          // exactly n
        } else if (m == -1) {
          // {n,} - infinite (like * after n mandatory matches)
          Porffor.wasm.i32.store8(bcPtr, 0x21, 0, 0); // fork
          if (lazyBrace) {
            Porffor.wasm.i32.store16(bcPtr, 5, 0, 1); // branch1: continue (done)
            Porffor.wasm.i32.store16(bcPtr, -(bcPtr - lastAtomStart), 0, 3); // branch2: back to atom
          } else {
            Porffor.wasm.i32.store16(bcPtr, -(bcPtr - lastAtomStart), 0, 1); // branch1: back to atom
            Porffor.wasm.i32.store16(bcPtr, 5, 0, 3); // branch2: continue (done)
          }
          bcPtr += 5;
        } else {
          // {n,m} - exactly between n and m matches
          // Create chain of forks, each executing atom inline
          for (let i: i32 = n; i < m; i++) {
            Porffor.wasm.i32.store8(bcPtr, 0x21, 0, 0); // fork
            if (lazyBrace) {
              Porffor.wasm.i32.store16(bcPtr, 5 + atomSize, 0, 1); // branch1: skip this match
              Porffor.wasm.i32.store16(bcPtr, 5, 0, 3); // branch2: execute atom
            } else {
              Porffor.wasm.i32.store16(bcPtr, 5, 0, 1); // branch1: execute atom
              Porffor.wasm.i32.store16(bcPtr, 5 + atomSize, 0, 3); // branch2: skip this match
            }
            bcPtr += 5;

            // Copy the atom inline
            for (let j: i32 = 0; j < atomSize; j++) {
              Porffor.wasm.i32.store8(bcPtr + j, Porffor.wasm.i32.load8_u(lastAtomStart + j, 0, 0), 0, 0);
            }
            bcPtr += atomSize;
          }
        }

        if (wrapOptional) {
          // wrap the whole [lastAtomStart, bcPtr) block in a fork so it can be skipped entirely (min 0).
          const blockSize: i32 = bcPtr - lastAtomStart;
          Porffor.wasm.memory.copy(lastAtomStart + 5, lastAtomStart, blockSize, 0, 0);
          Porffor.wasm.i32.store8(lastAtomStart, 0x21, 0, 0); // fork
          if (lazyBrace) {
            Porffor.wasm.i32.store16(lastAtomStart, blockSize + 5, 0, 1); // branch1: skip block
            Porffor.wasm.i32.store16(lastAtomStart, 5, 0, 3); // branch2: execute block
          } else {
            Porffor.wasm.i32.store16(lastAtomStart, 5, 0, 1); // branch1: execute block
            Porffor.wasm.i32.store16(lastAtomStart, blockSize + 5, 0, 3); // branch2: skip block
          }
          bcPtr += 5;
        }

        lastWasAtom = false;
        continue;
      }
    } else {
      // handle escapes outside class OR literal chars if escaped and not special
      // backreference: \1, \2, ...
      if (Porffor.fastAnd(char >= 49, char <= 57)) { // '1'-'9'
        lastAtomStart = bcPtr;
        Porffor.wasm.i32.store8(bcPtr, 0x0a, 0, 0); // back reference
        Porffor.wasm.i32.store8(bcPtr, char - 48, 0, 1);
        bcPtr += 2;
        lastWasAtom = true;
        continue;
      }

      // \k<name> named backreference: resolve the name to its group number and emit a normal backref op.
      // Only treated as a backref when the pattern actually declares named groups (else \k is a literal 'k',
      // per Annex B); forward names resolve because the name table was built in the pre-scan above.
      if (char == 107 && namesPtr != 0 && patternPtr < patternEndPtr && Porffor.wasm.i32.load16_u(patternPtr, 0, 4) == 60) {
        patternPtr += 2; // past '<'
        const nameStart: i32 = patternPtr;
        while (patternPtr < patternEndPtr && Porffor.wasm.i32.load16_u(patternPtr, 0, 4) != 62) patternPtr += 2;
        const nameLen: i32 = (patternPtr - nameStart) >> 1; // code-unit count
        if (patternPtr < patternEndPtr) patternPtr += 2; // past '>'
        const g: i32 = __Porffor_regex_lookupName(namesPtr, nameStart, nameLen);
        if (g == 0) throw new SyntaxError('Regex parse: \\k to unknown group name');
        lastAtomStart = bcPtr;
        Porffor.wasm.i32.store8(bcPtr, 0x0a, 0, 0); // back reference
        Porffor.wasm.i32.store8(bcPtr, g, 0, 1);
        bcPtr += 2;
        lastWasAtom = true;
        continue;
      }

      if (char == 100) { // \d
        lastAtomStart = bcPtr;
        Porffor.wasm.i32.store8(bcPtr, 0x04, 0, 0); // predefined class
        Porffor.wasm.i32.store8(bcPtr, 1, 0, 1); // digit
        bcPtr += 2;
        lastWasAtom = true;
        continue;
      }
      if (char == 68) { // \D
        lastAtomStart = bcPtr;
        Porffor.wasm.i32.store8(bcPtr, 0x04, 0, 0);
        Porffor.wasm.i32.store8(bcPtr, 2, 0, 1); // non-digit
        bcPtr += 2;
        lastWasAtom = true;
        continue;
      }

      if (char == 115) { // \s
        lastAtomStart = bcPtr;
        Porffor.wasm.i32.store8(bcPtr, 0x04, 0, 0);
        Porffor.wasm.i32.store8(bcPtr, 3, 0, 1); // space
        bcPtr += 2;
        lastWasAtom = true;
        continue;
      }
      if (char == 83) { // \S
        lastAtomStart = bcPtr;
        Porffor.wasm.i32.store8(bcPtr, 0x04, 0, 0);
        Porffor.wasm.i32.store8(bcPtr, 4, 0, 1); // non-space
        bcPtr += 2;
        lastWasAtom = true;
        continue;
      }

      if (char == 119) { // \w
        lastAtomStart = bcPtr;
        Porffor.wasm.i32.store8(bcPtr, 0x04, 0, 0);
        Porffor.wasm.i32.store8(bcPtr, 5, 0, 1); // word
        bcPtr += 2;
        lastWasAtom = true;
        continue;
      }
      if (char == 87) { // \W
        lastAtomStart = bcPtr;
        Porffor.wasm.i32.store8(bcPtr, 0x04, 0, 0);
        Porffor.wasm.i32.store8(bcPtr, 6, 0, 1); // non-word
        bcPtr += 2;
        lastWasAtom = true;
        continue;
      }

      // \p{Name} / \P{Name} Unicode property escape (only with the u/v flag; a lone \p is literal 'p' in
      // non-unicode mode per Annex B). Emitted as a predefined-class op; matching is byte/Latin1-domain.
      const pPropUni: boolean = (flags & 0b00010000) != 0 || (flags & 0b10000000) != 0; // u or v flag
      if ((char == 112 || char == 80) && pPropUni) { // 'p' / 'P'
        const negate: boolean = char == 80;
        if (patternPtr >= patternEndPtr || Porffor.wasm.i32.load16_u(patternPtr, 0, 4) != 123) // '{'
          throw new SyntaxError('Regex parse: \\p must be followed by {');
        patternPtr += 2; // past '{'
        const nameStart: i32 = patternPtr;
        while (patternPtr < patternEndPtr && Porffor.wasm.i32.load16_u(patternPtr, 0, 4) != 125) patternPtr += 2; // to '}'
        const nameLen: i32 = (patternPtr - nameStart) >> 1; // code-unit count
        if (patternPtr < patternEndPtr) patternPtr += 2; // past '}'
        const base: i32 = __Porffor_regex_propClass(nameStart, nameLen);
        if (base == 0) throw new SyntaxError('Regex parse: unsupported \\p property');
        lastAtomStart = bcPtr;
        Porffor.wasm.i32.store8(bcPtr, 0x04, 0, 0); // predefined class
        Porffor.wasm.i32.store8(bcPtr, negate ? base + 1 : base, 0, 1);
        bcPtr += 2;
        lastWasAtom = true;
        continue;
      }

      if (char == 98) { // \b
        Porffor.wasm.i32.store8(bcPtr, 0x07, 0, 0); // word boundary
        bcPtr += 1;
        lastWasAtom = false;
        continue;
      }
      if (char == 66) { // \B
        Porffor.wasm.i32.store8(bcPtr, 0x08, 0, 0); // non-word boundary
        bcPtr += 1;
        lastWasAtom = false;
        continue;
      }

      if (char == 110) { // \n
        lastAtomStart = bcPtr;
        Porffor.wasm.i32.store8(bcPtr, 0x01, 0, 0); // single
        Porffor.wasm.i32.store8(bcPtr, 10, 0, 1);
        bcPtr += 2;
        lastWasAtom = true;
        continue;
      }
      if (char == 114) { // \r
        lastAtomStart = bcPtr;
        Porffor.wasm.i32.store8(bcPtr, 0x01, 0, 0);
        Porffor.wasm.i32.store8(bcPtr, 13, 0, 1);
        bcPtr += 2;
        lastWasAtom = true;
        continue;
      }
      if (char == 116) { // \t
        lastAtomStart = bcPtr;
        Porffor.wasm.i32.store8(bcPtr, 0x01, 0, 0);
        Porffor.wasm.i32.store8(bcPtr, 9, 0, 1);
        bcPtr += 2;
        lastWasAtom = true;
        continue;
      }
      if (char == 118) { // \v
        lastAtomStart = bcPtr;
        Porffor.wasm.i32.store8(bcPtr, 0x01, 0, 0);
        Porffor.wasm.i32.store8(bcPtr, 11, 0, 1);
        bcPtr += 2;
        lastWasAtom = true;
        continue;
      }
      if (char == 102) { // \f
        lastAtomStart = bcPtr;
        Porffor.wasm.i32.store8(bcPtr, 0x01, 0, 0);
        Porffor.wasm.i32.store8(bcPtr, 12, 0, 1);
        bcPtr += 2;
        lastWasAtom = true;
        continue;
      }
      if (char == 48) { // \0
        lastAtomStart = bcPtr;
        Porffor.wasm.i32.store8(bcPtr, 0x01, 0, 0);
        Porffor.wasm.i32.store8(bcPtr, 0, 0, 1);
        bcPtr += 2;
        lastWasAtom = true;
        continue;
      }
      if (char == 120) { // \x
        if (patternPtr + 2 >= patternEndPtr) throw new SyntaxError('Regex parse: invalid \\x escape');
        const c1: i32 = Porffor.wasm.i32.load16_u(patternPtr, 0, 4); patternPtr += 2;
        const c2: i32 = Porffor.wasm.i32.load16_u(patternPtr, 0, 4); patternPtr += 2;

        lastAtomStart = bcPtr;
        Porffor.wasm.i32.store8(bcPtr, 0x01, 0, 0);
        Porffor.wasm.i32.store8(bcPtr, __Porffor_regex_hexDigitToValue(c1) * 16 + __Porffor_regex_hexDigitToValue(c2), 0, 1);
        bcPtr += 2;
        lastWasAtom = true;
        continue;
      }
      if (char == 117) { // \u
        const uniFlag: boolean = (flags & 0b00010000) != 0 || (flags & 0b10000000) != 0;
        const nx: i32 = patternPtr < patternEndPtr ? Porffor.wasm.i32.load16_u(patternPtr, 0, 4) : 0;
        if (uniFlag && nx == 123) { // \u{H+} — only with the u/v flag
          patternPtr += 2; // past '{'
          let cp: i32 = 0;
          while (patternPtr < patternEndPtr) {
            const hc: i32 = Porffor.wasm.i32.load16_u(patternPtr, 0, 4);
            if (hc == 125) { patternPtr += 2; break; } // '}'
            cp = cp * 16 + __Porffor_regex_hexDigitToValue(hc);
            patternPtr += 2;
          }
          lastAtomStart = bcPtr;
          if (cp > 0xFFFF) {
            // astral code point → UTF-16 surrogate pair, emitted as two wide-char ops (matches the surrogate
            // units of a UTF-16 input). The two ops form one atom for a following quantifier.
            const hi: i32 = 0xD800 + ((cp - 0x10000) >> 10);
            const lo: i32 = 0xDC00 + ((cp - 0x10000) & 0x3FF);
            Porffor.wasm.i32.store8(bcPtr, 0x0f, 0, 0);
            Porffor.wasm.i32.store16(bcPtr, hi, 0, 1);
            bcPtr += 3;
            Porffor.wasm.i32.store8(bcPtr, 0x0f, 0, 0);
            Porffor.wasm.i32.store16(bcPtr, lo, 0, 1);
            bcPtr += 3;
          } else if (cp > 255) {
            Porffor.wasm.i32.store8(bcPtr, 0x0f, 0, 0); // wide single char (only matchable on UTF-16 input)
            Porffor.wasm.i32.store16(bcPtr, cp, 0, 1);
            bcPtr += 3;
          } else {
            Porffor.wasm.i32.store8(bcPtr, 0x01, 0, 0);
            Porffor.wasm.i32.store8(bcPtr, cp, 0, 1);
            bcPtr += 2;
          }
          lastWasAtom = true;
          continue;
        }
        if (patternPtr + 6 < patternEndPtr &&
            __Porffor_regex_isHexDigit(Porffor.wasm.i32.load16_u(patternPtr, 0, 4)) &&
            __Porffor_regex_isHexDigit(Porffor.wasm.i32.load16_u(patternPtr, 0, 6)) &&
            __Porffor_regex_isHexDigit(Porffor.wasm.i32.load16_u(patternPtr, 0, 8)) &&
            __Porffor_regex_isHexDigit(Porffor.wasm.i32.load16_u(patternPtr, 0, 10))) {
          const c1: i32 = Porffor.wasm.i32.load16_u(patternPtr, 0, 4); patternPtr += 2;
          const c2: i32 = Porffor.wasm.i32.load16_u(patternPtr, 0, 4); patternPtr += 2;
          const c3: i32 = Porffor.wasm.i32.load16_u(patternPtr, 0, 4); patternPtr += 2;
          const c4: i32 = Porffor.wasm.i32.load16_u(patternPtr, 0, 4); patternPtr += 2;
          const cv: i32 = __Porffor_regex_hexDigitToValue(c1) * 4096 + __Porffor_regex_hexDigitToValue(c2) * 256 + __Porffor_regex_hexDigitToValue(c3) * 16 + __Porffor_regex_hexDigitToValue(c4);

          lastAtomStart = bcPtr;
          if (cv > 255) {
            Porffor.wasm.i32.store8(bcPtr, 0x0f, 0, 0); // wide single char (u16), e.g. a \uXXXX > 0xFF
            Porffor.wasm.i32.store16(bcPtr, cv, 0, 1);
            bcPtr += 3;
          } else {
            Porffor.wasm.i32.store8(bcPtr, 0x01, 0, 0);
            Porffor.wasm.i32.store8(bcPtr, cv, 0, 1);
            bcPtr += 2;
          }
          lastWasAtom = true;
          continue;
        }
        // not a valid \uXXXX / \u{...}: fall through to the default single-char emit (literal 'u')
      }
      if (char == 99) { // \c
        if (patternPtr >= patternEndPtr) {
          // No character after \c, treat as literal \c - fall through to default case
        } else {
          const ctrlChar: i32 = Porffor.wasm.i32.load16_u(patternPtr, 0, 4);
          if ((ctrlChar >= 65 && ctrlChar <= 90) || (ctrlChar >= 97 && ctrlChar <= 122)) {
            patternPtr += 2;
            lastAtomStart = bcPtr;
            Porffor.wasm.i32.store8(bcPtr, 0x01, 0, 0);
            Porffor.wasm.i32.store8(bcPtr, ctrlChar & 0x1F, 0, 1);
            bcPtr += 2;
            lastWasAtom = true;
            continue;
          }
          // Invalid control character, treat as literal \c - fall through to default case
        }
      }
    }

    // default: emit single char (either a literal, or an escape that resolves to a literal)
    lastAtomStart = bcPtr;
    Porffor.wasm.i32.store8(bcPtr, 0x01, 0, 0);
    Porffor.wasm.i32.store8(bcPtr, char, 0, 1);
    bcPtr += 2;
    lastWasAtom = true;
  }

  if (groupDepth != 0) throw new SyntaxError('Regex parse: Unmatched (');
  if (classPtr) throw new SyntaxError('Regex parse: Unmatched [');

  let thisAltDepth: i32 = altDepth[groupDepth];
  while (thisAltDepth-- > 0) {
    const jumpPtr: i32 = Porffor.array.fastPopI32(altStack);
    Porffor.wasm.i32.store16(jumpPtr, bcPtr - jumpPtr, 0, 1);
  }
  altDepth[groupDepth] = 0;

  // accept
  Porffor.wasm.i32.store8(bcPtr, 0x10, 0, 0);
  Porffor.wasm.i32.store16(ptr, captureIndex, 0, 6);

  return ptr as RegExp;
};


export const __Porffor_regex_interpret = (regexp: RegExp, input: i32, isTest: boolean, wide: boolean): any => {
  const bcBase: i32 = regexp + 16;
  const flags: i32 = Porffor.wasm.i32.load16_u(regexp, 0, 4);
  const totalCaptures: i32 = Porffor.wasm.i32.load16_u(regexp, 0, 6);

  const ignoreCase: boolean = (flags & 0b00000010) != 0;
  const multiline: boolean = (flags & 0b00000100) != 0;
  const dotAll: boolean = (flags & 0b00001000) != 0;
  const global: boolean = (flags & 0b00000001) != 0;
  const sticky: boolean = (flags & 0b00100000) != 0;

  const inputLen: i32 = Porffor.wasm.i32.load(input, 0, 0);
  let lastIndex: i32 = 0;
  if (global || sticky) {
    lastIndex = Porffor.wasm.i32.load16_u(regexp, 0, 8);
  }
  if (lastIndex > inputLen) {
    if (global || sticky) Porffor.wasm.i32.store16(regexp, 0, 0, 8);
    return isTest ? false : null;
  }

  const backtrackStack: i32[] = [];
  const captures: i32[] = [];

  // check if first op is char for fast scan
  let fastChar: i32 = -1;
  if (!Porffor.fastOr(ignoreCase, sticky)) {
    const firstOp = Porffor.wasm.i32.load8_u(bcBase, 0, 0);
    if (firstOp == 0x01) {
      fastChar = Porffor.wasm.i32.load8_u(bcBase, 0, 1);
    }
  }

  for (let i: i32 = lastIndex; i <= inputLen; i++) {
    if (fastChar != -1) {
      while (i < inputLen && __Porffor_regex_cu(input, i, wide) != fastChar) i++;
      if (i > inputLen) break;
    }

    backtrackStack.length = 0;
    captures.length = 0;

    let pc: i32 = bcBase;
    let sp: i32 = i;

    let matched: boolean = false;
    let finalSp: i32 = -1;

    interpreter: while (true) {
      const op: i32 = Porffor.wasm.i32.load8_u(pc, 0, 0);
      let backtrack: boolean = false;

      switch (op) {
        case 0x10: { // accept
          // The lookahead marker may sit BELOW fork entries pushed by an alternation inside the lookahead
          // body (e.g. (?=\s|$) takes a branch that advances sp). Fork entries are all positive, so the
          // -2000/-3000 marker is unambiguous — scan down for it instead of assuming it's on top. Without
          // this an alternation in a lookahead leaked its sp advance (e.g. /#(?=\s|$)/ consumed the space).
          let foundLA: boolean = false;
          let mi: i32 = backtrackStack.length - 1;
          while (mi >= 3) {
            const marker: i32 = backtrackStack[mi];
            if (marker == -2000 || marker == -3000) {
              const endPc: i32 = backtrackStack[mi - 3];
              sp = backtrackStack[mi - 2];
              // A POSITIVE lookahead's captures persist (JS semantics) AND any capture set BEFORE it must be
              // kept — so do NOT reset captures.length here. Only a NEGATIVE lookahead (body matched →
              // assertion fails) unwinds, where captures.length is irrelevant.
              backtrackStack.length = mi - 3; // discard marker + the lookahead's internal forks (atomic)
              foundLA = true;
              if (marker == -2000) break interpreter; // negative lookahead body matched → assertion fails
              pc = endPc;
              break;
            }
            mi--;
          }
          if (foundLA) break;

          matched = true;
          finalSp = sp;
          break interpreter;
        }

        case 0x01: { // single
          if (sp >= inputLen) {
            backtrack = true;
          } else {
            let c1: i32 = Porffor.wasm.i32.load8_u(pc, 0, 1);
            let c2: i32 = __Porffor_regex_cu(input, sp, wide);
            if (ignoreCase) {
              if (c1 >= 97 && c1 <= 122) c1 -= 32;
              if (c2 >= 97 && c2 <= 122) c2 -= 32;
            }
            if (c1 == c2) {
              pc += 2;
              sp += 1;
            } else {
              backtrack = true;
            }
          }
          break;
        }

        case 0x0f: { // single wide char (u16) — a code unit > 255, e.g. an astral surrogate half
          if (sp >= inputLen) {
            backtrack = true;
          } else {
            const wc: i32 = Porffor.wasm.i32.load16_u(pc, 0, 1);
            // On a narrow (byte) input no code unit can exceed 255, so a >255 pattern char never matches.
            if (__Porffor_regex_cu(input, sp, wide) == wc) {
              pc += 3;
              sp += 1;
            } else {
              backtrack = true;
            }
          }
          break;
        }

        case 0x02: // class
        case 0x03: { // negated class
          if (sp >= inputLen) {
            backtrack = true;
          } else {
            let char: i32 = __Porffor_regex_cu(input, sp, wide);
            const classLength: i32 = Porffor.wasm.i32.load8_u(pc, 0, 1);
            const beforeClassPc: i32 = pc;
            const afterClassPc: i32 = pc + 3 + classLength * 4;

            let match: boolean = false;
            if (ignoreCase && char >= 97 && char <= 122) char -= 32;

            while (true) {
              const marker: i32 = Porffor.wasm.i32.load8_u(pc, 0, 2);
              if (marker == 0xFF) break;

              if (marker == 0x00) { // range
                let from: i32 = Porffor.wasm.i32.load8_u(pc, 0, 3);
                let to: i32 = Porffor.wasm.i32.load8_u(pc, 0, 4);
                if (ignoreCase) {
                  if (from >= 97 && from <= 122) from -= 32;
                  if (to >= 97 && to <= 122) to -= 32;
                }
                if (char >= from && char <= to) {
                  match = true;
                  break;
                }
              } else if (marker == 0x01) { // char
                let check: i32 = Porffor.wasm.i32.load8_u(pc, 0, 3);
                if (ignoreCase && check >= 97 && check <= 122) check -= 32;
                if (check == char) {
                  match = true;
                  break;
                }
              } else if (marker == 0x02) { // predefined
                const classId: i32 = Porffor.wasm.i32.load8_u(pc, 0, 3);
                if (classId == 1) match = Porffor.fastAnd(char >= 48, char <= 57);
                  else if (classId == 2) match = Porffor.fastOr(char < 48, char > 57);
                  else if (classId == 3) match = Porffor.fastOr(char == 32, char == 9, char == 10, char == 13, char == 11, char == 12);
                  else if (classId == 4) match = Porffor.fastAnd(char != 32, char != 9, char != 10, char != 13, char != 11, char != 12);
                  else if (classId == 5) match = Porffor.fastOr(char >= 65 && char <= 90, char >= 97 && char <= 122, char >= 48 && char <= 57, char == 95);
                  else if (classId == 6) match = Porffor.fastAnd(char < 65 || char > 90, char < 97 || char > 122, char < 48 || char > 57, char != 95);

                if (match) break;
              }

              pc += 4;
            }

            if (op == 0x03) match = !match;
            if (match) {
              pc = afterClassPc;
              sp += 1;
            } else {
              pc = beforeClassPc;
              backtrack = true;
            }
          }
          break;
        }

        case 0x04: { // predefined class
          if (sp >= inputLen) {
            backtrack = true;
          } else {
            const classId: i32 = Porffor.wasm.i32.load8_u(pc, 0, 1);
            const char: i32 = __Porffor_regex_cu(input, sp, wide);
            let isMatch: boolean = false;
            if (classId == 1) isMatch = Porffor.fastAnd(char >= 48, char <= 57);
              else if (classId == 2) isMatch = Porffor.fastOr(char < 48, char > 57);
              else if (classId == 3) isMatch = Porffor.fastOr(char == 32, char == 9, char == 10, char == 13, char == 11, char == 12);
              else if (classId == 4) isMatch = Porffor.fastAnd(char != 32, char != 9, char != 10, char != 13, char != 11, char != 12);
              else if (classId == 5) isMatch = Porffor.fastOr(char >= 65 && char <= 90, char >= 97 && char <= 122, char >= 48 && char <= 57, char == 95);
              else if (classId == 6) isMatch = Porffor.fastAnd(char < 65 || char > 90, char < 97 || char > 122, char < 48 || char > 57, char != 95);
              else if (classId >= 7) { // \p{…}/\P{…} — odd id = positive property, even id = negation
                if ((classId & 1) == 1) isMatch = __Porffor_regex_isProp(char, classId);
                else isMatch = !__Porffor_regex_isProp(char, classId - 1);
              }

            if (isMatch) {
              pc += 2;
              sp += 1;
            } else {
              backtrack = true;
            }
          }
          break;
        }

        case 0x05: // start
          if (sp == 0 || (multiline && sp > 0 && __Porffor_regex_cu(input, sp - 1, wide) == 10)) {
            pc += 1;
          } else {
            backtrack = true;
          }
          break;

        case 0x06: // end
          if (sp == inputLen || (multiline && sp < inputLen && __Porffor_regex_cu(input, sp, wide) == 10)) {
            pc += 1;
          } else {
            backtrack = true;
          }
          break;

        case 0x07: // word boundary
        case 0x08: { // non-word boundary
          let prevIsWord: boolean = false;
          if (sp > 0) {
            const prevChar: i32 = __Porffor_regex_cu(input, sp - 1, wide);
            prevIsWord = Porffor.fastOr(
              prevChar >= 65 && prevChar <= 90, // A-Z
              prevChar >= 97 && prevChar <= 122, // a-z
              prevChar >= 48 && prevChar <= 57, // 0-9
              prevChar == 95 // _
            );
          }

          let nextIsWord: boolean = false;
          if (sp < inputLen) {
            const nextChar: i32 = __Porffor_regex_cu(input, sp, wide);
            nextIsWord = Porffor.fastOr(
              nextChar >= 65 && nextChar <= 90, // A-Z
              nextChar >= 97 && nextChar <= 122, // a-z
              nextChar >= 48 && nextChar <= 57, // 0-9
              nextChar == 95 // _
            );
          }

          const isWordBoundary: boolean = prevIsWord != nextIsWord;
          if ((op == 0x07 && isWordBoundary) || (op == 0x08 && !isWordBoundary)) {
            pc += 1;
          } else {
            backtrack = true;
          }
          break;
        }

        case 0x09: // dot
          if (sp >= inputLen || (!dotAll && __Porffor_regex_cu(input, sp, wide) == 10)) {
            backtrack = true;
          } else {
            pc += 1;
            sp += 1;
          }
          break;

        case 0x0a: { // back reference
          const capIndex: i32 = Porffor.wasm.i32.load8_u(pc, 0, 1);
          const arrIndex: i32 = (capIndex - 1) * 2;
          if (arrIndex + 1 >= captures.length) { // reference to group that hasn't been seen
            pc += 2;
          } else {
            const capStart: i32 = captures[arrIndex];
            const capEnd: i32 = captures[arrIndex + 1];
            if (capStart == -1 || capEnd == -1) { // reference to unmatched group
              pc += 2;
            } else {
              const capLen: i32 = capEnd - capStart;
              if (sp + capLen > inputLen) {
                backtrack = true;
              } else {
                let matches: boolean = true;
                for (let k: i32 = 0; k < capLen; k++) {
                  let c1: i32 = __Porffor_regex_cu(input, capStart + k, wide);
                  let c2: i32 = __Porffor_regex_cu(input, sp + k, wide);
                  if (ignoreCase) {
                    if (c1 >= 97 && c1 <= 122) c1 -= 32;
                    if (c2 >= 97 && c2 <= 122) c2 -= 32;
                  }
                  if (c1 != c2) {
                    matches = false;
                    break;
                  }
                }
                if (matches) {
                  sp += capLen;
                  pc += 2;
                } else {
                  backtrack = true;
                }
              }
            }
          }
          break;
        }

        case 0x0b:
        case 0x0c: { // positive or negative lookahead
          const jumpOffset: i32 = Porffor.wasm.i32.load16_s(pc, 0, 1);
          const lookaheadEndPc: i32 = pc + jumpOffset + 3;
          const savedSp: i32 = sp;

          const len: i32 = backtrackStack.length;
          backtrackStack[len] = lookaheadEndPc;
          backtrackStack[len + 1] = savedSp;
          backtrackStack[len + 2] = captures.length;
          if (op == 0x0c) { // negative lookahead
            backtrackStack[len + 3] = -2000;
          } else { // positive lookahead
            backtrackStack[len + 3] = -3000;
          }
          backtrackStack.length = len + 4;

          pc += 3;
          break;
        }

        case 0x0d:
        case 0x0e: { // positive / negative fixed-length lookbehind
          const jumpOffset: i32 = Porffor.wasm.i32.load16_s(pc, 0, 1);
          const lbLen: i32 = Porffor.wasm.i32.load16_u(pc, 0, 3);
          const lookbehindEndPc: i32 = pc + jumpOffset + 5;
          const savedSp: i32 = sp;

          if (sp < lbLen) {
            // not enough preceding input → the body cannot match here
            if (op == 0x0e) { pc = lookbehindEndPc; } // negative assertion holds, skip the body
            else { backtrack = true; }                 // positive assertion fails
            break;
          }

          // Same frame shape as a lookahead (endPc, restore-sp, captures, marker) so the existing accept /
          // backtrack-unwind machinery resolves it. Run the body forward from sp-L; a fixed-length body lands
          // its accept exactly at savedSp, where sp is restored to savedSp regardless of pos/neg outcome.
          const len: i32 = backtrackStack.length;
          backtrackStack[len] = lookbehindEndPc;
          backtrackStack[len + 1] = savedSp;
          backtrackStack[len + 2] = captures.length;
          backtrackStack[len + 3] = op == 0x0e ? -2000 : -3000;
          backtrackStack.length = len + 4;

          sp = sp - lbLen;
          pc += 5;
          break;
        }

        case 0x20: // jump
          pc += Porffor.wasm.i32.load16_s(pc, 0, 1);
          break;

        case 0x21: { // fork
          const branch1Offset: i32 = Porffor.wasm.i32.load16_s(pc, 0, 1);
          const branch2Offset: i32 = Porffor.wasm.i32.load16_s(pc, 0, 3);

          const len: i32 = backtrackStack.length;
          backtrackStack[len] = pc + branch2Offset;
          backtrackStack[len + 1] = sp;
          backtrackStack[len + 2] = captures.length;
          backtrackStack.length = len + 3;

          pc += branch1Offset;
          break;
        }

        case 0x22: { // star loop back-edge (zero-width loop guard)
          // The `*` loop is `fork(body, exit); body; <0x22 back-edge>`. We arrive here having just completed
          // one body iteration. If it consumed NOTHING (sp unchanged since this iteration's fork), re-running
          // loops forever (was the marked-table OOB: /(?:(?!a)x*)*/ grew backtrackStack until overflow).
          // ECMAScript: a quantifier iteration matching the empty string stops the quantifier. Find THIS
          // loop's most-recent fork frame (the one whose pushed resume == this loop's exit target) and compare
          // its entry sp to the current sp. Done at the back-edge (not the fork), so ordinary backtracking that
          // revisits a fork at an earlier sp is unaffected — only a genuine no-progress iteration is caught.
          const forkPc: i32 = pc + Porffor.wasm.i32.load16_s(pc, 0, 1);
          const exitTarget: i32 = forkPc + Porffor.wasm.i32.load16_s(forkPc, 0, 3);

          let mi: i32 = backtrackStack.length - 3;
          let entrySp: i32 = -1;
          while (mi >= 0) {
            if (backtrackStack[mi] == exitTarget) { entrySp = backtrackStack[mi + 1]; break; }
            mi = mi - 1;
          }

          if (entrySp == sp) {
            pc = exitTarget; // zero-width iteration → stop the loop
          } else {
            pc = forkPc; // progress made → keep looping
          }
          break;
        }

        case 0x30: { // start capture
          const capIndex: i32 = Porffor.wasm.i32.load8_u(pc, 0, 1);
          captures[capIndex + 1024] = sp;
          pc += 2;
          break;
        }

        case 0x31: { // end capture
          const capIndex: i32 = Porffor.wasm.i32.load8_u(pc, 0, 1);
          const arrIndex: i32 = capIndex * 2 + 1;
          const len: i32 = captures.length;
          if (len <= arrIndex) {
            captures.length = arrIndex + 1;
            for (let j: i32 = len; j < arrIndex - 1; j++) captures[j] = -1;
          }
          captures[arrIndex - 1] = captures[capIndex + 1024];
          captures[arrIndex] = sp;
          pc += 2;
          break;
        }

        default:
          backtrack = true;
          break;
      }

      if (backtrack) {
        // Unwind choice points. A lookahead marker on top needs special handling, and a failed
        // *positive* lookahead must keep unwinding to the previous real choice point (so a preceding
        // greedy quantifier can give back characters) rather than resume at a stale pc.
        let unwinding: boolean = true;
        while (unwinding) {
          const len: i32 = backtrackStack.length;
          if (len == 0) break interpreter; // no choices left → this start position fails

          const marker: i32 = len >= 4 ? backtrackStack[len - 1] : 0;
          if (marker == -2000) {
            // negative lookahead body failed == the negative lookahead SUCCEEDS → continue past it
            sp = backtrackStack[len - 3];
            captures.length = backtrackStack[len - 2];
            pc = backtrackStack[len - 4];
            backtrackStack.length = len - 4;
            unwinding = false;
          } else if (marker == -3000) {
            // positive lookahead body failed → the lookahead fails → keep unwinding
            sp = backtrackStack[len - 3];
            captures.length = backtrackStack[len - 2];
            backtrackStack.length = len - 4;
          } else {
            captures.length = backtrackStack[len - 1];
            sp = backtrackStack[len - 2];
            pc = backtrackStack[len - 3];
            backtrackStack.length = len - 3;
            unwinding = false;
          }
        }
      }
    }

    if (matched) {
      if (isTest) return true;

      const matchStart: i32 = i;
      if (global || sticky) {
        Porffor.wasm.i32.store16(regexp, finalSp, 0, 8); // write last index
      }

      const result: any[] = Porffor.malloc(4096);
      // Slice in the input's own encoding (UTF-16 for wide, Latin1 for narrow) — sp/capture indices are code
      // units either way, so a wide slice keeps surrogate pairs intact.
      if (wide) {
        Porffor.array.fastPush(result, __String_prototype_substring(input as string, matchStart, finalSp));
      } else {
        Porffor.array.fastPush(result, __ByteString_prototype_substring(input, matchStart, finalSp));
      }

      for (let k: i32 = 0; k < totalCaptures; k++) {
        const arrIdx: i32 = k * 2;
        if (arrIdx + 1 < captures.length) {
          const capStart: i32 = captures[arrIdx];
          const capEnd: i32 = captures[arrIdx + 1];
          if (capStart != -1 && capEnd != -1) {
            if (wide) {
              Porffor.array.fastPush(result, __String_prototype_substring(input as string, capStart, capEnd));
            } else {
              Porffor.array.fastPush(result, __ByteString_prototype_substring(input, capStart, capEnd));
            }
          } else {
            Porffor.array.fastPush(result, undefined);
          }
        } else {
          Porffor.array.fastPush(result, undefined);
        }
      }

      result.index = matchStart;
      if (wide) { result.input = input as string; } else { result.input = input as bytestring; }

      // .groups — an object of name→capture for named groups, or undefined when the pattern has none
      // (the property still exists per spec). Names + their group numbers come from the compiled table.
      const namesPtr: i32 = Porffor.wasm.i32.load(regexp, 0, 10);
      if (namesPtr != 0) {
        const nameCount: i32 = Porffor.wasm.i32.load16_u(namesPtr, 0, 0);
        const groups: object = {};
        let np: i32 = namesPtr + 2;
        for (let e: i32 = 0; e < nameCount; e++) {
          const g: i32 = Porffor.wasm.i32.load16_u(np, 0, 0);
          const nl: i32 = Porffor.wasm.i32.load16_u(np, 0, 2);
          np += 4;
          const key: bytestring = Porffor.malloc(6 + nl);
          const keyPtr: i32 = Porffor.wasm`local.get ${key}`;
          for (let k: i32 = 0; k < nl; k++) {
            Porffor.wasm.i32.store8(keyPtr + k, Porffor.wasm.i32.load8_u(np + k, 0, 0), 0, 4);
          }
          key.length = nl;
          np += nl;
          __Porffor_object_fastAdd(groups, key, __Array_prototype_at(result, g), 0b1110);
        }
        result.groups = groups;
      } else {
        result.groups = undefined;
      }

      return result;
    }

    if (sticky) { // sticky, do not go forward in string
      Porffor.wasm.i32.store16(regexp, 0, 0, 8); // failed, write 0 last index
      if (isTest) return false;
      return null;
    }
  }

  if (global || sticky) {
    Porffor.wasm.i32.store16(regexp, 0, 0, 8); // failed, write 0 last index
  }

  if (isTest) return false;
  return null;
};


export const __RegExp_prototype_source$get = (_this: RegExp) => {
  return Porffor.wasm.i32.load(_this, 0, 0) as bytestring;
};

export const __RegExp_prototype_lastIndex$get = (_this: RegExp) => {
  return Porffor.wasm.i32.load16_u(_this, 0, 8);
};

// 22.2.6.4 get RegExp.prototype.flags
// https://tc39.es/ecma262/multipage/text-processing.html#sec-get-regexp.prototype.flags
export const __RegExp_prototype_flags$get = (_this: RegExp) => {
  // 1. Let R be the this value.
  // 2. If R is not an Object, throw a TypeError exception.
  if (!Porffor.object.isObject(_this)) throw new TypeError('this is a non-object');

  // 3. Let codeUnits be a new empty List.
  const flags: i32 = Porffor.wasm.i32.load16_u(_this, 0, 4);
  const result: bytestring = Porffor.malloc(16);

  // 4. Let hasIndices be ToBoolean(? Get(R, "hasIndices")).
  // 5. If hasIndices is true, append the code unit 0x0064 (LATIN SMALL LETTER D) to codeUnits.
  if (flags & 0b01000000) Porffor.bytestring.appendChar(result, 0x64);
  // 6. Let global be ToBoolean(? Get(R, "global")).
  // 7. If global is true, append the code unit 0x0067 (LATIN SMALL LETTER G) to codeUnits.
  if (flags & 0b00000001) Porffor.bytestring.appendChar(result, 0x67);
  // 8. Let ignoreCase be ToBoolean(? Get(R, "ignoreCase")).
  // 9. If ignoreCase is true, append the code unit 0x0069 (LATIN SMALL LETTER I) to codeUnits.
  if (flags & 0b00000010) Porffor.bytestring.appendChar(result, 0x69);
  // 10. Let multiline be ToBoolean(? Get(R, "multiline")).
  // 11. If multiline is true, append the code unit 0x006D (LATIN SMALL LETTER M) to codeUnits.
  if (flags & 0b00000100) Porffor.bytestring.appendChar(result, 0x6d);
  // 12. Let dotAll be ToBoolean(? Get(R, "dotAll")).
  // 13. If dotAll is true, append the code unit 0x0073 (LATIN SMALL LETTER S) to codeUnits.
  if (flags & 0b00001000) Porffor.bytestring.appendChar(result, 0x73);
  // 14. Let unicode be ToBoolean(? Get(R, "unicode")).
  // 15. If unicode is true, append the code unit 0x0075 (LATIN SMALL LETTER U) to codeUnits.
  if (flags & 0b00010000) Porffor.bytestring.appendChar(result, 0x75);
  // 16. Let unicodeSets be ToBoolean(? Get(R, "unicodeSets")).
  // 17. If unicodeSets is true, append the code unit 0x0076 (LATIN SMALL LETTER V) to codeUnits.
  if (flags & 0b10000000) Porffor.bytestring.appendChar(result, 0x76);
  // 18. Let sticky be ToBoolean(? Get(R, "sticky")).
  // 19. If sticky is true, append the code unit 0x0079 (LATIN SMALL LETTER Y) to codeUnits.
  if (flags & 0b00100000) Porffor.bytestring.appendChar(result, 0x79);

  // 20. Return the String value whose code units are the elements of the List codeUnits.
  //     If codeUnits has no elements, the empty String is returned.
  return result;
};

export const __RegExp_prototype_global$get = (_this: RegExp) => {
  return ((Porffor.wasm.i32.load16_u(_this, 0, 4) & 0b00000001) != 0) as boolean;
};

export const __RegExp_prototype_ignoreCase$get = (_this: RegExp) => {
  return ((Porffor.wasm.i32.load16_u(_this, 0, 4) & 0b00000010) != 0) as boolean;
};

export const __RegExp_prototype_multiline$get = (_this: RegExp) => {
  return ((Porffor.wasm.i32.load16_u(_this, 0, 4) & 0b00000100) != 0) as boolean;
};

export const __RegExp_prototype_dotAll$get = (_this: RegExp) => {
  return ((Porffor.wasm.i32.load16_u(_this, 0, 4) & 0b00001000) != 0) as boolean;
};

export const __RegExp_prototype_unicode$get = (_this: RegExp) => {
  return ((Porffor.wasm.i32.load16_u(_this, 0, 4) & 0b00010000) != 0) as boolean;
};

export const __RegExp_prototype_sticky$get = (_this: RegExp) => {
  return ((Porffor.wasm.i32.load16_u(_this, 0, 4) & 0b00100000) != 0) as boolean;
};

export const __RegExp_prototype_hasIndices$get = (_this: RegExp) => {
  return (Porffor.wasm.i32.load16_u(_this, 0, 4) & 0b01000000) as boolean;
};

export const __RegExp_prototype_unicodeSets$get = (_this: RegExp) => {
  return (Porffor.wasm.i32.load16_u(_this, 0, 4) & 0b10000000) as boolean;
};

export const __RegExp_prototype_toString = (_this: RegExp) => {
  return '/' + _this.source + '/' + _this.flags;
};


export const RegExp = function (pattern: any, flags: any): RegExp {
  let patternSrc, flagsSrc;
  if (Porffor.type(pattern) === Porffor.TYPES.regexp) {
    patternSrc = __RegExp_prototype_source$get(pattern);
    if (flags === undefined) {
      flagsSrc = __RegExp_prototype_flags$get(pattern);
    } else {
      flagsSrc = flags;
    }
  } else {
    patternSrc = pattern;
    flagsSrc = flags;
  }

  if (patternSrc === undefined) patternSrc = '';
  if (flagsSrc === undefined) flagsSrc = '';

  // The regex compiler normalizes the pattern itself: it accepts EITHER a narrow bytestring OR a wide 2-byte
  // `string` (e.g. acorn/rollup build regexes dynamically, and code points > 255 like combining marks must
  // survive) and copies it into a uniform 16-bit scratch buffer. So pass a `string` pattern through unchanged
  // — do NOT downcast it to a bytestring (that truncated code points > 255, corrupting e.g. /[̀-ͯ]/). Flags
  // are always ASCII, and the compile signature wants a bytestring, so downcast those.
  if (Porffor.type(flagsSrc) === Porffor.TYPES.string) {
    let fbs: bytestring = Porffor.malloc();
    Porffor.bytestring.appendStr(fbs, flagsSrc);
    flagsSrc = fbs;
  }

  const patType: i32 = Porffor.type(patternSrc);
  if ((patType !== Porffor.TYPES.bytestring && patType !== Porffor.TYPES.string) || Porffor.type(flagsSrc) !== Porffor.TYPES.bytestring) {
    throw new TypeError('Invalid regular expression');
  }

  return __Porffor_regex_compile(patternSrc, flagsSrc);
};


export const __RegExp_prototype_exec = (_this: RegExp, input: any) => {
  if (Porffor.type(input) !== Porffor.TYPES.bytestring) input = ecma262.ToString(input);
  return __Porffor_regex_interpret(_this, input, false, Porffor.type(input) == Porffor.TYPES.string);
};

export const __RegExp_prototype_test = (_this: RegExp, input: any) => {
  if (Porffor.type(input) !== Porffor.TYPES.bytestring) input = ecma262.ToString(input);
  return __Porffor_regex_interpret(_this, input, true, Porffor.type(input) == Porffor.TYPES.string);
};


export const __Porffor_regex_match = (regexp: any, input: any) => {
  if (Porffor.type(regexp) !== Porffor.TYPES.regexp) regexp = new RegExp(regexp);
  if (Porffor.type(input) !== Porffor.TYPES.bytestring) input = ecma262.ToString(input);

  if (__RegExp_prototype_global$get(regexp)) {
    // global match returns every whole-match string. fastPush does NOT grow a malloc'd array, so size the
    // buffer to the input up front — there can be at most input.length+1 matches (zero-width included).
    // (A fixed 4096-byte buffer overflowed past ~500 matches; marked hits this on real input.)
    const result: any[] = Porffor.malloc((input.length + 4) * 16);
    let match: any[];
    while (match = __Porffor_regex_interpret(regexp, input, false, Porffor.type(input) == Porffor.TYPES.string)) {
      const ms: bytestring = ecma262.ToString(__Array_prototype_at(match, 0));
      Porffor.array.fastPush(result, ms);
      // A zero-width match doesn't advance lastIndex → bump it by one so the global scan makes progress
      // (otherwise it matches empty at the same spot forever). interpret() returns null past the end.
      if (ms.length == 0) {
        const li: i32 = Porffor.wasm.i32.load16_u(regexp, 0, 8);
        Porffor.wasm.i32.store16(regexp, li + 1, 0, 8);
      }
    }
    // A global match with no matches returns null (not an empty array), per ECMAScript.
    if (result.length == 0) return null;
    return result;
  }

  return __Porffor_regex_interpret(regexp, input, false, Porffor.type(input) == Porffor.TYPES.string);
};

export const __String_prototype_match = (_this: string, regexp: any) => {
  return __Porffor_regex_match(regexp, _this);
};

export const __ByteString_prototype_match = (_this: bytestring, regexp: any) => {
  return __Porffor_regex_match(regexp, _this);
};


// todo: use actual iterator not array
export const __Porffor_regex_matchAll = (regexp: any, input: any) => {
  if (Porffor.type(regexp) !== Porffor.TYPES.regexp) regexp = new RegExp(regexp, 'g');
  if (Porffor.type(input) !== Porffor.TYPES.bytestring) input = ecma262.ToString(input);

  if (!__RegExp_prototype_global$get(regexp)) throw new TypeError('matchAll used with non-global RegExp');

  // Size to the input — at most input.length+1 matches; fastPush won't grow a malloc'd buffer (see match).
  const result: any[] = Porffor.malloc((input.length + 4) * 16);
  let match: any[];
  while (match = __Porffor_regex_interpret(regexp, input, false, Porffor.type(input) == Porffor.TYPES.string)) {
    Porffor.array.fastPush(result, match);
    // bump lastIndex past a zero-width match so the scan progresses (see __Porffor_regex_match).
    if (ecma262.ToString(__Array_prototype_at(match, 0)).length == 0) {
      const li: i32 = Porffor.wasm.i32.load16_u(regexp, 0, 8);
      Porffor.wasm.i32.store16(regexp, li + 1, 0, 8);
    }
  }
  return result;
};

export const __String_prototype_matchAll = (_this: string, regexp: any) => {
  return __Porffor_regex_matchAll(regexp, _this);
};

export const __ByteString_prototype_matchAll = (_this: bytestring, regexp: any) => {
  return __Porffor_regex_matchAll(regexp, _this);
};


// Expand a replacement template into `out`, given the match-result array `m` (m[0] = whole match,
// m[1..] = capture groups, m.length = 1 + groupCount), the match start `position`, and the source.
// Handles the spec $-patterns: $$ -> '$', $& -> whole match, $` -> prefix, $' -> suffix,
// $n / $nn -> capture group (left literal when no such group exists).
export const __Porffor_regex_appendSubst = (out: bytestring, template: bytestring, m: any[], position: number, source: bytestring) => {
  const matched: bytestring = ecma262.ToString(__Array_prototype_at(m, 0));
  const mLen: number = matched.length;
  const ncap: number = m.length; // 1 + number of capture groups
  const tlen: number = template.length;
  const srcLen: number = source.length;

  let i: number = 0;
  while (i < tlen) {
    const c: i32 = template.charCodeAt(i);
    if (c == 36 && i + 1 < tlen) { // '$'
      const n1: i32 = template.charCodeAt(i + 1);
      if (n1 == 36) { Porffor.bytestring.appendChar(out, 36); i += 2; continue; }          // $$
      if (n1 == 38) { Porffor.bytestring.appendStr(out, matched); i += 2; continue; }       // $&
      if (n1 == 96) { // $`  -> portion before the match
        Porffor.bytestring.appendStr(out, __ByteString_prototype_substring(source, 0, position));
        i += 2; continue;
      }
      if (n1 == 39) { // $'  -> portion after the match
        Porffor.bytestring.appendStr(out, __ByteString_prototype_substring(source, position + mLen, srcLen));
        i += 2; continue;
      }
      if (n1 >= 49 && n1 <= 57) { // '1'-'9' -> capture group ($0 is not special)
        let gi: number = n1 - 48;
        let consumed: number = 2;
        if (i + 2 < tlen) {
          const n2: i32 = template.charCodeAt(i + 2);
          if (n2 >= 48 && n2 <= 57) {
            const two: number = gi * 10 + (n2 - 48);
            if (two < ncap) { gi = two; consumed = 3; } // prefer the two-digit group when it exists
          }
        }
        if (gi < ncap) {
          const cap: any = __Array_prototype_at(m, gi);
          // ToString lands the capture in a clean bytestring (undefined groups -> skipped).
          if (Porffor.type(cap) != Porffor.TYPES.undefined) {
            const capStr: bytestring = ecma262.ToString(cap);
            Porffor.bytestring.appendStr(out, capStr);
          }
          i += consumed; continue;
        }
        // no such group: fall through and emit the '$' literally
      }
    }

    Porffor.bytestring.appendChar(out, c);
    i++;
  }
};

// Shared core for String.prototype.replace / replaceAll. `pattern` may be a string or a RegExp;
// `replacement` may be a string template or a function. `forceAll` makes a string pattern replace
// every occurrence (replaceAll) and forces a RegExp to behave globally.
export const __Porffor_string_replace = (_this: bytestring, pattern: any, replacement: any, forceAll: boolean) => {
  const srcLen: number = _this.length;

  const isFunc: boolean = Porffor.type(replacement) == Porffor.TYPES.function;
  let replStr: bytestring = '';
  if (!isFunc) replStr = ecma262.ToString(replacement);

  const out: bytestring = Porffor.malloc();

  if (Porffor.type(pattern) == Porffor.TYPES.regexp) {
    const isGlobal: boolean = __RegExp_prototype_global$get(pattern) || forceAll;
    Porffor.wasm.i32.store16(pattern, 0, 0, 8); // reset lastIndex

    let lastEnd: number = 0;
    while (true) {
      const m: any[] = __Porffor_regex_interpret(pattern, _this, false, Porffor.type(_this) == Porffor.TYPES.string);
      if (m == 0) break;

      const mStart: number = m.index;
      const matched: bytestring = ecma262.ToString(__Array_prototype_at(m, 0));
      const mLen: number = matched.length;

      Porffor.bytestring.appendStr(out, __ByteString_prototype_substring(_this, lastEnd, mStart));

      if (isFunc) {
        // call replacement(match, p1..pn, offset, string) via apply (the spread path Porffor.call
        // miscompiles for a freshly-built array); ToString the result before appending.
        const args: any[] = Porffor.malloc(4096);
        const capCount: number = m.length;
        for (let k: i32 = 0; k < capCount; k++) Porffor.array.fastPush(args, __Array_prototype_at(m, k));
        Porffor.array.fastPush(args, mStart);
        Porffor.array.fastPush(args, _this);
        const r: any = __Function_prototype_apply(replacement, undefined, args);
        const rStr: bytestring = ecma262.ToString(r);
        Porffor.bytestring.appendStr(out, rStr);
      } else {
        __Porffor_regex_appendSubst(out, replStr, m, mStart, _this);
      }

      lastEnd = mStart + mLen;
      if (!isGlobal) break;

      if (mLen == 0) {
        // empty match: bump lastIndex by one so we make progress and don't loop forever
        const li: i32 = Porffor.wasm.i32.load16_u(pattern, 0, 8);
        Porffor.wasm.i32.store16(pattern, li + 1, 0, 8);
        if (li + 1 > srcLen) break;
      }
    }

    Porffor.bytestring.appendStr(out, __ByteString_prototype_substring(_this, lastEnd, srcLen));
    Porffor.wasm.i32.store16(pattern, 0, 0, 8); // leave lastIndex reset
    return out;
  }

  // string pattern
  const patStr: bytestring = ecma262.ToString(pattern);
  const patLen: number = patStr.length;

  let from: number = 0;
  let found: boolean = false;
  while (true) {
    const idx: number = __ByteString_prototype_indexOf(_this, patStr, from);
    if (idx == -1) break;
    found = true;

    Porffor.bytestring.appendStr(out, __ByteString_prototype_substring(_this, from, idx));

    if (isFunc) {
      const args: any[] = Porffor.malloc(4096);
      Porffor.array.fastPush(args, patStr);
      Porffor.array.fastPush(args, idx);
      Porffor.array.fastPush(args, _this);
      const r: any = __Function_prototype_apply(replacement, undefined, args);
      const rStr: bytestring = ecma262.ToString(r);
      Porffor.bytestring.appendStr(out, rStr);
    } else {
      // synthesize a 0-group match array so $&, $`, $', $$ work (numbered groups stay literal)
      const fake: any[] = Porffor.malloc(4096);
      Porffor.array.fastPush(fake, patStr);
      __Porffor_regex_appendSubst(out, replStr, fake, idx, _this);
    }

    from = idx + patLen;
    if (patLen == 0) {
      if (from < srcLen) { Porffor.bytestring.appendChar(out, _this.charCodeAt(from)); from++; }
      else break;
    }

    if (!forceAll) break;
    if (from > srcLen) break;
  }

  if (!found) return _this;
  Porffor.bytestring.appendStr(out, __ByteString_prototype_substring(_this, from, srcLen));
  return out;
};

export const __String_prototype_replace = (_this: string, pattern: any, replacement: any) => {
  return __Porffor_string_replace(_this, pattern, replacement, false);
};

export const __ByteString_prototype_replace = (_this: bytestring, pattern: any, replacement: any) => {
  return __Porffor_string_replace(_this, pattern, replacement, false);
};

export const __String_prototype_replaceAll = (_this: string, pattern: any, replacement: any) => {
  if (Porffor.type(pattern) == Porffor.TYPES.regexp && !__RegExp_prototype_global$get(pattern))
    throw new TypeError('replaceAll must be called with a global RegExp');
  return __Porffor_string_replace(_this, pattern, replacement, true);
};

export const __ByteString_prototype_replaceAll = (_this: bytestring, pattern: any, replacement: any) => {
  if (Porffor.type(pattern) == Porffor.TYPES.regexp && !__RegExp_prototype_global$get(pattern))
    throw new TypeError('replaceAll must be called with a global RegExp');
  return __Porffor_string_replace(_this, pattern, replacement, true);
};

export const __Porffor_string_search = (_this: any, regexp: any) => {
  if (Porffor.type(_this) !== Porffor.TYPES.bytestring) _this = ecma262.ToString(_this);
  if (Porffor.type(regexp) !== Porffor.TYPES.regexp) regexp = new RegExp(regexp);
  Porffor.wasm.i32.store16(regexp, 0, 0, 8);
  const m: any = __Porffor_regex_interpret(regexp, _this, false, Porffor.type(_this) == Porffor.TYPES.string);
  Porffor.wasm.i32.store16(regexp, 0, 0, 8);
  if (m == 0) return -1;
  return m.index;
};

export const __String_prototype_search = (_this: string, regexp: any) => {
  return __Porffor_string_search(_this, regexp);
};

export const __ByteString_prototype_search = (_this: bytestring, regexp: any) => {
  return __Porffor_string_search(_this, regexp);
};


export const __Porffor_regex_escapeX = (out: bytestring, char: i32) => {
  // 0-9 or a-z or A-Z as first char - escape as \xNN
  Porffor.bytestring.append2Char(out, 92, 120);

  let char1: i32 = 48 + Math.floor(char / 16);
  if (char1 > 57) char1 += 39; // 58 (:) -> 97 (a)
  let char2: i32 = 48 + char % 16;
  if (char2 > 57) char2 += 39; // 58 (:) -> 97 (a)
  Porffor.bytestring.append2Char(out, char1, char2);
};

export const __RegExp_escape = (str: any) => {
  const out: bytestring = Porffor.malloc();

  let i: i32 = 0;
  const first: i32 = str.charCodeAt(0);
  if ((first > 47 && first < 58) || (first > 96 && first < 123) || (first > 64 && first < 91)) {
    __Porffor_regex_escapeX(out, first);
    i++;
  }

  const len: i32 = str.length;
  for (; i < len; i++) {
    const char: i32 = str.charCodeAt(i);
    // ^, $, \, ., *, +, ?, (, ), [, ], {, }, |, /
    if (Porffor.fastOr(char == 94, char == 36, char == 92, char == 46, char == 42, char == 43, char == 63, char == 40, char == 41, char == 91, char == 93, char == 123, char == 125, char == 124, char == 47)) {
      // regex syntax, escape with \
      Porffor.bytestring.append2Char(out, 92, char);
      continue;
    }

    // ,, -, =, <, >, #, &, !, %, :, ;, @, ~, ', `, "
    if (Porffor.fastOr(char == 44, char == 45, char == 61, char == 60, char == 62, char == 35, char == 38, char == 33, char == 37, char == 58, char == 59, char == 64, char == 126, char == 39, char == 96, char == 34)) {
      // punctuator, escape with \x
      __Porffor_regex_escapeX(out, char);
      continue;
    }

    // \f, \n, \r, \t, \v, \x20
    if (char == 12) {
      Porffor.bytestring.append2Char(out, 92, 102);
      continue;
    }
    if (char == 10) {
      Porffor.bytestring.append2Char(out, 92, 110);
      continue;
    }
    if (char == 13) {
      Porffor.bytestring.append2Char(out, 92, 114);
      continue;
    }
    if (char == 9) {
      Porffor.bytestring.append2Char(out, 92, 116);
      continue;
    }
    if (char == 11) {
      Porffor.bytestring.append2Char(out, 92, 118);
      continue;
    }
    if (char == 32) {
      Porffor.bytestring.append2Char(out, 92, 120);
      Porffor.bytestring.append2Char(out, 50, 48);
      continue;
    }

    // todo: surrogates
    Porffor.bytestring.appendChar(out, char);
  }

  return out;
};