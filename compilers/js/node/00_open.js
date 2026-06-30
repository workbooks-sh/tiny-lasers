// Node-core shim — module 00: open the IIFE + the CommonJS registry.
// Each Node core module is its own file here (conflict-free fan-out: an agent adds node/<NN_mod>.js
// without touching harness_run.c). build.sh concatenates these IN FILENAME ORDER into a single
// NODE_PRELUDE C string. 00_open opens the closure; 99_require installs require()+globals and closes it.
// All files share this one IIFE scope, so a `var`/`function` here is visible to later module files.
(function(){
var M={};
function def(n,m){M[n]=m;}
globalThis.global=globalThis;
