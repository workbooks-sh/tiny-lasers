var globalThis = {};
var global = globalThis;
var self = globalThis;
var module = { exports: {} };
var exports = module.exports;
var process = { env: {}, argv: [], platform: "linux", version: "v18.0.0", nextTick: function(f){ f(); }, cwd: function(){ return "/"; } };
function require(n) {
  if (n === "tty") return { isatty: function(){ return false; } };
  return {};
}
