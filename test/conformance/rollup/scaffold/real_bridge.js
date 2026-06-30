// Porffor-lane bridge HEADER for running the UNMODIFIED real rollup_bundle.cjs (not the approximation).
// PREPEND host_prelude.js (minus its parser-specialized `const __host`) before this — it provides the
// proven `hostCall(op, req)` byte bridge (returns a Uint8Array). Here we pre-declare the node globals as
// module-scope vars (Porffor can't bind a bare ref from `globalThis.X =`, and a globalThis->var transform
// would redeclare a `const` as a SyntaxError — so declare explicitly), and define a JSON-shaped __host
// returning EXACTLY the {ok,b64}/{h} shapes the real bundle's native_bridge expects (b64ToU8(r.b64) / r.h).
// The host (PorfforHost) returns the base64 / hash STRING via the op-name-encoded byte ABI
// (rollup_parse_b64, rollup_xxhash_<kind>), so no codepath in the bundle is modified.
var require, module, exports, process, Buffer, global, setTimeout, clearTimeout, setInterval, clearInterval, queueMicrotask, __host, TextEncoder, TextDecoder, btoa, atob;
globalThis.Javy = { IO: { writeSync: function(fd, u8){ return (u8 && u8.length) || 0; } } };
TextEncoder = function(){ this.encode = function(s){ var a=[]; for(var i=0;i<s.length;i++) a.push(s.charCodeAt(i)&255); return a; }; };
TextDecoder = function(){ this.decode = function(u8){ var s=''; for(var i=0;i<u8.length;i++) s+=String.fromCharCode(u8[i]); return s; }; };

// decode the host's Uint8Array result (ASCII base64 / hash text) into a JS string.
var __u8str = function(u){ var s = ''; for (var i = 0; i < u.length; i++) s += String.fromCharCode(u[i]); return s; };

// UNMODIFIED-bundle __host over host_prelude's hostCall: {ok,b64} for parse, {h} for xxhash (kind folded
// into the op name).
__host = function(name, args){
  if (name === "rollup_parse") return { ok: true, b64: __u8str(hostCall("rollup_parse_b64", String(args[0]))) };
  if (name === "rollup_xxhash") return { h: __u8str(hostCall("rollup_xxhash_" + args[1], String(args[0]))) };
  return undefined;
};
