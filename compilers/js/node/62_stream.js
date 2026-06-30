// node:stream — pure-JS streams over EventEmitter (wb-q6ft, Wave-1). No host calls.
// Readable/Writable/Duplex/Transform/PassThrough. Emission is driven by microtasks
// (process.nextTick) since there is no real event loop — the harness drains the
// pending-job queue after each guest entry, so queued ticks run to completion.
// We reference the in-scope EventEmitter (same shared IIFE as 20_events.js).
var __stream_tick=(typeof process!=='undefined'&&process.nextTick)?process.nextTick:function(f){queueMicrotask(f);};
function __stream_inherit(C){C.prototype=Object.create(EventEmitter.prototype);C.prototype.constructor=C;return C;}
function __stream_size(chunk,objectMode){if(objectMode)return 1;if(chunk==null)return 0;if(typeof chunk==='string')return chunk.length;if(chunk.length!=null)return chunk.length;return 1;}
function __stream_concat(buf){if(buf.length===0)return null;if(typeof buf[0]==='string')return buf.join('');
  if(typeof Buffer!=='undefined'&&Buffer.concat)return Buffer.concat(buf.map(function(b){return typeof b==='string'?Buffer.from(b):b;}));
  return buf.join('');}

// ---- Readable ----------------------------------------------------------
function Readable(opts){EventEmitter.call(this);opts=opts||{};
  this._readableState={objectMode:!!opts.objectMode,highWaterMark:opts.highWaterMark!=null?opts.highWaterMark:(opts.objectMode?16:16384),
    buffer:[],length:0,flowing:null,ended:false,endEmitted:false,reading:false,readableListening:false,destroyed:false,pipes:[],resumeScheduled:false};
  if(typeof opts.read==='function')this._read=opts.read;
}
__stream_inherit(Readable);
Readable.prototype._read=function(){};
Readable.prototype.push=function(chunk,enc){return this.__push(chunk,false);};
Readable.prototype.unshift=function(chunk){return this.__push(chunk,true);};
Readable.prototype.__push=function(chunk,addToFront){var s=this._readableState;
  if(chunk===null){s.ended=true;__stream_tick_emit_end(this);return false;}
  if(addToFront)s.buffer.unshift(chunk);else s.buffer.push(chunk);
  s.length+=__stream_size(chunk,s.objectMode);
  if(s.flowing){__stream_tick_flow(this);}
  else{var self=this;__stream_tick(function(){self.emit('readable');});}
  return s.length<s.highWaterMark;
};
function __stream_tick_emit_end(r){__stream_tick(function(){__stream_maybe_end(r);});}
function __stream_maybe_end(r){var s=r._readableState;if(s.ended&&s.length===0&&!s.endEmitted){s.endEmitted=true;
  r.emit('end');var pipes=s.pipes.slice();for(var i=0;i<pipes.length;i++){pipes[i].end();}s.pipes=[];}}
Readable.prototype.read=function(n){var s=this._readableState;
  if(s.length===0){if(s.ended){__stream_maybe_end(this);return null;}if(!s.reading){s.reading=true;var self=this;__stream_tick(function(){s.reading=false;self._read(s.highWaterMark);});}return null;}
  var chunk;
  if(s.objectMode){chunk=s.buffer.shift();s.length-=1;}
  else if(n==null||n>=s.length){chunk=s.buffer.length===1?s.buffer[0]:__stream_concat(s.buffer);s.buffer=[];s.length=0;}
  else{chunk=__stream_take(s,n);}
  if(s.length===0&&s.ended)__stream_tick_emit_end(this);
  return chunk;
};
function __stream_take(s,n){var joined=__stream_concat(s.buffer);var out=joined.slice(0,n);var rest=joined.slice(n);s.buffer=rest.length?[rest]:[];s.length=rest.length;return out;}
Readable.prototype.on=function(t,f){var r=EventEmitter.prototype.on.call(this,t,f);var s=this._readableState;
  if(t==='data'){if(s.flowing!==false){this.resume();}}
  else if(t==='readable'){s.readableListening=true;}
  return r;};
Readable.prototype.addListener=Readable.prototype.on;
Readable.prototype.resume=function(){var s=this._readableState;if(s.flowing!==true){s.flowing=true;__stream_tick_flow(this);}return this;};
Readable.prototype.pause=function(){if(this._readableState.flowing!==false)this._readableState.flowing=false;return this;};
Readable.prototype.isPaused=function(){return this._readableState.flowing===false;};
function __stream_tick_flow(r){var s=r._readableState;if(s.resumeScheduled||s.flowing!==true)return;s.resumeScheduled=true;
  __stream_tick(function(){s.resumeScheduled=false;__stream_flow(r);});}
