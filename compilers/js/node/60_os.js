// node:os — static host facts (wasm guest; no real machine introspection).
def('os',{platform:function(){return 'linux';},arch:function(){return 'wasm32';},type:function(){return 'wasi';},release:function(){return '1.0.0';},
hostname:function(){return 'wasm';},EOL:'\n',cpus:function(){return [];},totalmem:function(){return 0;},freemem:function(){return 0;},
tmpdir:function(){return '/tmp';},homedir:function(){return '/work';},endianness:function(){return 'LE';},uptime:function(){return 0;},loadavg:function(){return [0,0,0];}});
