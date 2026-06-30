// node:path — posix semantics (the VFS is posix; path.win32 is intentionally absent).
var path={sep:'/',delimiter:':'};
path.normalize=function(p){p=String(p);var abs=p.charAt(0)==='/';var parts=p.split('/'),out=[];for(var i=0;i<parts.length;i++){var s=parts[i];if(s===''||s==='.')continue;if(s==='..'){if(out.length&&out[out.length-1]!=='..')out.pop();else if(!abs)out.push('..');}else out.push(s);}var r=out.join('/');if(abs)r='/'+r;if(!r)r=abs?'/':'.';if(p.charAt(p.length-1)==='/'&&r.charAt(r.length-1)!=='/')r+='/';return r;};
path.join=function(){var p=Array.prototype.filter.call(arguments,function(x){return x&&typeof x==='string';}).join('/');return p?path.normalize(p):'.';};
path.isAbsolute=function(p){return String(p).charAt(0)==='/';};
path.resolve=function(){var r='';for(var i=arguments.length-1;i>=-1;i--){var s=i>=0?arguments[i]:'/work';if(!s)continue;r=s+'/'+r;if(path.isAbsolute(s))break;}r=path.normalize(r);return r.length>1&&r.charAt(r.length-1)==='/'?r.slice(0,-1):(r||'/');};
path.dirname=function(p){p=String(p);var i=p.lastIndexOf('/');if(i<0)return '.';if(i===0)return '/';return p.slice(0,i);};
path.basename=function(p,e){p=String(p);var i=p.lastIndexOf('/');var b=i<0?p:p.slice(i+1);if(e&&b.length>=e.length&&b.slice(-e.length)===e)b=b.slice(0,-e.length);return b;};
path.extname=function(p){p=path.basename(p);var i=p.lastIndexOf('.');return i<=0?'':p.slice(i);};
path.parse=function(p){var d=path.dirname(p),b=path.basename(p),e=path.extname(p);return {root:path.isAbsolute(p)?'/':'',dir:d,base:b,ext:e,name:e?b.slice(0,-e.length):b};};
path.format=function(o){var d=o.dir||o.root||'';var b=o.base||((o.name||'')+(o.ext||''));return d?(d+(d.charAt(d.length-1)==='/'?'':'/')+b):b;};
path.relative=function(f,t){var a=path.resolve(f).split('/'),b=path.resolve(t).split('/');var i=0;while(i<a.length&&i<b.length&&a[i]===b[i])i++;var up=[];for(var j=i;j<a.length;j++)up.push('..');return up.concat(b.slice(i)).join('/')||'.';};
path.posix=path;
// node always exposes path.win32 even on posix hosts; bundlers (rollup/vite) reference path.win32.sep for
// platform detection. The VFS is posix, so win32 is a thin view with windows separators over the same fns.
path.win32=Object.assign({},path,{sep:'\\',delimiter:';'});
def('path',path);
