// node:url — the WHATWG URL/URLSearchParams classes (also set as globals) + the legacy parse/format/resolve API.
// Pure JS, dependency-free. Lives inside the shared IIFE, so helpers are prefixed __url_ to avoid clashes.
var __url_special={'http:':80,'https:':443,'ws:':80,'wss:':443,'ftp:':21,'file:':null};
function __url_isSpecial(p){return Object.prototype.hasOwnProperty.call(__url_special,p);}

function __url_parseQuery(s){var o=[];if(s.charAt(0)==='?')s=s.slice(1);if(!s)return o;s.split('&').forEach(function(p){var i=p.indexOf('=');var k=i<0?p:p.slice(0,i),v=i<0?'':p.slice(i+1);o.push([__url_decode(k),__url_decode(v)]);});return o;}
function __url_decode(s){try{return decodeURIComponent(String(s).replace(/\+/g,' '));}catch(e){return String(s);}}
function __url_encode(s){return encodeURIComponent(String(s)).replace(/%20/g,'+');}
function __url_stringifyQuery(pairs){return pairs.map(function(p){return __url_encode(p[0])+'='+__url_encode(p[1]);}).join('&');}

class URLSearchParams{
  constructor(init){
    this.__list=[];
    this.__url=null;
    if(init===undefined||init===null||init==='')return;
    if(typeof init==='string'){this.__list=__url_parseQuery(init);return;}
    if(init instanceof URLSearchParams){this.__list=init.__list.map(function(p){return [p[0],p[1]];});return;}
    if(Array.isArray(init)){for(var i=0;i<init.length;i++){this.__list.push([String(init[i][0]),String(init[i][1])]);}return;}
    if(typeof init==='object'){var self=this;Object.keys(init).forEach(function(k){self.__list.push([String(k),String(init[k])]);});return;}
  }
  __sync(){if(this.__url)this.__url.__updateSearch(this.toString());}
  append(k,v){this.__list.push([String(k),String(v)]);this.__sync();}
  delete(k){k=String(k);this.__list=this.__list.filter(function(p){return p[0]!==k;});this.__sync();}
  get(k){k=String(k);for(var i=0;i<this.__list.length;i++)if(this.__list[i][0]===k)return this.__list[i][1];return null;}
  getAll(k){k=String(k);var r=[];for(var i=0;i<this.__list.length;i++)if(this.__list[i][0]===k)r.push(this.__list[i][1]);return r;}
  has(k){k=String(k);for(var i=0;i<this.__list.length;i++)if(this.__list[i][0]===k)return true;return false;}
  set(k,v){k=String(k);v=String(v);var found=false;var out=[];for(var i=0;i<this.__list.length;i++){if(this.__list[i][0]===k){if(!found){out.push([k,v]);found=true;}}else out.push(this.__list[i]);}if(!found)out.push([k,v]);this.__list=out;this.__sync();}
  sort(){this.__list.sort(function(a,b){return a[0]<b[0]?-1:a[0]>b[0]?1:0;});this.__sync();}
  forEach(cb,thisArg){for(var i=0;i<this.__list.length;i++)cb.call(thisArg,this.__list[i][1],this.__list[i][0],this);}
  keys(){return this.__list.map(function(p){return p[0];})[Symbol.iterator]();}
  values(){return this.__list.map(function(p){return p[1];})[Symbol.iterator]();}
  entries(){return this.__list.map(function(p){return [p[0],p[1]];})[Symbol.iterator]();}
  [Symbol.iterator](){return this.entries();}
  get size(){return this.__list.length;}
  toString(){return __url_stringifyQuery(this.__list);}
}

