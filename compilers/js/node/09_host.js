// The generic host bridge JS side (wb-5q8w) — how every Node I/O concern reaches the Elixir host without
// a per-concern C wrapper. __host(name,args) is a SYNC round-trip (host op runs inline, returns a value);
// __host_async(name,args) returns a Promise resolved when the concern calls Actor.io_complete. A concern's
// node/NN_<mod>.js shim is pure JS over these two — it never touches harness_run.c.
globalThis.__host=function(name,args){return JSON.parse(__host_call(String(name),JSON.stringify(args===undefined?[]:args)));};
globalThis.__host_async=function(name,args){return __wb_async(function(id){__host_call_async(String(name),JSON.stringify(args===undefined?[]:args),id);});};
