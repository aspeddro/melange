// Generated by Melange
'use strict';

var Stdlib__List = require("melange/./list.js");

var b = Stdlib__List.length({
      hd: 1,
      tl: {
        hd: 2,
        tl: {
          hd: 3,
          tl: /* [] */0
        }
      }
    });

var a = b - 1 | 0;

console.log("hello, res");

exports.a = a;
/* b Not a pure module */
