// The async spine's generic promise-completion registry (wb-5q8w) — the contract EVERY async I/O module
// (fs/net/http) reuses. A shim calls __wb_async(arm): it allocates a completion id, registers a pending
// promise, and calls arm(id) to issue the host op (a host import that kicks off VFS/socket/etc work). When
// the host op finishes it re-enters the guest at the wb_complete export, which calls __wb_dispatch_complete
// here to resolve/reject the right promise with the host's JSON result. Host op done → mailbox → re-enter
// → resolve. Callback-style APIs wrap this: fn(err,res) => __wb_async(arm).then(r=>fn(null,r),e=>fn(e)).
var __pending={},__cid=1;
globalThis.__wb_async=function(arm){var id=__cid++;return new Promise(function(res,rej){__pending[id]={res:res,rej:rej};try{arm(id);}catch(e){delete __pending[id];rej(e);}});};
// resolve/reject a pending completion (ok=true → resolve with value, ok=false → reject with value).
globalThis.__wb_complete=function(id,ok,val){var p=__pending[id];if(!p)return;delete __pending[id];if(ok)p.res(val);else p.rej(val);};
// the host re-enters here (wb_complete export): pull the {id,ok,value} envelope the host stashed and apply it.
globalThis.__wb_dispatch_complete=function(){var m=JSON.parse(__io_recv());__wb_complete(m.id,m.ok,m.value);};

// EVENT CHANNELS — the streaming sibling of one-shot completion (for sockets, watchers, …). A shim opens a
// channel with an onEvent(event,value) handler; the host delivers repeated events (e.g. socket 'data',
// 'close') by re-entering the wb_event export, which routes {channel,event,value} to the handler. Reuses
// the same :washy_io_inbox slot (one re-entry carries one envelope).
var __chan={},__chanId=1;
globalThis.__wb_open_channel=function(onEvent){var id=__chanId++;__chan[id]=onEvent;return id;};
globalThis.__wb_close_channel=function(id){delete __chan[id];};
globalThis.__wb_dispatch_event=function(){var m=JSON.parse(__io_recv());var h=__chan[m.channel];if(h)h(m.event,m.value);};
