// Node host-surface shims for the F2 rollup lane — pure guest JS (confined; no host escape). Virtualizes the
// Node builtins rollup's reachable code path touches: events, path, process, os, util, fs (in-memory), etc.
// Layered AFTER cjs_prelude (which defines module/exports/require/process/globalThis) and OVERRIDES its
// stub require with a dispatching one.

// ── events.EventEmitter ──
function EventEmitter() { this._events = {}; }
EventEmitter.prototype.on = function(ev, fn) { (this._events[ev] || (this._events[ev] = [])).push(fn); return this; };
EventEmitter.prototype.addListener = EventEmitter.prototype.on;
EventEmitter.prototype.once = function(ev, fn) {
  var self = this; function g() { self.off(ev, g); return fn.apply(this, arguments); }
  return this.on(ev, g);
};
EventEmitter.prototype.off = function(ev, fn) {
  var l = this._events[ev]; if (l) this._events[ev] = l.filter(function(f){ return f !== fn; }); return this;
};
EventEmitter.prototype.removeListener = EventEmitter.prototype.off;
EventEmitter.prototype.removeAllListeners = function(ev) { if (ev) delete this._events[ev]; else this._events = {}; return this; };
EventEmitter.prototype.emit = function(ev) {
  var l = this._events[ev]; if (!l) return false;
  var args = Array.prototype.slice.call(arguments, 1);
  l.slice().forEach(function(f){ f.apply(this, args); });
  return true;
};
EventEmitter.prototype.listeners = function(ev) { return (this._events[ev] || []).slice(); };

// ── path (posix) ──
var path = {
  sep: "/",
  delimiter: ":",
  resolve: function() {
    var resolved = "";
    for (var i = arguments.length - 1; i >= 0; i--) {
      var p = arguments[i]; if (!p) continue;
      resolved = p + "/" + resolved;
      if (p.charAt(0) === "/") break;
    }
    if (resolved.charAt(0) !== "/") resolved = "/" + resolved;
    return path.normalize(resolved) || "/";
  },
  normalize: function(p) {
    if (!p) return ".";
    var abs = p.charAt(0) === "/";
    var trail = p.length > 1 && p.charAt(p.length - 1) === "/";
    var parts = p.split("/"); var out = [];
    for (var i = 0; i < parts.length; i++) {
      var seg = parts[i];
      if (seg === "" || seg === ".") continue;
      if (seg === "..") { if (out.length && out[out.length-1] !== "..") out.pop(); else if (!abs) out.push(".."); }
      else out.push(seg);
    }
    var res = out.join("/");
    if (abs) res = "/" + res;
    if (trail && res.charAt(res.length-1) !== "/") res += "/";
    return res || (abs ? "/" : ".");
  },
  join: function() {
    var parts = Array.prototype.slice.call(arguments).filter(function(p){ return p && typeof p === "string"; });
    return parts.length ? path.normalize(parts.join("/")) : ".";
  },
  dirname: function(p) {
    if (!p) return ".";
    var i = p.lastIndexOf("/");
    if (i < 0) return "."; if (i === 0) return "/";
    return p.slice(0, i);
  },
  basename: function(p, ext) {
    var b = p.slice(p.lastIndexOf("/") + 1);
    if (ext && b.slice(-ext.length) === ext) b = b.slice(0, -ext.length);
    return b;
  },
  extname: function(p) {
    var b = p.slice(p.lastIndexOf("/") + 1);
    var i = b.lastIndexOf(".");
    return i > 0 ? b.slice(i) : "";
  },
  isAbsolute: function(p) { return !!p && p.charAt(0) === "/"; },
  relative: function(from, to) {
    from = path.resolve(from); to = path.resolve(to);
    if (from === to) return "";
    var f = from.split("/").filter(Boolean), t = to.split("/").filter(Boolean);
    var i = 0; while (i < f.length && i < t.length && f[i] === t[i]) i++;
    var up = []; for (var j = i; j < f.length; j++) up.push("..");
    return up.concat(t.slice(i)).join("/");
  }
};
path.posix = path;
var pathWin = path; // rollup only uses posix on this platform

// ── minimal in-memory fs (virtual; rollup's bundle path uses plugin load, not real fs) ──
var fs = {
  readFileSync: function(){ throw new Error("ENOENT"); },
  existsSync: function(){ return false; },
  statSync: function(){ throw new Error("ENOENT"); },
  promises: { readFile: function(){ return Promise.reject(new Error("ENOENT")); } }
};

// ── util ──
var util = {
  inspect: function(x){ return String(x); },
  promisify: function(fn){ return function(){ var a = Array.prototype.slice.call(arguments); return new Promise(function(res, rej){ a.push(function(err, v){ if (err) rej(err); else res(v); }); fn.apply(this, a); }); }; },
  inherits: function(ctor, sup){ ctor.super_ = sup; ctor.prototype = Object.create(sup.prototype); ctor.prototype.constructor = ctor; }
};

// ── os ──
var os = { platform: function(){ return "linux"; }, EOL: "\n", cpus: function(){ return [{}]; }, tmpdir: function(){ return "/tmp"; } };

// enrich process
process.cwd = function(){ return "/"; };
process.hrtime = function(){ return [0, 0]; };
process.hrtime.bigint = function(){ return 0; };
process.stderr = { write: function(){ return true; } };
process.stdout = { write: function(){ return true; }, isTTY: false };
process.platform = "linux";
process.versions = { node: "18.0.0" };
process.emitWarning = function(){};
process.on = function(){ return process; };
process.once = function(){ return process; };
process.off = function(){ return process; };
process.removeListener = function(){ return process; };
process.prependListener = function(){ return process; };
process.emit = function(){ return false; };
process.exit = function(){};

// ── dispatching require (a function DECLARATION so it wins the registry over cjs_prelude's stub — a bare
// `require = function(){}` would only bind a local, leaving the bundle's greg-resolved require pointing at
// the stub) ──
function require(n) {
  switch (n) {
    case "events": { var e = EventEmitter; e.EventEmitter = EventEmitter; e.default = EventEmitter; return e; }
    case "path": case "node:path": return path;
    case "fs": case "node:fs": return fs;
    case "util": case "node:util": return util;
    case "os": case "node:os": return os;
    case "process": case "node:process": return process;
    case "tty": return { isatty: function(){ return false; } };
    case "crypto": case "node:crypto": return { createHash: function(){ return { update: function(){ return this; }, digest: function(){ return ""; } }; } };
    case "url": case "node:url": return { fileURLToPath: function(u){ return String(u); }, pathToFileURL: function(p){ return { href: "file://" + p }; }, URL: function(u){ this.href = u; } };
    case "perf_hooks": return { performance: { now: function(){ return 0; } } };
    case "module": return { createRequire: function(){ return require; }, builtinModules: [] };
    case "assert": { var a = function(v){ if (!v) throw new Error("assert"); }; a.ok = a; return a; }
    default: return {};
  }
};
