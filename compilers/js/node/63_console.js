// console augmentation — adds the rich console methods on top of the host-backed
// global console.log/console.error (wb-8mdz.1). NO def() — console is a global. This file
// only AUGMENTS globalThis.console; it never replaces log/error (those are host-backed).
// Loads after 59_perf_hooks.js so console.time can use performance.now().
(function(){
  var C = globalThis.console;
  if(!C) return;
  var __log = (typeof C.log === 'function') ? C.log.bind(C) : function(){};
  var __err = (typeof C.error === 'function') ? C.error.bind(C) : __log;

  function __c_str(a){
    try {
      if(typeof a === 'string') return a;
      if(a instanceof Error) return (a.stack || (a.name+': '+a.message));
      if(typeof a === 'object' && a !== null){
        try { return JSON.stringify(a); } catch(e){ return String(a); }
      }
      return String(a);
    } catch(e){ return ''; }
  }
  function __c_fmt(args){
    var out = [];
    for(var i=0;i<args.length;i++) out.push(__c_str(args[i]));
    return out.join(' ');
  }
  function __c_now(){
    try {
      if(globalThis.performance && typeof globalThis.performance.now === 'function') return globalThis.performance.now();
    } catch(e){}
    try { var d = Date.now(); if(typeof d==='number'&&!isNaN(d)) return d; } catch(e){}
    return 0;
  }

  var __c_indent = '';
  function __c_emit(fn, args){
    try { fn(__c_indent + __c_fmt(args)); } catch(e){}
  }

  if(typeof C.info !== 'function') C.info = function(){ __c_emit(__log, arguments); };
  if(typeof C.warn !== 'function') C.warn = function(){ __c_emit(__err, arguments); };
  if(typeof C.debug !== 'function') C.debug = function(){ __c_emit(__log, arguments); };
  C.dir = function(obj){ __c_emit(__log, [obj]); };
  C.trace = function(){
    var msg = 'Trace';
    if(arguments.length) msg += ': ' + __c_fmt(arguments);
    try { var e = new Error(); __log(__c_indent + msg + (e.stack ? '\n'+e.stack : '')); }
    catch(x){ try{ __log(__c_indent + msg); }catch(y){} }
  };
  C.assert = function(cond){
    if(cond) return;
    var rest = Array.prototype.slice.call(arguments, 1);
    var m = rest.length ? __c_fmt(rest) : '';
    try { __err(__c_indent + 'Assertion failed' + (m ? ': ' + m : '')); } catch(e){}
  };

  var __c_counts = {};
  C.count = function(label){
    label = (label==null) ? 'default' : String(label);
    __c_counts[label] = (__c_counts[label] || 0) + 1;
    try { __log(__c_indent + label + ': ' + __c_counts[label]); } catch(e){}
  };
  C.countReset = function(label){
    label = (label==null) ? 'default' : String(label);
    __c_counts[label] = 0;
  };

  C.group = function(){ if(arguments.length) __c_emit(__log, arguments); __c_indent += '  '; };
  C.groupCollapsed = C.group;
  C.groupEnd = function(){ __c_indent = __c_indent.slice(0, -2); };

  var __c_timers = {};
  C.time = function(label){ label = (label==null) ? 'default' : String(label); __c_timers[label] = __c_now(); };
  C.timeEnd = function(label){
    label = (label==null) ? 'default' : String(label);
    if(!(label in __c_timers)) return;
    var dur = __c_now() - __c_timers[label]; delete __c_timers[label];
    try { __log(__c_indent + label + ': ' + dur + 'ms'); } catch(e){}
  };
  C.timeLog = function(label){
    label = (label==null) ? 'default' : String(label);
    if(!(label in __c_timers)) return;
    var dur = __c_now() - __c_timers[label];
    var rest = Array.prototype.slice.call(arguments, 1);
    var extra = rest.length ? ' ' + __c_fmt(rest) : '';
    try { __log(__c_indent + label + ': ' + dur + 'ms' + extra); } catch(e){}
  };

  C.table = function(data){
    try {
      if(data == null || typeof data !== 'object'){ __c_emit(__log, [data]); return; }
      var rows = [];          // array of {key, values:{col:val}}
      var cols = [];          // ordered column names
      function addCol(c){ if(cols.indexOf(c) < 0) cols.push(c); }
      var indexKeys = Array.isArray(data) ? data.map(function(_,i){ return String(i); }) : Object.keys(data);
      var hasValuesCol = false;
      for(var i=0;i<indexKeys.length;i++){
        var k = indexKeys[i];
        var v = data[k];
        var rec = { key: k, values: {} };
        if(v !== null && typeof v === 'object' && !(v instanceof Error)){
          var sub = Array.isArray(v) ? v.map(function(_,j){ return String(j); }) : Object.keys(v);
          for(var j=0;j<sub.length;j++){ addCol(sub[j]); rec.values[sub[j]] = __c_str(v[sub[j]]); }
        } else {
          hasValuesCol = true; rec.values['Values'] = __c_str(v);
        }
        rows.push(rec);
      }
      if(hasValuesCol) addCol('Values');
      var header = ['(index)'].concat(cols);
      var widths = header.map(function(h){ return h.length; });
      var lines = [];
      for(var r=0;r<rows.length;r++){
        var line = [rows[r].key];
        for(var c=0;c<cols.length;c++){
          var cell = (cols[c] in rows[r].values) ? rows[r].values[cols[c]] : '';
          line.push(cell);
        }
        for(var w=0;w<line.length;w++){ if(line[w].length > widths[w]) widths[w] = line[w].length; }
        lines.push(line);
      }
      function pad(s, n){ s = String(s); while(s.length < n) s += ' '; return s; }
      function fmtRow(arr){ return arr.map(function(s,idx){ return pad(s, widths[idx]); }).join(' | '); }
      var out = [fmtRow(header)];
      out.push(widths.map(function(w){ var d=''; while(d.length<w) d+='-'; return d; }).join('-+-'));
      for(var L=0;L<lines.length;L++) out.push(fmtRow(lines[L]));
      __log(__c_indent + out.join('\n' + __c_indent));
    } catch(e){
      try { __c_emit(__log, [data]); } catch(x){}
    }
  };
})();
