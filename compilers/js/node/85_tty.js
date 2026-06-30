// node:tty — a Washy guest is never attached to a real terminal, so isatty() is always false (which is
// the correct/safe default: terminal-color libraries like chalk/picocolors disable ANSI when there's no
// TTY). The Read/WriteStream stubs exist for libs that reference the classes; they extend the in-scope
// EventEmitter. Surfaced by the conformance loop (picocolors require('tty')).
function __tty_inherit(C){C.prototype=Object.create(EventEmitter.prototype);C.prototype.constructor=C;}

function ReadStream(fd){EventEmitter.call(this);this.fd=fd==null?0:fd;this.isTTY=false;this.isRaw=false;}
__tty_inherit(ReadStream);
ReadStream.prototype.setRawMode=function(m){this.isRaw=!!m;return this;};

function WriteStream(fd){EventEmitter.call(this);this.fd=fd==null?1:fd;this.isTTY=false;this.columns=80;this.rows=24;}
__tty_inherit(WriteStream);
WriteStream.prototype.getColorDepth=function(){return 1;};            // 1-bit = no color (no TTY)
WriteStream.prototype.hasColors=function(){return false;};
WriteStream.prototype.getWindowSize=function(){return [this.columns,this.rows];};
WriteStream.prototype.clearLine=function(){return true;};
WriteStream.prototype.cursorTo=function(){return true;};
WriteStream.prototype.write=function(s){Javy.IO.writeSync(this.fd||1,new TextEncoder().encode(String(s)));return true;};

def('tty',{isatty:function(fd){return false;},ReadStream:ReadStream,WriteStream:WriteStream});