function __stream_flow(r){var s=r._readableState;if(s.flowing!==true)return;
  while(s.flowing===true&&s.length>0){var chunk=s.buffer.shift();s.length-=__stream_size(chunk,s.objectMode);r.emit('data',chunk);}
  if(s.length===0){if(s.ended){__stream_maybe_end(r);}
    else if(!s.reading){s.reading=true;var self=r;__stream_tick(function(){s.reading=false;self._read(s.highWaterMark);if(self._readableState.flowing===true&&self._readableState.length>0)__stream_tick_flow(self);});}}
}
Readable.prototype.pipe=function(dest,opts){var src=this;var s=this._readableState;opts=opts||{};s.pipes.push(dest);
  var ondata=function(chunk){var ok=dest.write(chunk);if(ok===false){src.pause();dest.once('drain',function(){src.resume();});}};
  this.on('data',ondata);
  dest.emit('pipe',src);
  return dest;
};
Readable.prototype.unpipe=function(dest){var s=this._readableState;if(!dest){s.pipes=[];}else{var i=s.pipes.indexOf(dest);if(i>-1)s.pipes.splice(i,1);}return this;};
Readable.prototype.destroy=function(err){var s=this._readableState;if(s.destroyed)return this;s.destroyed=true;var self=this;__stream_tick(function(){if(err)self.emit('error',err);self.emit('close');});return this;};
Readable.from=function(iterable,opts){opts=opts||{};if(opts.objectMode==null)opts.objectMode=true;var r=new Readable(opts);
  var items;if(Array.isArray(iterable))items=iterable.slice();
  else if(iterable&&typeof Symbol!=='undefined'&&typeof iterable[Symbol.iterator]==='function'){items=[];for(var it=iterable[Symbol.iterator](),step;!(step=it.next()).done;)items.push(step.value);}
  else items=[iterable];
  var i=0;r._read=function(){if(i<items.length){r.push(items[i++]);}else{r.push(null);}};
  return r;};

// ---- Writable ----------------------------------------------------------
function Writable(opts){EventEmitter.call(this);opts=opts||{};
  this._writableState={objectMode:!!opts.objectMode,highWaterMark:opts.highWaterMark!=null?opts.highWaterMark:(opts.objectMode?16:16384),
    length:0,buffered:[],writing:false,corked:0,ended:false,finished:false,needDrain:false,destroyed:false};
  if(typeof opts.write==='function')this._write=opts.write;
  if(typeof opts.final==='function')this._final=opts.final;
}
__stream_inherit(Writable);
Writable.prototype._write=function(chunk,enc,cb){cb();};
Writable.prototype.write=function(chunk,enc,cb){var w=this._writableState;
  if(typeof enc==='function'){cb=enc;enc='utf8';}
  if(w.ended){var er=new Error('write after end');var self0=this;__stream_tick(function(){if(cb)cb(er);self0.emit('error',er);});return false;}
  var len=__stream_size(chunk,w.objectMode);w.length+=len;
  var ret=w.length<w.highWaterMark;if(!ret)w.needDrain=true;
  if(w.writing||w.corked){w.buffered.push({chunk:chunk,enc:enc,cb:cb});}
  else{__stream_doWrite(this,chunk,enc,cb,len);}
  return ret;
};
function __stream_doWrite(stream,chunk,enc,cb,len){var w=stream._writableState;w.writing=true;
  stream._write(chunk,enc,function(err){w.writing=false;w.length-=len;
    if(err){if(cb)__stream_tick(function(){cb(err);});__stream_tick(function(){stream.emit('error',err);});return;}
    if(cb)__stream_tick(function(){cb();});
    if(w.buffered.length&&!w.corked){var nx=w.buffered.shift();__stream_doWrite(stream,nx.chunk,nx.enc,nx.cb,__stream_size(nx.chunk,w.objectMode));}
    else{if(w.needDrain&&w.length<w.highWaterMark){w.needDrain=false;__stream_tick(function(){stream.emit('drain');});}
      if(w.ended&&w.length===0&&w.buffered.length===0)__stream_finishMaybe(stream);}
  });
}
Writable.prototype.cork=function(){this._writableState.corked++;return this;};
Writable.prototype.uncork=function(){var w=this._writableState;if(w.corked>0)w.corked--;
  if(w.corked===0&&!w.writing&&w.buffered.length){var nx=w.buffered.shift();__stream_doWrite(this,nx.chunk,nx.enc,nx.cb,__stream_size(nx.chunk,w.objectMode));}
  return this;};
