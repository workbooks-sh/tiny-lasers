// bignumber.js-9.1.2 feature cases — arbitrary-precision decimal arithmetic. `module.exports` is the
// BigNumber constructor. Each line: `label=<value>`. Exercises the exact-decimal paths float can't do.
const BN = module.exports;
function show(label, v) { console.log(label + "=" + String(v)); }
show("add", new BN("0.1").plus("0.2").toString());            // exact 0.3 (float gives 0.30000000000000004)
show("sub", new BN("1").minus("0.3").toString());
show("mul", new BN("123456789").times("987654321").toString());
show("div", new BN("1").dividedBy("7").toString());           // 20 dp default
show("pow", new BN("2").pow(64).toString());                  // 18446744073709551616
show("mod", new BN("100").mod("7").toString());
show("eq", new BN("0.1").plus("0.2").eq("0.3"));              // true
show("cmp", new BN("5").comparedTo("3"));
show("abs", new BN("-5.5").abs().toString());
show("toFixed", new BN("1.23456").toFixed(2));
show("sqrt", new BN("2").sqrt().toString());
show("fromExp", new BN("1.23e10").toFixed());                 // 12300000000
show("big", new BN("99999999999999999999").plus("1").toString());
show("chain", new BN("10").dividedBy("4").times("2").toString());
