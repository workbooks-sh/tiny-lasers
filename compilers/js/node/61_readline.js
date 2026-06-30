// node:readline — pure-JS line reader over an input Readable (wb-8mdz.1). No host calls.
// Buffers input 'data' chunks, splits on \n (handles \r\n), emits a 'line' per complete line and
// 'close' when input ends. Extends the in-scope EventEmitter (same shared IIFE as 20_events.js).
function __rl_Interface(opts){
  EventEmitter.call(this);
  opts = opts || {};
  this.input = opts.input;
  this.output = opts.output || null;
  this.__buf = '';
  this.__closed = false;
  this.__questionCb = null;
  this.__lineQueue = [];   // pending lines for asyncIterator
  this.__iterWaiters = []; // resolvers waiting on a line
  var self = this;
  if(this.input && typeof this.input.on === 'function'){
    this.input.on('data', function(chunk){ self.__onData(chunk); });
    this.input.on('end', function(){ self.__onEnd(); });
    this.input.on('close', function(){ self.__onEnd(); });
  }
}
__rl_Interface.prototype = Object.create(EventEmitter.prototype);
__rl_Interface.prototype.constructor = __rl_Interface;

__rl_Interface.prototype.__onData = function(chunk){
  if(this.__closed) return;
  var s = (chunk==null) ? '' : (typeof chunk==='string' ? chunk : (chunk && chunk.toString ? chunk.toString() : String(chunk)));
  this.__buf += s;
  var idx;
  while((idx = this.__buf.indexOf('\n')) >= 0){
    var line = this.__buf.slice(0, idx);
    this.__buf = this.__buf.slice(idx + 1);
    if(line.charAt(line.length-1) === '\r') line = line.slice(0, -1);
    this.__emitLine(line);
  }
};
__rl_Interface.prototype.__emitLine = function(line){
  if(this.__questionCb){ var cb = this.__questionCb; this.__questionCb = null; try{ cb(line); }catch(e){} return; }
  if(this.__iterWaiters.length){ var w = this.__iterWaiters.shift(); w({ value: line, done: false }); }
  else this.__lineQueue.push(line);
  this.emit('line', line);
};
__rl_Interface.prototype.__onEnd = function(){
  if(this.__closed) return;
  if(this.__buf.length){
    var last = this.__buf; this.__buf = '';
    if(last.charAt(last.length-1) === '\r') last = last.slice(0, -1);
    this.__emitLine(last);
  }
  this.close();
};
__rl_Interface.prototype.close = function(){
  if(this.__closed) return;
  this.__closed = true;
  // flush any iterator waiters with done
  while(this.__iterWaiters.length){ this.__iterWaiters.shift()({ value: undefined, done: true }); }
  this.emit('close');
};
__rl_Interface.prototype.write = function(s){
  if(this.output && typeof this.output.write === 'function'){ try{ this.output.write(String(s)); }catch(e){} }
  return this;
};
__rl_Interface.prototype.question = function(query, cb){
  if(this.output && typeof this.output.write === 'function'){ try{ this.output.write(String(query)); }catch(e){} }
  if(this.__lineQueue.length){ var line = this.__lineQueue.shift(); try{ cb(line); }catch(e){} return; }
  this.__questionCb = cb;
};
__rl_Interface.prototype[Symbol.asyncIterator] = function(){
  var self = this;
  return {
    next: function(){
      if(self.__lineQueue.length) return Promise.resolve({ value: self.__lineQueue.shift(), done: false });
      if(self.__closed) return Promise.resolve({ value: undefined, done: true });
      return new Promise(function(resolve){ self.__iterWaiters.push(resolve); });
    },
    return: function(){ self.close(); return Promise.resolve({ value: undefined, done: true }); },
    [Symbol.asyncIterator]: function(){ return this; }
  };
};

function __rl_createInterface(opts){
  // Support createInterface(input, output) signature too.
  if(opts && typeof opts.on === 'function'){ opts = { input: opts, output: arguments[1] }; }
  return new __rl_Interface(opts || {});
}

def('readline', {
  Interface: __rl_Interface,
  createInterface: __rl_createInterface
});
