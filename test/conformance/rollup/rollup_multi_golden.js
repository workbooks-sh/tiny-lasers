'use strict';

const upper = (s) => s.toUpperCase();
const punct = "!";

function greet(n) { return "hi " + upper(n) + punct; }
function farewell(n) { return "bye " + n; }

const VERSION = "@v1";

const who = "world";
const msg = greet(who) + " " + farewell(who) + VERSION;
console.log(msg);

exports.msg = msg;
