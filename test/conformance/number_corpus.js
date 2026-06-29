// G2 number/float formatting corpus. Each case runs isolated (try/catch) so one failure never aborts the
// rest. golden = native node output (regenerate with: node number_corpus.js > number_corpus.golden.txt).
function r(l, fn){ var v; try { v = "" + fn(); } catch(e){ v = "THREW:" + ((e && e.message) || e); } console.log(l + "=" + v); }
// shortest round-trip toString
r("ts-int", function(){ return (255).toString(); });
r("ts-neg", function(){ return (-42).toString(); });
r("ts-tenth", function(){ return (0.1).toString(); });
r("ts-sum", function(){ return (0.1 + 0.2).toString(); });
r("ts-third", function(){ return (1/3).toString(); });
r("ts-big", function(){ return (1e21).toString(); });
r("ts-small", function(){ return (1e-7).toString(); });
r("ts-smaller", function(){ return (5e-324).toString(); });
r("ts-max", function(){ return (Number.MAX_VALUE).toString(); });
r("ts-frac", function(){ return (123.456).toString(); });
r("ts-e", function(){ return (1234567890123456789).toString(); });
r("ts-neg0", function(){ return (-0).toString(); });
r("ts-pi", function(){ return (Math.PI).toString(); });
r("ts-1e100", function(){ return (1e100).toString(); });
r("ts-9999", function(){ return (9999999999999999).toString(); });
r("ts-0001", function(){ return (0.0001).toString(); });
r("ts-00001", function(){ return (0.00001).toString(); });
r("ts-1point5", function(){ return (1.5).toString(); });
r("ts-100", function(){ return (100).toString(); });
// radix
r("rdx-2", function(){ return (255).toString(2); });
r("rdx-16", function(){ return (255).toString(16); });
r("rdx-36", function(){ return (35).toString(36); });
r("rdx-frac2", function(){ return (0.5).toString(2); });
// toFixed
r("fx-0", function(){ return (3.14159).toFixed(0); });
r("fx-2", function(){ return (3.14159).toFixed(2); });
r("fx-round", function(){ return (2.5).toFixed(0); });
r("fx-round2", function(){ return (0.125).toFixed(2); });
r("fx-neg", function(){ return (-1.005).toFixed(2); });
r("fx-big", function(){ return (123456.789).toFixed(3); });
r("fx-pad", function(){ return (1).toFixed(5); });
// toPrecision
r("pr-3", function(){ return (3.14159).toPrecision(3); });
r("pr-5", function(){ return (123.456).toPrecision(5); });
r("pr-exp", function(){ return (0.00001234).toPrecision(2); });
r("pr-big", function(){ return (123456).toPrecision(3); });
// toExponential
r("ex-2", function(){ return (123.456).toExponential(2); });
r("ex-0", function(){ return (123.456).toExponential(0); });
r("ex-auto", function(){ return (123.456).toExponential(); });
r("ex-neg", function(){ return (-0.00012).toExponential(3); });
// parse edges
r("pf-1", function(){ return parseFloat("3.14abc"); });
r("pf-2", function(){ return parseFloat(".5"); });
r("pf-3", function(){ return parseFloat("1e3"); });
r("pf-nan", function(){ return parseFloat("abc"); });
r("pi-1", function(){ return parseInt("0x1F", 16); });
r("pi-2", function(){ return parseInt("777", 8); });
r("pi-3", function(){ return parseInt("42px"); });
// specials
r("sp-inf", function(){ return (Infinity).toString(); });
r("sp-ninf", function(){ return (-Infinity).toString(); });
r("sp-nan", function(){ return (NaN).toString(); });
