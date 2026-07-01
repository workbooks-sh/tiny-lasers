// magic-string-0.30.11 feature cases — source string manipulation. Prepended with cjs_prelude + the UMD bundle,
// so `module.exports` is the MagicString class. Each line: `label=<result string>`.
const MagicString = module.exports;
function show(label, v) { console.log(label + "=" + String(v)); }

var s;
s = new MagicString('hello world');           show("basic", s.toString());
s = new MagicString('hello world'); s.overwrite(0, 5, 'goodbye'); show("overwrite", s.toString());
s = new MagicString('hello world'); s.update(6, 11, 'there');     show("update", s.toString());
s = new MagicString('abc'); s.append('DEF');                      show("append", s.toString());
s = new MagicString('abc'); s.prepend('XYZ');                     show("prepend", s.toString());
s = new MagicString('abc'); s.appendLeft(1, '[L]');               show("appendLeft", s.toString());
s = new MagicString('abc'); s.appendRight(1, '[R]');              show("appendRight", s.toString());
s = new MagicString('abc'); s.prependLeft(1, '[PL]');             show("prependLeft", s.toString());
s = new MagicString('abc'); s.prependRight(1, '[PR]');            show("prependRight", s.toString());
s = new MagicString('hello world'); s.remove(0, 6);               show("remove", s.toString());
s = new MagicString('hello world'); show("slice", s.slice(0, 5));
s = new MagicString('  hi  '); s.trim();                          show("trim", s.toString());
s = new MagicString('a\nb\nc'); s.indent('  ');                   show("indent", s.toString());
s = new MagicString('hello'); var c = s.clone(); c.append('!');   show("clone", s.toString() + '|' + c.toString());
s = new MagicString('hello world'); show("snip", s.snip(0, 5).toString());
s = new MagicString('hello'); show("isEmpty", '' + s.isEmpty());
s = new MagicString(''); show("isEmptyTrue", '' + s.isEmpty());
s = new MagicString('hello world'); show("length", '' + s.length());
s = new MagicString('foobar'); s.overwrite(0, 3, 'X'); s.overwrite(3, 6, 'Y'); show("multi-overwrite", s.toString());
s = new MagicString('abcdef'); s.remove(1, 2); s.remove(4, 5);    show("multi-remove", s.toString());
s = new MagicString('one two three'); s.overwrite(4, 7, 'TWO'); s.append(' END'); show("mixed", s.toString());
