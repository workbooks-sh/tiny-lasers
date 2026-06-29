// Porffor↔host call bridge — GUEST prelude (prepend to a Porffor-compiled program that needs host I/O).
//
// Pairs with Nexus.Compilers.Js.PorfforHost (the `e` import handler) and the `__host_call` import declared
// in compiler/wrap.js. Exchanges bytes through linear memory (nothing but integers cross the wasm
// boundary): the op name + request bytes go OUT by pointer, the host writes the result region, and we copy
// the N result bytes back into a real `Uint8Array` the program can index.
//
// NOTE: written in Porffor's annotated-JS `Porffor.wasm` dialect — only valid when compiled BY Porffor.
// `Porffor.wasm\`local.get ${x}\`` yields the linear-memory pointer of a local/param; a bytestring's data
// lives at pointer+4 (past the i32 length prefix). `Porffor.malloc()` (no arg) returns a fresh 64KB page.

const hostCall = (op, req) => {
  const opPtr = Porffor.wasm`local.get ${op}` + 4;
  const reqPtr = Porffor.wasm`local.get ${req}` + 4;
  const resBuf = Porffor.malloc();
  const resPtr = Porffor.wasm`local.get ${resBuf}`;
  const n = __host_call(opPtr, op.length, reqPtr, req.length, resPtr, 65536);
  const u = new Uint8Array(n);
  let i = 0;
  while (i < n) { u[i] = Porffor.wasm.i32.load8_u(resPtr + i, 0, 0); i = i + 1; }
  return u;
};

// The JS-visible adapter Rollup's native_bridge calls: __host("rollup_parse", [code, allowReturn, jsx]).
// We return the raw AST buffer as a Uint8Array (skipping Rollup's base64 round-trip); a Rollup-specific
// shim overrides b64ToU8/parse to consume this directly when the full bundle runs.
const __host = (name, args) => hostCall(name, args[0]);