Writable.prototype.end=function(chunk,enc,cb){var w=this._writableState;
  if(typeof chunk==='function'){cb=chunk;chunk=null;enc=null;}else if(typeof enc==='function'){cb=enc;enc=null;}
  if(chunk!=null)this.write(chunk,enc);
  w.ended=true;if(cb)this.once('finish',cb);
  if(!w.writing&&w.length===0&&w.buffered.length===0)__stream_finishMaybe(this);
  return this;};
function __stream_finishMaybe(stream){var w=stream._writableState;if(w.finished||!w.ended)return;
  if(w.length!==0||w.writing||w.buffered.length)return;
  var fin=function(){w.finished=true;stream.emit('finish');};
  if(stream._final){__stream_tick(function(){stream._final(function(){fin();});});}
  else{__stream_tick(fin);}
}
Writable.prototype.destroy=function(err){var w=this._writableState;if(w.destroyed)return this;w.destroyed=true;var self=this;__stream_tick(function(){if(err)self.emit('error',err);self.emit('close');});return this;};

// ---- Duplex ------------------------------------------------------------
function Duplex(opts){EventEmitter.call(this);opts=opts||{};
  Readable.call(this,opts);Writable.call(this,opts);
  if(typeof opts.read==='function')this._read=opts.read;
  if(typeof opts.write==='function')this._write=opts.write;
}
Duplex.prototype=Object.create(Readable.prototype);
// Splice in Writable's instance methods (write/end/cork/uncork/_write/destroy).
Duplex.prototype.write=Writable.prototype.write;Duplex.prototype.end=Writable.prototype.end;
Duplex.prototype.cork=Writable.prototype.cork;Duplex.prototype.uncork=Writable.prototype.uncork;
Duplex.prototype._write=Writable.prototype._write;
Duplex.prototype.constructor=Duplex;
Duplex.prototype._read=function(){};
Duplex.prototype.destroy=function(err){Readable.prototype.destroy.call(this,err);return this;};

// ---- Transform ---------------------------------------------------------
function Transform(opts){opts=opts||{};
  Duplex.call(this,opts);
  if(typeof opts.transform==='function')this._transform=opts.transform;
  if(typeof opts.flush==='function')this._flush=opts.flush;
  var self=this;
  // route _write through _transform; push transformed data into the readable side
  this._write=function(chunk,enc,cb){self._transform(chunk,enc,function(err,data){
    if(err){cb(err);return;}if(data!=null)self.push(data);cb();});};
  // on end, run _flush, then push EOF (null) to close the readable side
  this._final=function(cb){if(self._flush){self._flush(function(err,data){if(data!=null)self.push(data);self.push(null);cb&&cb(err);});}
    else{self.push(null);cb&&cb();}};
}
Transform.prototype=Object.create(Duplex.prototype);
Transform.prototype.constructor=Transform;
Transform.prototype._transform=function(chunk,enc,cb){cb(null,chunk);};

// ---- PassThrough -------------------------------------------------------
function PassThrough(opts){Transform.call(this,opts);}
PassThrough.prototype=Object.create(Transform.prototype);
PassThrough.prototype.constructor=PassThrough;
PassThrough.prototype._transform=function(chunk,enc,cb){cb(null,chunk);};

// ---- Stream (alias) + exports -----------------------------------------
function Stream(opts){EventEmitter.call(this);}
__stream_inherit(Stream);
Stream.Readable=Readable;Stream.Writable=Writable;Stream.Duplex=Duplex;Stream.Transform=Transform;
Stream.PassThrough=PassThrough;Stream.Stream=Stream;
Stream.pipeline=function(){var args=Array.prototype.slice.call(arguments);var cb=typeof args[args.length-1]==='function'?args.pop():null;
  for(var i=0;i<args.length-1;i++){args[i].pipe(args[i+1]);}
  var last=args[args.length-1];if(cb){last.on('finish',function(){cb();});last.on('end',function(){cb();});last.on('error',cb);}
  return last;};

def('stream',{Readable:Readable,Writable:Writable,Duplex:Duplex,Transform:Transform,PassThrough:PassThrough,Stream:Stream,pipeline:Stream.pipeline});
