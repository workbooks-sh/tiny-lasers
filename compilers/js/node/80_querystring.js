// node:querystring — parse/stringify (legacy API; the WHATWG URLSearchParams lives in node/url).
def('querystring',{parse:function(s){var o={};String(s||'').split('&').forEach(function(p){if(!p)return;var i=p.indexOf('=');var k=i<0?p:p.slice(0,i),v=i<0?'':p.slice(i+1);o[decodeURIComponent(k)]=decodeURIComponent(v);});return o;},
stringify:function(o){return Object.keys(o||{}).map(function(k){return encodeURIComponent(k)+'='+encodeURIComponent(o[k]);}).join('&');}});
