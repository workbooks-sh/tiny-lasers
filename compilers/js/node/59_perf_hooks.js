// node:perf_hooks — pure-JS performance timing (wb-8mdz.1). No host calls.
// Sets globalThis.performance and registers def('perf_hooks',...). High-res-ish ms via Date.now()
// anchored at load; falls back to a monotonic per-call counter if Date.now() is unavailable/NaN.
var __perf_start = (function(){ var d = (typeof Date!=='undefined'&&Date.now)?Date.now():NaN; return (typeof d==='number'&&!isNaN(d))?d:null; })();
var __perf_counter = 0;
function __perf_now(){
  if(__perf_start!==null){ var d=Date.now(); if(typeof d==='number'&&!isNaN(d))return d-__perf_start; }
  return ++__perf_counter;
}
var __perf_entries = [];
function __perf_addEntry(e){ __perf_entries.push(e); return e; }

var __perf_timeOrigin = (__perf_start!==null)?__perf_start:0;

function PerformanceObserver(cb){ this.__cb = (typeof cb==='function')?cb:function(){}; }
PerformanceObserver.prototype.observe=function(opts){ this.__opts=opts||{}; return undefined; };
PerformanceObserver.prototype.disconnect=function(){ return undefined; };
PerformanceObserver.prototype.takeRecords=function(){ return []; };

var __perf_performance = {
  now: __perf_now,
  timeOrigin: __perf_timeOrigin,
  mark: function(name){
    var e = { name: String(name), entryType: 'mark', startTime: __perf_now(), duration: 0 };
    return __perf_addEntry(e);
  },
  measure: function(name, startMark, endMark){
    var start = 0, end = __perf_now();
    function lookup(m){ for(var i=__perf_entries.length-1;i>=0;i--){ if(__perf_entries[i].name===m&&__perf_entries[i].entryType==='mark')return __perf_entries[i].startTime; } return null; }
    if(startMark!=null){ var s=lookup(String(startMark)); if(s!=null)start=s; }
    if(endMark!=null){ var en=lookup(String(endMark)); if(en!=null)end=en; }
    var e = { name: String(name), entryType: 'measure', startTime: start, duration: end-start };
    return __perf_addEntry(e);
  },
  getEntries: function(){ return __perf_entries.slice(); },
  getEntriesByName: function(name, type){
    name=String(name);
    return __perf_entries.filter(function(e){ return e.name===name && (type==null||e.entryType===type); });
  },
  getEntriesByType: function(type){
    type=String(type);
    return __perf_entries.filter(function(e){ return e.entryType===type; });
  },
  clearMarks: function(name){
    if(name==null){ __perf_entries=__perf_entries.filter(function(e){ return e.entryType!=='mark'; }); }
    else { name=String(name); __perf_entries=__perf_entries.filter(function(e){ return !(e.entryType==='mark'&&e.name===name); }); }
  },
  clearMeasures: function(name){
    if(name==null){ __perf_entries=__perf_entries.filter(function(e){ return e.entryType!=='measure'; }); }
    else { name=String(name); __perf_entries=__perf_entries.filter(function(e){ return !(e.entryType==='measure'&&e.name===name); }); }
  }
};

globalThis.performance = __perf_performance;
globalThis.PerformanceObserver = PerformanceObserver;

def('perf_hooks', {
  performance: __perf_performance,
  PerformanceObserver: PerformanceObserver,
  constants: {}
});
