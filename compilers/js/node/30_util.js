// node:util — inspect/format/inherits/promisify + a minimal types table.
function inspect(v){try{if(typeof v==='string')return v;if(typeof v==='function')return '[Function]';return JSON.stringify(v);}catch(e){return String(v);}}
function inherits(c,s){c.super_=s;c.prototype=Object.create(s.prototype,{constructor:{value:c,enumerable:false}});}
function format(f){var a=arguments,i=1;if(typeof f!=='string'){var o=[];for(var k=0;k<a.length;k++)o.push(inspect(a[k]));return o.join(' ');}
var s=String(f).replace(/%[sdjifoO%]/g,function(m){if(m==='%%')return '%';if(i>=a.length)return m;var v=a[i++];if(m==='%d'||m==='%i')return String(parseInt(v));if(m==='%f')return String(parseFloat(v));if(m==='%j')return JSON.stringify(v);if(m==='%s')return String(v);return inspect(v);});
for(;i<a.length;i++)s+=' '+inspect(a[i]);return s;}
function promisify(fn){return function(){var a=Array.prototype.slice.call(arguments),s=this;return new Promise(function(res,rej){a.push(function(e,r){if(e)rej(e);else res(r);});fn.apply(s,a);});};}
def('util',{inherits:inherits,format:format,inspect:inspect,promisify:promisify,deprecate:function(f){return f;},debuglog:function(){return function(){};},
types:{isDate:function(x){return x instanceof Date;},isRegExp:function(x){return x instanceof RegExp;},isNativeError:function(x){return x instanceof Error;}},
isArray:Array.isArray,isBuffer:function(x){return globalThis.Buffer&&Buffer.isBuffer(x);},TextEncoder:globalThis.TextEncoder,TextDecoder:globalThis.TextDecoder});
