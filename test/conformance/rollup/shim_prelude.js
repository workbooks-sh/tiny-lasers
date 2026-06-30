(function(){
  var orig = globalThis.require;
  var extra = {};
  globalThis.require = function(n){
    n = String(n).replace(/^node:/,'');
    if (Object.prototype.hasOwnProperty.call(extra,n)) return extra[n];
    return orig(n);
  };
  globalThis.__addModule = function(n,m){ extra[n]=m; };
  var fs = orig('fs');
  __addModule('fs/promises', {
    readFile:function(p,e){return Promise.resolve(fs.readFileSync(p,e));},
    writeFile:function(p,d,e){return Promise.resolve(fs.writeFileSync(p,d,e));},
    mkdir:function(p,o){try{fs.mkdirSync(p,o);}catch(e){} return Promise.resolve();},
    rmdir:function(p){return Promise.resolve();},
    rm:function(p,o){try{fs.unlinkSync(p);}catch(e){} return Promise.resolve();},
    stat:function(p){return Promise.resolve(fs.statSync(p));},
    lstat:function(p){return Promise.resolve(fs.statSync(p));},
    readdir:function(p){return Promise.resolve(fs.readdirSync(p));},
    access:function(p){return fs.existsSync(p)?Promise.resolve():Promise.reject(Object.assign(new Error('ENOENT'),{code:'ENOENT'}));},
    realpath:function(p){return Promise.resolve(p);},
    unlink:function(p){try{fs.unlinkSync(p);}catch(e){} return Promise.resolve();},
  });
  var path = orig('path');
  if(!path.win32){ path.win32 = Object.assign({}, path, {sep:'\\', delimiter:';'}); }
  var proc = globalThis.process;
  ['on','once','off','removeListener','addListener','prependListener'].forEach(function(m){ if(typeof proc[m]!=='function') proc[m]=function(){return proc;}; });
  if(typeof proc.emit!=='function') proc.emit=function(){return false;};
})();
