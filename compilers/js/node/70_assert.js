// node:assert — the common surface (assert(), ok/equal/strictEqual/deepEqual/throws/fail).
function AssertionError(m){var e=new Error(m||'assertion failed');e.name='AssertionError';return e;}
function assert(v,m){if(!v)throw AssertionError(m);}
assert.ok=assert;
assert.equal=function(a,b,m){if(a!=b)throw AssertionError(m||a+' != '+b);};
assert.strictEqual=function(a,b,m){if(a!==b)throw AssertionError(m||a+' !== '+b);};
assert.notEqual=function(a,b,m){if(a==b)throw AssertionError(m);};
assert.deepEqual=function(a,b,m){if(JSON.stringify(a)!==JSON.stringify(b))throw AssertionError(m||'not deep equal');};
assert.deepStrictEqual=assert.deepEqual;
assert.fail=function(m){throw AssertionError(m||'failed');};
assert.throws=function(fn,m){var t=false;try{fn();}catch(e){t=true;}if(!t)throw AssertionError(m||'did not throw');};
def('assert',assert);
