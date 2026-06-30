// node:process — the process global (also exposed as globalThis.process, Node-style).
var process=globalThis.process={argv:['node','/work/main'],argv0:'node',env:{},platform:'linux',arch:'wasm32',pid:1,ppid:0,
version:'v18.19.0',versions:{node:'18.19.0',v8:'0'},title:'node',
nextTick:function(f){var a=Array.prototype.slice.call(arguments,1);Promise.resolve().then(function(){f.apply(null,a);});},
cwd:function(){return '/work';},chdir:function(){},exit:function(c){throw {__node_exit:c||0};},
hrtime:function(p){return p?[0,0]:[0,0];},
on:function(){return process;},once:function(){return process;},emit:function(){return false;},
stdout:{write:function(s){Javy.IO.writeSync(1,new TextEncoder().encode(String(s)));return true;},isTTY:false},
stderr:{write:function(s){Javy.IO.writeSync(2,new TextEncoder().encode(String(s)));return true;},isTTY:false}};
process.hrtime.bigint=function(){return 0n;};
def('process',process);
