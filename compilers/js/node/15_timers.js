// node:timers + the global timer functions — the first consumer of the async spine (wb-5q8w).
// setTimeout/setInterval/setImmediate arm a BEAM timer via the __host_timer_set host import; when it
// fires, the host re-enters the guest through the wb_timer export, which calls __wb_fire_timer(id) here
// (run-to-completion, then the pending-job loop drains promise microtasks). queueMicrotask/nextTick are
// pure promise microtasks (no host timer). Timers require the persistent-actor context (a live mailbox).
var __timers={},__tid=1;
function setTimeout(fn,ms){var id=__tid++;__timers[id]={fn:fn,args:Array.prototype.slice.call(arguments,2),repeat:false};__host_timer_set(id,(ms|0)<0?0:(ms|0));return id;}
function setInterval(fn,ms){var id=__tid++;ms=(ms|0)<0?0:(ms|0);__timers[id]={fn:fn,args:Array.prototype.slice.call(arguments,2),repeat:true,ms:ms};__host_timer_set(id,ms);return id;}
function clearTimeout(id){if(id&&__timers[id]){delete __timers[id];__host_timer_clear(id);}}
function clearInterval(id){clearTimeout(id);}
function setImmediate(fn){var id=__tid++;__timers[id]={fn:fn,args:Array.prototype.slice.call(arguments,1),repeat:false};__host_timer_set(id,0);return id;}
function clearImmediate(id){clearTimeout(id);}
globalThis.setTimeout=setTimeout;globalThis.setInterval=setInterval;globalThis.clearTimeout=clearTimeout;globalThis.clearInterval=clearInterval;
globalThis.setImmediate=setImmediate;globalThis.clearImmediate=clearImmediate;
if(!globalThis.queueMicrotask)globalThis.queueMicrotask=function(fn){Promise.resolve().then(fn);};
globalThis.__wb_fire_timer=function(id){var t=__timers[id];if(!t)return;if(t.repeat){__host_timer_set(id,t.ms);}else{delete __timers[id];}t.fn.apply(null,t.args);};
def('timers',{setTimeout:setTimeout,setInterval:setInterval,clearTimeout:clearTimeout,clearInterval:clearInterval,setImmediate:setImmediate,clearImmediate:clearImmediate});
def('timers/promises',{setTimeout:function(ms,val){return new Promise(function(res){setTimeout(function(){res(val);},ms);});}});
