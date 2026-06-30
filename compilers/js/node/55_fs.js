// node:fs — pure-JS shim over the generic host bridge (__host) → Nexus.Washy.HostFs → Nexus.Washy.VFS.
// The REFERENCE Wave-1 module: no harness/washy edits, just this file + lib/washy/host_fs.ex. Bytes cross
// the bridge base64-encoded (binary-safe). VFS is synchronous, so the *Sync ops are direct round-trips and
// the async/promise forms are the sync result deferred to a microtask (honest: there's no slow device here).
function __fsnorm(p){return String(p).replace(/^\/work\//,'').replace(/^\/work$/,'').replace(/^\.\//,'').replace(/^\//,'');}
function readFileSync(path,enc){var r=__host('fs_read',[__fsnorm(path)]);if(!r.ok){var e=new Error('ENOENT: no such file, open \''+path+'\'');e.code='ENOENT';throw e;}var buf=Buffer.from(r.b64,'base64');if(typeof enc==='object'&&enc)enc=enc.encoding;return enc?buf.toString(enc):buf;}
function writeFileSync(path,data,enc){var buf=Buffer.isBuffer(data)?data:Buffer.from(String(data),(typeof enc==='string'?enc:'utf8'));var r=__host('fs_write',[__fsnorm(path),buf.toString('base64')]);if(!r.ok){var e=new Error('EIO: write failed');e.code='EIO';throw e;}}
function existsSync(path){return !!__host('fs_exists',[__fsnorm(path)]).ok;}
function unlinkSync(path){__host('fs_unlink',[__fsnorm(path)]);}
function mkdirSync(path){__host('fs_mkdir',[__fsnorm(path)]);}
function readdirSync(path){var r=__host('fs_list',[__fsnorm(path)]);return r.entries||[];}
function appendFileSync(path,data){var cur='';try{cur=readFileSync(path,'utf8');}catch(e){}writeFileSync(path,cur+String(data));}
function Stats(s){this.size=s.size;this._f=s.isFile;this._d=s.isDirectory;}
Stats.prototype.isFile=function(){return !!this._f;};Stats.prototype.isDirectory=function(){return !!this._d;};
function statSync(path){var r=__host('fs_stat',[__fsnorm(path)]);if(!r.ok){var e=new Error('ENOENT');e.code='ENOENT';throw e;}return new Stats(r);}
// callback forms: defer the sync result to a microtask so call order matches Node (err-first callbacks).
function __cb(fn,thunk){queueMicrotask(function(){var r,err=null;try{r=thunk();}catch(e){err=e;}fn(err,r);});}
function readFile(path,enc,cb){if(typeof enc==='function'){cb=enc;enc=undefined;}__cb(cb,function(){return readFileSync(path,enc);});}
function writeFile(path,data,enc,cb){if(typeof enc==='function'){cb=enc;enc=undefined;}__cb(cb,function(){writeFileSync(path,data,enc);});}
var promises={
  readFile:function(p,e){return new Promise(function(res,rej){try{res(readFileSync(p,e));}catch(x){rej(x);}});},
  writeFile:function(p,d,e){return new Promise(function(res,rej){try{writeFileSync(p,d,e);res();}catch(x){rej(x);}});},
  readdir:function(p){return Promise.resolve(readdirSync(p));},
  stat:function(p){return new Promise(function(res,rej){try{res(statSync(p));}catch(x){rej(x);}});},
  unlink:function(p){unlinkSync(p);return Promise.resolve();},
  mkdir:function(p){mkdirSync(p);return Promise.resolve();}
};
def('fs',{readFileSync:readFileSync,writeFileSync:writeFileSync,existsSync:existsSync,unlinkSync:unlinkSync,
mkdirSync:mkdirSync,readdirSync:readdirSync,appendFileSync:appendFileSync,statSync:statSync,
readFile:readFile,writeFile:writeFile,Stats:Stats,promises:promises,constants:{}});
def('fs/promises',promises);