function __url_parse(input,base){
  input=String(input).trim();
  var rec={protocol:'',username:'',password:'',hostname:'',port:'',pathname:'',search:'',hash:'',slashes:false};
  var hashIdx=input.indexOf('#');
  if(hashIdx>=0){rec.hash=input.slice(hashIdx);input=input.slice(0,hashIdx);}
  var qIdx=input.indexOf('?');
  if(qIdx>=0){rec.search=input.slice(qIdx);input=input.slice(0,qIdx);}
  var m=input.match(/^([a-zA-Z][a-zA-Z0-9+.\-]*):/);
  var rest=input;
  if(m){rec.protocol=m[1].toLowerCase()+':';rest=input.slice(m[0].length);}
  if(!m&&base){
    var b=base instanceof URL?base:new URL(String(base));
    rec.protocol=b.protocol;rec.username=b.__username;rec.password=b.__password;
    rec.hostname=b.hostname;rec.port=b.port;rec.slashes=true;
    if(rest.charAt(0)==='/'){rec.pathname=__url_normalizePath(rest);}
    else if(rest===''){rec.pathname=b.pathname;if(!rec.search)rec.search=b.search;}
    else{var dir=b.pathname.slice(0,b.pathname.lastIndexOf('/')+1);rec.pathname=__url_normalizePath(dir+rest);}
    return rec;
  }
  if(rest.slice(0,2)==='//'){
    rec.slashes=true;rest=rest.slice(2);
    var slash=rest.search(/[\/?#]/);
    var auth=slash<0?rest:rest.slice(0,slash);
    rest=slash<0?'':rest.slice(slash);
    var at=auth.lastIndexOf('@');
    if(at>=0){var cred=auth.slice(0,at);auth=auth.slice(at+1);var ci=cred.indexOf(':');if(ci<0){rec.username=cred;}else{rec.username=cred.slice(0,ci);rec.password=cred.slice(ci+1);}}
    var host=auth;
    if(host.charAt(0)==='['){var rb=host.indexOf(']');rec.hostname=host.slice(0,rb+1).toLowerCase();var after=host.slice(rb+1);if(after.charAt(0)===':')rec.port=after.slice(1);}
    else{var ci2=host.indexOf(':');if(ci2<0){rec.hostname=host.toLowerCase();}else{rec.hostname=host.slice(0,ci2).toLowerCase();rec.port=host.slice(ci2+1);}}
    if(rec.port!==''&&__url_isSpecial(rec.protocol)&&String(__url_special[rec.protocol])===rec.port)rec.port='';
  }else if(__url_isSpecial(rec.protocol)){
    rec.slashes=true;
  }
  rec.pathname=__url_normalizePath(rest);
  if(__url_isSpecial(rec.protocol)&&rec.pathname===''&&rec.hostname!=='')rec.pathname='/';
  return rec;
}
function __url_normalizePath(p){
  if(p===''||p===undefined)return '';
  if(p.charAt(0)!=='/'&&p!=='')return p;
  var parts=p.split('/'),out=[];for(var i=0;i<parts.length;i++){var s=parts[i];if(s==='.')continue;if(s==='..'){if(out.length>1)out.pop();continue;}out.push(s);}
  return out.join('/')||'/';
}

class URL{
  constructor(input,base){
    var rec=__url_parse(input,base);
    if(!rec.protocol)throw new TypeError("Invalid URL: "+input);
    this.__protocol=rec.protocol;
    this.__username=rec.username;
    this.__password=rec.password;
    this.__hostname=rec.hostname;
    this.__port=rec.port;
    this.__pathname=rec.pathname||(__url_isSpecial(rec.protocol)?'/':'');
    this.__search=rec.search;
    this.__hash=rec.hash;
    this.__sp=new URLSearchParams(rec.search);
    this.__sp.__url=this;
  }
  get protocol(){return this.__protocol;}
  set protocol(v){v=String(v);if(v.charAt(v.length-1)!==':')v+=':';this.__protocol=v.toLowerCase();}
  get username(){return this.__username;}
  set username(v){this.__username=String(v);}
  get password(){return this.__password;}
  set password(v){this.__password=String(v);}
  get hostname(){return this.__hostname;}
  set hostname(v){this.__hostname=String(v).toLowerCase();}
  get port(){return this.__port;}
  set port(v){this.__port=v===''?'':String(parseInt(v,10));}
  get host(){return this.__hostname+(this.__port?':'+this.__port:'');}
  set host(v){v=String(v);var i=v.indexOf(':');if(i<0){this.__hostname=v.toLowerCase();this.__port='';}else{this.__hostname=v.slice(0,i).toLowerCase();this.__port=v.slice(i+1);}}
  get pathname(){return this.__pathname;}
  set pathname(v){v=String(v);if(v.charAt(0)!=='/'&&__url_isSpecial(this.__protocol))v='/'+v;this.__pathname=v;}
  get search(){return this.__search;}
  set search(v){v=String(v);if(v&&v.charAt(0)!=='?')v='?'+v;this.__search=v;this.__sp.__list=__url_parseQuery(v);}
  __updateSearch(qs){this.__search=qs?'?'+qs:'';}
  get hash(){return this.__hash;}
  set hash(v){v=String(v);if(v&&v.charAt(0)!=='#')v='#'+v;this.__hash=v;}
  get searchParams(){return this.__sp;}
  get origin(){
    if(__url_isSpecial(this.__protocol)&&this.__protocol!=='file:'&&this.__hostname)return this.__protocol+'//'+this.host;
    return 'null';
  }
  get href(){
    var s=this.__protocol;
    if(this.__hostname||this.__protocol==='file:'||__url_isSpecial(this.__protocol)){
      s+='//';
      if(this.__username){s+=this.__username;if(this.__password)s+=':'+this.__password;s+='@';}
      s+=this.host;
    }
    s+=this.__pathname;
    var qs=this.__sp.toString();
    if(qs)s+='?'+qs;else if(this.__search)s+=this.__search;
    s+=this.__hash;
    return s;
  }
  set href(v){var rec=__url_parse(String(v));this.__protocol=rec.protocol;this.__username=rec.username;this.__password=rec.password;this.__hostname=rec.hostname;this.__port=rec.port;this.__pathname=rec.pathname;this.__search=rec.search;this.__hash=rec.hash;this.__sp.__list=__url_parseQuery(rec.search);}
  toString(){return this.href;}
  toJSON(){return this.href;}
}

globalThis.URL=URL;
globalThis.URLSearchParams=URLSearchParams;

// ---- legacy node:url API ----
function __url_legacyParse(str,parseQueryString){
  var rec=__url_parse(String(str));
  var search=rec.search;
  var out={
    protocol:rec.protocol||null,
    slashes:rec.slashes||null,
    auth:rec.username?(rec.username+(rec.password?':'+rec.password:'')):null,
    host:rec.hostname?(rec.hostname+(rec.port?':'+rec.port:'')):null,
    port:rec.port||null,
    hostname:rec.hostname||null,
    hash:rec.hash||null,
    search:search||null,
    query:parseQueryString?__url_legacyQueryObj(search):(search?search.slice(1):null),
    pathname:rec.pathname||null,
    path:null,
    href:''
  };
  out.path=(out.pathname||'')+(search||'')||null;
  var href='';
  if(out.protocol)href+=out.protocol;
  if(rec.slashes||rec.hostname)href+='//';
  if(out.auth)href+=out.auth+'@';
  if(out.host)href+=out.host;
  if(out.pathname)href+=out.pathname;
  if(search)href+=search;
  if(out.hash)href+=out.hash;
  out.href=href;
  return out;
}
function __url_legacyQueryObj(search){var o={};__url_parseQuery(search||'').forEach(function(p){if(Object.prototype.hasOwnProperty.call(o,p[0])){if(Array.isArray(o[p[0]]))o[p[0]].push(p[1]);else o[p[0]]=[o[p[0]],p[1]];}else o[p[0]]=p[1];});return o;}
function __url_format(obj){
  if(typeof obj==='string')return obj;
  if(obj instanceof URL)return obj.href;
  var s='';
  var proto=obj.protocol||'';
  if(proto&&proto.charAt(proto.length-1)!==':')proto+=':';
  if(proto)s+=proto;
  var host=obj.host;
  if(host===undefined||host===null){host=(obj.hostname||'');if(obj.port)host+=':'+obj.port;}
  if(obj.slashes||host||(proto&&__url_isSpecial(proto)))s+='//';
  if(obj.auth)s+=obj.auth+'@';
  if(host)s+=host;
  var pathname=obj.pathname||'';
  if(pathname&&pathname.charAt(0)!=='/'&&host)pathname='/'+pathname;
  s+=pathname;
  var search=obj.search||'';
  if(!search&&obj.query){search='?'+(typeof obj.query==='string'?obj.query:__url_stringifyQuery(__url_objToPairs(obj.query)));}
  if(search&&search.charAt(0)!=='?')search='?'+search;
  s+=search;
  var hash=obj.hash||'';
  if(hash&&hash.charAt(0)!=='#')hash='#'+hash;
  s+=hash;
  return s;
}
function __url_objToPairs(o){var r=[];Object.keys(o).forEach(function(k){var v=o[k];if(Array.isArray(v))v.forEach(function(x){r.push([k,String(x)]);});else r.push([k,String(v)]);});return r;}
function __url_resolve(from,to){
  try{var b=new URL(String(from));var r=new URL(String(to),b);return r.href;}
  catch(e){
    try{return new URL(String(to)).href;}catch(e2){return String(to);}
  }
}

def('url',{
  URL:URL,
  URLSearchParams:URLSearchParams,
  parse:__url_legacyParse,
  format:__url_format,
  resolve:__url_resolve,
  fileURLToPath:function(u){var url=u instanceof URL?u:new URL(String(u));return decodeURIComponent(url.pathname);},
  pathToFileURL:function(p){return new URL('file://'+(String(p).charAt(0)==='/'?'':'/')+String(p));},
  domainToASCII:function(d){return String(d).toLowerCase();},
  domainToUnicode:function(d){return String(d);}
});
