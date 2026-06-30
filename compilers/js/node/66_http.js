// node:http (+ https alias) — HTTP/1.1 client over node:net + a minimal parser. Server (createServer)
// is added once HostNet has a listen/accept seam. Pure JS: require('net')/require('url') (both in-scope).
// This is the Wave-2 keystone — http is what turns "runs npm libraries" into "runs clients/servers".
// NB: require() isn't defined until 99_require.js (later in concat order), so resolve modules LAZILY at
// call-time, never at prelude-eval time. (A top-level require here throws and breaks the whole prelude.)
function __http_inherit(C){C.prototype=Object.create(EventEmitter.prototype);C.prototype.constructor=C;}

function IncomingMessage(){EventEmitter.call(this);this.statusCode=0;this.statusMessage='';this.headers={};this.httpVersion='1.1';this.method=null;this.url=null;this.complete=false;}
__http_inherit(IncomingMessage);
IncomingMessage.prototype.setEncoding=function(e){this._enc=e;return this;};

function ClientRequest(opts,cb){EventEmitter.call(this);
  if(typeof opts==='string')opts=__http_parseUrl(opts);
  this.method=(opts.method||'GET').toUpperCase();
  this.path=opts.path||opts.pathname||'/';
  this._host=opts.host||opts.hostname||'127.0.0.1';
  this._port=opts.port||80;
  this._headers={};for(var k in (opts.headers||{}))this._headers[k]=opts.headers[k];
  this._body=[];this._ended=false;
  if(cb)this.once('response',cb);
}
__http_inherit(ClientRequest);
ClientRequest.prototype.setHeader=function(k,v){this._headers[k]=v;return this;};
ClientRequest.prototype.getHeader=function(k){return this._headers[k];};
ClientRequest.prototype.write=function(chunk,enc){this._body.push(Buffer.isBuffer(chunk)?chunk:Buffer.from(String(chunk),(typeof enc==='string'?enc:'utf8')));return true;};
ClientRequest.prototype.end=function(chunk,enc){if(chunk!=null)this.write(chunk,enc);this.__send();return this;};
ClientRequest.prototype.abort=function(){if(this.socket)this.socket.destroy();};
ClientRequest.prototype.__send=function(){var self=this;
  var body=Buffer.concat(this._body);
  var lines=[this.method+' '+this.path+' HTTP/1.1'];
  var hasHost=false,hasLen=false;
  for(var k in this._headers){var lk=k.toLowerCase();if(lk==='host')hasHost=true;if(lk==='content-length')hasLen=true;lines.push(k+': '+this._headers[k]);}
  if(!hasHost)lines.push('Host: '+this._host+':'+this._port);
  if(!hasLen&&body.length)lines.push('Content-Length: '+body.length);
  lines.push('Connection: close');
  var head=lines.join('\r\n')+'\r\n\r\n';
  var sock=require('net').connect(this._port,this._host);this.socket=sock;
  var chunks=[],parsed=false,res=null,bodyEnded=false;
  var endOnce=function(){if(res&&!bodyEnded){bodyEnded=true;res.complete=true;res.emit('end');}};
  sock.on('connect',function(){sock.write(Buffer.concat([Buffer.from(head,'latin1'),body]));});
  sock.on('data',function(d){
    if(!parsed){
      chunks.push(d);var raw=Buffer.concat(chunks);var s=raw.toString('latin1');var idx=s.indexOf('\r\n\r\n');
      if(idx<0)return;
      parsed=true;var headPart=s.slice(0,idx);var rest=raw.slice(idx+4);
      res=new IncomingMessage();var hl=headPart.split('\r\n');var statusLine=hl.shift();
      var m=statusLine.match(/HTTP\/(\d\.\d)\s+(\d+)\s*(.*)/);
      if(m){res.httpVersion=m[1];res.statusCode=parseInt(m[2],10);res.statusMessage=m[3]||'';}
      for(var i=0;i<hl.length;i++){var c=hl[i].indexOf(':');if(c>0)res.headers[hl[i].slice(0,c).trim().toLowerCase()]=hl[i].slice(c+1).trim();}
      self.emit('response',res);
      if(rest.length)res.emit('data',rest);
      chunks=[];
    }else{res.emit('data',d);}
  });
  sock.on('end',endOnce);sock.on('close',endOnce);
  sock.on('error',function(e){self.emit('error',e);});
};

function __http_titlecase(k){return String(k).replace(/(^|-)([a-z])/g,function(m,p,c){return p+c.toUpperCase();});}

