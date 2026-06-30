// node:string_decoder — StringDecoder with correct utf8 multibyte-boundary buffering across write() calls.
// Pure JS. For non-utf8 encodings each write decodes directly via Buffer(...).toString(enc). Helpers __sd_*.
function __sd_normEnc(e){e=String(e||'utf8').toLowerCase();if(e==='utf-8')return'utf8';if(e==='ucs-2'||e==='utf-16le')return'utf16le';if(e==='binary')return'latin1';return e;}
// bytes needed for a utf8 lead byte (0 = continuation/invalid)
function __sd_seqLen(b){if(b<0x80)return 1;if((b&0xE0)===0xC0)return 2;if((b&0xF0)===0xE0)return 3;if((b&0xF8)===0xF0)return 4;return 0;}

class StringDecoder{
  constructor(encoding){
    this.encoding=__sd_normEnc(encoding);
    this.__partial=[];   // buffered trailing bytes of an incomplete utf8 sequence
  }
  __toBytes(buf){
    if(buf==null)return [];
    if(typeof buf==='string')return Array.prototype.slice.call(Buffer.from(buf,'utf8'));
    if(buf instanceof Uint8Array||Array.isArray(buf))return Array.prototype.slice.call(buf);
    if(buf.buffer)return Array.prototype.slice.call(new Uint8Array(buf.buffer,buf.byteOffset||0,buf.byteLength));
    return [];
  }
  write(buf){
    var bytes=this.__toBytes(buf);
    if(this.encoding!=='utf8'){
      // non-utf8: decode this chunk directly (these encodings have no cross-write boundary issue here)
      if(bytes.length===0)return '';
      return Buffer.from(bytes).toString(this.encoding);
    }
    // utf8 path: prepend any buffered partial bytes
    var data=this.__partial.concat(bytes);
    this.__partial=[];
    if(data.length===0)return '';
    // find how many trailing bytes belong to an incomplete sequence
    var hold=__sd_incompleteTail(data);
    var complete=data;
    if(hold>0){this.__partial=data.slice(data.length-hold);complete=data.slice(0,data.length-hold);}
    if(complete.length===0)return '';
    return new TextDecoder('utf-8').decode(new Uint8Array(complete));
  }
  end(buf){
    var out='';
    if(buf!=null)out+=this.write(buf);
    if(this.encoding==='utf8'&&this.__partial.length){
      // flush remaining bytes (replacement chars for truly-incomplete tail, Node-style)
      out+=new TextDecoder('utf-8').decode(new Uint8Array(this.__partial));
      this.__partial=[];
    }
    return out;
  }
}

// returns the count of trailing bytes that form an INCOMPLETE utf8 sequence (to be held for next write)
function __sd_incompleteTail(data){
  var n=data.length;
  // scan back up to 3 bytes for a lead byte
  for(var i=1;i<=Math.min(4,n);i++){
    var b=data[n-i];
    if(b<0x80)return 0;                 // ascii at this position => everything before complete
    if((b&0xC0)===0xC0){                 // a lead byte
      var need=__sd_seqLen(b);
      if(need===0)return 0;              // invalid lead — let decoder emit replacement now
      if(i<need)return i;                // not enough bytes yet — hold them
      return 0;                          // sequence complete (or over-long; decoder handles)
    }
    // else continuation byte (0x80..0xBF) — keep scanning back
  }
  // all of the last 4 were continuation bytes; hold them
  return Math.min(4,n);
}

def('string_decoder',{StringDecoder:StringDecoder});
