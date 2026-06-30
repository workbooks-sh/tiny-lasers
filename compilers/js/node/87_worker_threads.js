// node:worker_threads + node:child_process — a worker IS another supervised JS actor (the on-thesis
// model, wb-hwsp). Beam.spawn starts the worker guest; IPC rides the Beam mailbox. The parent installs ONE
// onMessage router that multiplexes {__wt:id,data} envelopes to the right Worker (chaining any prior cb so
// a guest's own Beam.onMessage still works). The worker's preamble defines parentPort/process.send and
// routes its onMessage to them. workerData is injected as a JSON literal into the worker source.
var __wt_workers={},__wt_wid=1,__wt_installed=false,__wt_prevcb=null;
function __wt_inherit(C){C.prototype=Object.create(EventEmitter.prototype);C.prototype.constructor=C;}
function __wt_router(){
  if(__wt_installed)return; __wt_installed=true; __wt_prevcb=Beam.__cb;
  Beam.onMessage(function(m){
    if(m&&m.__wt!=null&&__wt_workers[m.__wt]){ __wt_workers[m.__wt].emit('message',m.data); }
    else if(__wt_prevcb){ __wt_prevcb(m); }
  });
}
// build the worker-side preamble: `selfvar` is the global the child reads ('parentPort' or 'process'),
// `evt` is the inbound event name the child's handler is registered under ('message').
function __wt_preamble(parent,id,workerData,selfvar){
  return "globalThis.workerData="+JSON.stringify(workerData===undefined?null:workerData)+";"+
    "globalThis."+selfvar+"=Object.assign(globalThis."+selfvar+"||{},{__cb:null,"+
    "postMessage:function(m){Beam.send('"+parent+"',{__wt:"+id+",data:m});},"+
    "send:function(m){Beam.send('"+parent+"',{__wt:"+id+",data:m});},"+
    "on:function(e,f){if(e==='message')this.__cb=f;return this;},"+
    "once:function(e,f){return this.on(e,f);},close:function(){},unref:function(){return this;},ref:function(){return this;}});"+
    "Beam.onMessage(function(m){var h=globalThis."+selfvar+".__cb;if(h)h(m.data);});\n";
}

function Worker(source,opts){
  EventEmitter.call(this); __wt_router(); opts=opts||{};
  var id=__wt_wid++; this.threadId=id; __wt_workers[id]=this;
  this._h=Beam.spawn(__wt_preamble(Beam.self(),id,opts.workerData,'parentPort')+String(source));
}
__wt_inherit(Worker);
Worker.prototype.postMessage=function(m){Beam.send(this._h,{data:m});return this;};
Worker.prototype.terminate=function(){var self=this,id=this.threadId;delete __wt_workers[id];return new Promise(function(res){queueMicrotask(function(){self.emit('exit',0);res(0);});});};
Worker.prototype.ref=function(){return this;};Worker.prototype.unref=function(){return this;};

// node:worker_threads — parentPort/workerData/isMainThread read globalThis dynamically (a worker's preamble
// sets globalThis.parentPort; the main thread has none).
var wt={Worker:Worker,threadId:0,MessageChannel:function(){},SHARE_ENV:Symbol('SHARE_ENV')};
Object.defineProperty(wt,'parentPort',{get:function(){return globalThis.parentPort||null;},enumerable:true});
Object.defineProperty(wt,'workerData',{get:function(){return (typeof globalThis.workerData!=='undefined')?globalThis.workerData:null;},enumerable:true});
Object.defineProperty(wt,'isMainThread',{get:function(){return typeof globalThis.parentPort==='undefined';},enumerable:true});
def('worker_threads',wt);

// node:child_process — fork(source[,args,opts]) returns a ChildProcess; IPC is .send(msg)/.on('message')
// over the same actor mailbox. The child reads globalThis.process.send / process.on('message').
function ChildProcess(){EventEmitter.call(this);this.connected=true;this.killed=false;}
__wt_inherit(ChildProcess);
ChildProcess.prototype.send=function(m){Beam.send(this._h,{data:m});return true;};
ChildProcess.prototype.kill=function(){this.killed=true;this.connected=false;var self=this;queueMicrotask(function(){self.emit('exit',0,null);self.emit('close',0);});return true;};
ChildProcess.prototype.disconnect=function(){this.connected=false;};
function fork(source,args,opts){
  if(!Array.isArray(args)){opts=args;args=[];} opts=opts||{};
  var cp=new ChildProcess(); __wt_router(); var id=__wt_wid++; cp.pid=id; __wt_workers[id]=cp;
  // the child augments the existing `process` global with send/on('message'); workerData carries argv
  cp._h=Beam.spawn(__wt_preamble(Beam.self(),id,{argv:args},'process')+String(source));
  return cp;
}
def('child_process',{fork:fork,ChildProcess:ChildProcess});
