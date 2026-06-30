// node:buffer — Buffer as a Uint8Array subclass (also exposed as the Buffer global, Node-style).
var B64='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
function b64enc(u){var r='',i;for(i=0;i+2<u.length;i+=3){var n=(u[i]<<16)|(u[i+1]<<8)|u[i+2];r+=B64[n>>18&63]+B64[n>>12&63]+B64[n>>6&63]+B64[n&63];}var rem=u.length-i;if(rem===1){var n=u[i]<<16;r+=B64[n>>18&63]+B64[n>>12&63]+'==';}else if(rem===2){var n=(u[i]<<16)|(u[i+1]<<8);r+=B64[n>>18&63]+B64[n>>12&63]+B64[n>>6&63]+'=';}return r;}
function b64dec(s){s=String(s).replace(/[^A-Za-z0-9+\/]/g,'');var out=[],i;for(i=0;i+3<s.length;i+=4){var n=(B64.indexOf(s[i])<<18)|(B64.indexOf(s[i+1])<<12)|(B64.indexOf(s[i+2])<<6)|B64.indexOf(s[i+3]);out.push(n>>16&255,n>>8&255,n&255);}var rem=s.length-i;if(rem===2){var n=(B64.indexOf(s[i])<<18)|(B64.indexOf(s[i+1])<<12);out.push(n>>16&255);}else if(rem===3){var n=(B64.indexOf(s[i])<<18)|(B64.indexOf(s[i+1])<<12)|(B64.indexOf(s[i+2])<<6);out.push(n>>16&255,n>>8&255);}return out;}
function strToBytes(s,e){e=e||'utf8';s=String(s);if(e==='hex'){var a=[];for(var i=0;i<s.length;i+=2)a.push(parseInt(s.substr(i,2),16));return a;}if(e==='base64')return b64dec(s);if(e==='latin1'||e==='binary'||e==='ascii'){var a=[];for(var i=0;i<s.length;i++)a.push(s.charCodeAt(i)&255);return a;}return Array.prototype.slice.call(new TextEncoder().encode(s));}
class NodeBuffer extends Uint8Array{
toString(enc,start,end){enc=enc||'utf8';var u=this.subarray(start||0,end===undefined?this.length:end);
if(enc==='hex'){var s='';for(var i=0;i<u.length;i++)s+=(u[i]<16?'0':'')+u[i].toString(16);return s;}
if(enc==='base64')return b64enc(u);
if(enc==='latin1'||enc==='binary'||enc==='ascii'){var s='';for(var i=0;i<u.length;i++)s+=String.fromCharCode(enc==='ascii'?u[i]&127:u[i]);return s;}
return new TextDecoder().decode(u);}
slice(s,e){return new NodeBuffer(this.subarray(s,e));}
equals(o){if(this.length!==o.length)return false;for(var i=0;i<this.length;i++)if(this[i]!==o[i])return false;return true;}
write(str,off,len,enc){if(typeof off==='string'){enc=off;off=0;}off=off||0;var b=strToBytes(str,enc||'utf8');var n=0;for(var i=0;i<b.length&&off+i<this.length;i++){this[off+i]=b[i];n++;}return n;}
toJSON(){return {type:'Buffer',data:Array.prototype.slice.call(this)};}}
function Buffer(a,e){return Buffer.from(a,e);}
Buffer.from=function(a,e){if(typeof a==='string'){var b=strToBytes(a,e);var buf=new NodeBuffer(b.length);buf.set(b);return buf;}if(a instanceof Uint8Array||Array.isArray(a)){var buf=new NodeBuffer(a.length);buf.set(a);return buf;}if(a&&a.buffer){var u=new Uint8Array(a.buffer,a.byteOffset||0,a.byteLength);var buf=new NodeBuffer(u.length);buf.set(u);return buf;}return new NodeBuffer(0);};
Buffer.alloc=function(n,fill){var b=new NodeBuffer(n);if(fill!==undefined&&fill!==0){if(typeof fill==='number')b.fill(fill);else{var f=strToBytes(String(fill));for(var i=0;i<n;i++)b[i]=f[i%f.length];}}return b;};
Buffer.allocUnsafe=function(n){return new NodeBuffer(n);};
Buffer.isBuffer=function(b){return b instanceof NodeBuffer;};
Buffer.byteLength=function(s,e){return (s instanceof Uint8Array)?s.length:strToBytes(s,e).length;};
Buffer.concat=function(list,tot){var len=0;list.forEach(function(b){len+=b.length;});if(tot===undefined)tot=len;var out=new NodeBuffer(tot),off=0;list.forEach(function(b){if(off>=tot)return;out.set(b.subarray(0,tot-off),off);off+=b.length;});return out;};
Buffer.isEncoding=function(e){return ['utf8','utf-8','hex','base64','latin1','binary','ascii'].indexOf(String(e).toLowerCase())>-1;};
globalThis.Buffer=Buffer;
def('buffer',{Buffer:Buffer,kMaxLength:0x7fffffff});
