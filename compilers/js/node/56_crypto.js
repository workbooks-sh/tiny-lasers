// node:crypto — pure-JS shim over the generic host bridge (__host) → Nexus.Washy.HostCrypto → Erlang :crypto.
// Mirrors node/55_fs.js: no harness/washy edits, just this file + lib/washy/host_crypto.ex. Binary crosses the
// bridge base64-encoded (JSON-safe). All ops are sync CPU round-trips; callback forms defer to a microtask.
function __cbuf(data,enc){return Buffer.isBuffer(data)?data:Buffer.from(String(data),(typeof enc==='string'?enc:'utf8'));}
function __cenc(buf,enc){if(!enc||enc==='buffer')return buf;return buf.toString(enc==='base64'?'base64':enc==='hex'?'hex':enc);}
function Hash(algo){this._algo=algo;this._chunks=[];}
Hash.prototype.update=function(data,enc){this._chunks.push(__cbuf(data,enc));return this;};
Hash.prototype.digest=function(enc){var all=Buffer.concat(this._chunks);var r=__host('crypto_hash',[this._algo,all.toString('base64')]);if(r.err)throw new Error(r.err);return __cenc(Buffer.from(r.digest,'base64'),enc);};
function createHash(algo){return new Hash(algo);}
function Hmac(algo,key){this._algo=algo;this._key=__cbuf(key);this._chunks=[];}
Hmac.prototype.update=function(data,enc){this._chunks.push(__cbuf(data,enc));return this;};
Hmac.prototype.digest=function(enc){var all=Buffer.concat(this._chunks);var r=__host('crypto_hmac',[this._algo,this._key.toString('base64'),all.toString('base64')]);if(r.err)throw new Error(r.err);return __cenc(Buffer.from(r.digest,'base64'),enc);};
function createHmac(algo,key){return new Hmac(algo,key);}
function randomBytes(n,cb){var r=__host('crypto_random',[n]);var buf=Buffer.from(r.b64,'base64');if(typeof cb==='function'){queueMicrotask(function(){cb(null,buf);});return;}return buf;}
function randomUUID(){return __host('crypto_uuid',[]).uuid;}
def('crypto',{createHash:createHash,createHmac:createHmac,randomBytes:randomBytes,randomUUID:randomUUID,Hash:Hash,Hmac:Hmac});
