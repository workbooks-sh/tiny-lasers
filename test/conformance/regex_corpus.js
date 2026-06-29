var out = [];
function r(label, fn){ try { out.push(label + "=" + JSON.stringify(fn())); } catch(e){ out.push(label + "=ERR:" + e.message); } }

// {n,m} quantifiers
r("q-exact", function(){ return "aaaa".match(/a{2}/)[0]; });
r("q-range", function(){ return "aaaa".match(/a{2,3}/)[0]; });
r("q-min", function(){ return "aaaa".match(/a{2,}/)[0]; });
r("q-lazy", function(){ return "aaaa".match(/a{2,3}?/)[0]; });
r("q-zero", function(){ return "bbb".match(/a{0,2}b/)[0]; });
// groups
r("g-capture", function(){ var m="abc".match(/(a)(b)(c)/); return [m[1],m[2],m[3]]; });
r("g-noncap", function(){ var m="abc".match(/(?:a)(b)/); return m[1]; });
r("g-named", function(){ var m="2024-01".match(/(?<y>\d+)-(?<mo>\d+)/); return [m.groups.y, m.groups.mo]; });
r("g-backref-num", function(){ return /(\w)\1/.test("aa"); });
r("g-backref-named", function(){ return /(?<c>\w)\k<c>/.test("xx"); });
// alternation
r("alt-simple", function(){ return "cat".match(/cat|dog/)[0]; });
r("alt-group", function(){ return "abd".match(/a(b|c)d/)[1]; });
r("alt-multi", function(){ return "xyz".replace(/x|y|z/g,"-"); });
// classes
r("cls-range", function(){ return "a1b2".replace(/[0-9]/g,"#"); });
r("cls-neg", function(){ return "a1b2".replace(/[^0-9]/g,"#"); });
r("cls-pred-d", function(){ return "a1b2".replace(/\d/g,"#"); });
r("cls-pred-w", function(){ return "a b!c".replace(/\w/g,"#"); });
r("cls-pred-s", function(){ return "a b\tc".replace(/\s/g,"_"); });
r("cls-mixed", function(){ return "Hello World 123".replace(/[a-z0-9]/gi,"."); });
// anchors
r("anc-start", function(){ return /^abc/.test("abcd"); });
r("anc-end", function(){ return /abc$/.test("xabc"); });
r("anc-wordb", function(){ return "foo bar".match(/\bbar\b/)[0]; });
r("anc-nwordb", function(){ return "foobar".match(/\Bbar/)[0]; });
r("anc-multiline", function(){ return "a\nb".match(/^b/m)[0]; });
// lookahead
r("la-pos", function(){ return "foobar".match(/foo(?=bar)/)[0]; });
r("la-neg", function(){ return "foobaz".match(/foo(?!bar)/)[0]; });
// lookbehind
r("lb-pos", function(){ var m="$100".match(/(?<=\$)\d+/); return m&&m[0]; });
r("lb-neg", function(){ var m="a1 b2".match(/(?<!a)\d/); return m&&m[0]; });
// flags
r("f-i", function(){ return "ABC".match(/abc/i)[0]; });
r("f-g", function(){ return "aaa".match(/a/g).length; });
r("f-m", function(){ return "x\ny".replace(/^/gm,">"); });
r("f-s", function(){ return /a.b/s.test("a\nb"); });
r("f-y", function(){ var re=/a/y; re.lastIndex=0; return re.test("ab"); });
// unicode
r("u-escape", function(){ return /A/.test("A"); });
r("u-brace", function(){ return /\u{1F600}/u.test("\u{1F600}"); });
r("u-prop", function(){ var m="abc123".match(/\p{L}+/u); return m&&m[0]; });
// dotAll / special
r("dot", function(){ return "abc".replace(/./g,"#"); });
r("escape-special", function(){ return "a.b".replace(/\./g,"_"); });
// replace with function + templates
r("rep-fn", function(){ return "abc".replace(/[abc]/g, function(m){return m.toUpperCase();}); });
r("rep-tmpl", function(){ return "John Smith".replace(/(\w+) (\w+)/,"$2 $1"); });
// split
r("split-re", function(){ return "a1b2c".split(/\d/); });
r("split-cap", function(){ return "a1b2c".split(/(\d)/); });

console.log(out.join("\n"));
