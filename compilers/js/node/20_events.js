// node:events — EventEmitter (require('events') returns the constructor; .EventEmitter also set).
function EventEmitter(){this._ev={};}
EventEmitter.prototype.on=function(t,f){(this._ev[t]=this._ev[t]||[]).push(f);return this;};
EventEmitter.prototype.addListener=EventEmitter.prototype.on;
EventEmitter.prototype.prependListener=function(t,f){(this._ev[t]=this._ev[t]||[]).unshift(f);return this;};
EventEmitter.prototype.once=function(t,f){var s=this;function g(){s.removeListener(t,g);return f.apply(this,arguments);}g.listener=f;return s.on(t,g);};
EventEmitter.prototype.removeListener=function(t,f){var a=this._ev[t];if(a){var i=a.indexOf(f);if(i<0){for(i=0;i<a.length;i++){if(a[i].listener===f)break;}}if(i>-1&&i<a.length)a.splice(i,1);}return this;};
EventEmitter.prototype.off=EventEmitter.prototype.removeListener;
EventEmitter.prototype.removeAllListeners=function(t){if(t)delete this._ev[t];else this._ev={};return this;};
EventEmitter.prototype.emit=function(t){var a=this._ev[t];if(!a||!a.length){if(t==='error')throw arguments[1];return false;}var ar=Array.prototype.slice.call(arguments,1);a.slice().forEach(function(f){f.apply(this,ar);},this);return true;};
EventEmitter.prototype.listeners=function(t){return (this._ev[t]||[]).slice();};
EventEmitter.prototype.listenerCount=function(t){return (this._ev[t]||[]).length;};
EventEmitter.prototype.setMaxListeners=function(){return this;};
EventEmitter.defaultMaxListeners=10;
EventEmitter.once=function(em,t){return new Promise(function(r){em.once(t,function(){r(Array.prototype.slice.call(arguments));});});};
def('events',EventEmitter);M['events'].EventEmitter=EventEmitter;