// ── server side ──────────────────────────────────────────────────────────────────────────────────
function ServerResponse(sock){EventEmitter.call(this);this._sock=sock;this.statusCode=200;this.statusMessage=null;this._headers={};this.headersSent=false;this.finished=false;}
__http_inherit(ServerResponse);
ServerResponse.prototype.setHeader=function(k,v){this._headers[String(k).toLowerCase()]=v;return this;};
ServerResponse.prototype.getHeader=function(k){return this._headers[String(k).toLowerCase()];};
ServerResponse.prototype.removeHeader=function(k){delete this._headers[String(k).toLowerCase()];};
ServerResponse.prototype.writeHead=function(code,msg,headers){this.statusCode=code;if(typeof msg==='object'&&msg){headers=msg;msg=null;}if(msg)this.statusMessage=msg;if(headers)for(var k in headers)this.setHeader(k,headers[k]);return this;};
ServerResponse.prototype.__flushHead=function(bodyLen){if(this.headersSent)return;this.headersSent=true;
  var msg=this.statusMessage||STATUS_CODES[this.statusCode]||'OK';
  var lines=['HTTP/1.1 '+this.statusCode+' '+msg];var h=this._headers;var hasLen=false,hasType=false;
  for(var k in h){if(k==='content-length')hasLen=true;if(k==='content-type')hasType=true;lines.push(__http_titlecase(k)+': '+h[k]);}
  if(!hasType)lines.push('Content-Type: text/plain');
  if(bodyLen!=null&&!hasLen)lines.push('Content-Length: '+bodyLen);
  lines.push('Connection: close');
  this._sock.write(Buffer.from(lines.join('\r\n')+'\r\n\r\n','latin1'));};
ServerResponse.prototype.write=function(chunk,enc){this.__flushHead(null);this._sock.write(Buffer.isBuffer(chunk)?chunk:Buffer.from(String(chunk),(typeof enc==='string'?enc:'utf8')));return true;};
ServerResponse.prototype.end=function(chunk,enc){
  var body=chunk!=null?(Buffer.isBuffer(chunk)?chunk:Buffer.from(String(chunk),(typeof enc==='string'?enc:'utf8'))):Buffer.alloc(0);
  if(!this.headersSent)this.__flushHead(body.length);
  if(body.length)this._sock.write(body);
  this.finished=true;this._sock.end();this.emit('finish');};

function HttpServer(reqListener){EventEmitter.call(this);var self=this;if(typeof reqListener==='function')this.on('request',reqListener);
  this._net=require('net').createServer(function(sock){__http_serveConn(self,sock);});
  this._net.on('listening',function(){self.emit('listening');});}
__http_inherit(HttpServer);
HttpServer.prototype.listen=function(port,host,cb){this._net.listen(port,host,cb);return this;};
HttpServer.prototype.address=function(){return this._net.address();};
HttpServer.prototype.close=function(cb){this._net.close(cb);return this;};

function __http_serveConn(server,sock){var chunks=[],parsed=false;
  sock.on('data',function(d){chunks.push(d);if(parsed)return;
    var raw=Buffer.concat(chunks);var s=raw.toString('latin1');var idx=s.indexOf('\r\n\r\n');if(idx<0)return;parsed=true;
    var headPart=s.slice(0,idx);var rest=raw.slice(idx+4);var hl=headPart.split('\r\n');var reqLine=hl.shift()||'';var parts=reqLine.split(' ');
    var req=new IncomingMessage();req.method=parts[0]||'GET';req.url=parts[1]||'/';req.httpVersion=(parts[2]||'HTTP/1.1').replace('HTTP/','');req.socket=sock;
    for(var i=0;i<hl.length;i++){var c=hl[i].indexOf(':');if(c>0)req.headers[hl[i].slice(0,c).trim().toLowerCase()]=hl[i].slice(c+1).trim();}
    var res=new ServerResponse(sock);
    server.emit('request',req,res);
    queueMicrotask(function(){if(rest.length)req.emit('data',rest);req.complete=true;req.emit('end');});
  });}
function __http_createServer(reqListener){return new HttpServer(reqListener);}

function __http_parseUrl(u){var url=require('url');var p=url.parse(u);return {host:p.hostname||'127.0.0.1',port:p.port?parseInt(p.port,10):(p.protocol==='https:'?443:80),path:(p.path||'/'),protocol:p.protocol};}
function request(opts,cb){return new ClientRequest(opts,cb);}
function get(opts,cb){var req=request(opts,cb);req.end();return req;}

var STATUS_CODES={200:'OK',201:'Created',204:'No Content',301:'Moved Permanently',302:'Found',304:'Not Modified',400:'Bad Request',401:'Unauthorized',403:'Forbidden',404:'Not Found',500:'Internal Server Error',502:'Bad Gateway',503:'Service Unavailable'};
var METHODS=['GET','POST','PUT','DELETE','HEAD','OPTIONS','PATCH','CONNECT','TRACE'];
def('http',{request:request,get:get,createServer:__http_createServer,Server:HttpServer,ServerResponse:ServerResponse,IncomingMessage:IncomingMessage,ClientRequest:ClientRequest,STATUS_CODES:STATUS_CODES,METHODS:METHODS,globalAgent:{}});
// https: no TLS yet (a follow-up — tls over :ssl); same client surface so plain-http endpoints work.
def('https',{request:request,get:get,STATUS_CODES:STATUS_CODES,METHODS:METHODS});
