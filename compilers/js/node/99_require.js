// Node-core shim — module 99: install require()/module/exports and CLOSE the IIFE.
// MUST sort last (every def() above has run, so M is fully populated). require strips a leading
// 'node:' prefix; an unknown specifier throws like Node. The I/O modules (fs/net/http/crypto/…) are
// added by their own NN_*.js files which def() into M before this runs — no change needed here.
globalThis.require=function(n){n=String(n).replace(/^node:/,'');if(M[n])return M[n];throw new Error("Cannot find module '"+n+"'");};
globalThis.require.resolve=function(n){return n;};
globalThis.module={exports:{}};globalThis.exports=globalThis.module.exports;
})();
