// marked-4.3.0 feature cases — markdown → HTML. Prepended with cjs_prelude + the marked bundle, so
// `module.exports` is the marked module. Each line: `label=<JSON-stringified HTML>` (single line, escape-safe).
const M = module.exports;
const p = M.parse;
function show(label, md) { console.log(label + "=" + JSON.stringify(p(md))); }
show("h1", "# Hello");
show("h3", "### Sub");
show("bold", "**x**");
show("em", "*y*");
show("inlinecode", "`c`");
show("para", "a paragraph of text");
show("link", "[t](http://u)");
show("image", "![alt](http://img)");
show("ul", "- a\n- b\n- c");
show("ol", "1. one\n2. two");
show("blockquote", "> quote");
show("hr", "---");
show("codeblock", "```\nx=1\n```");
show("nested", "**bold _and italic_**");
show("escape", "a \\* b");
show("table", "| a | b |\n| - | - |\n| 1 | 2 |");
