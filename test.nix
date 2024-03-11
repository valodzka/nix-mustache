
let
  pkgs = (import <nixpkgs>  { config = {}; overlays = []; });
  mustache = (import ./mustache);
  # TODO: test failures?
  tests = [
    { t = "hello, {{name}} {{name}}"; v = { name = "World"; }; e = "hello, World World"; }
    { t = "hello, {{ name }} {{  name   }}"; v = { name = "World"; }; e = "hello, World World"; }
    { t = "{{#foo}}{{.}} is {{foo}}{{/foo}}"; v = { foo = "bar"; }; e = "bar is bar"; }
    { t = "hello, {{#name}}friend{{/name}}"; v = { name = "World"; }; e = "hello, friend"; }
    { t = "hello, {{#name}}friend{{/name}}"; v = { }; e = "hello, "; }
    { t = "hello, {{! comment}} friend"; v = { }; e = "hello,  friend"; }
    { t = "hello, {{! \ncom\nment\n\n}} friend"; v = { }; e = "hello,  friend"; }
    { t = "packages: {{#packages}}-{{/packages}}"; v = { packages = ["a" "b" "c"]; }; e = "packages: ---"; }
    { t = "function {{call}}"; v = { call = v: "call!"; }; e = "function call!"; }
    { t = "is {{#call}}{{name}} ok{{/call}}?"; v = { call = text: "[" + text + "]" ; name = "Alex"; }; e = "is [Alex ok]?"; }
    { t = "package: {{#packages}}{{.}}{{/packages}}"; v = { packages = "a"; }; e = "package: a"; }
    { t = "packages: {{#packages}}{{.}},{{/packages}}"; v = { packages = ["a" "b" "c"]; }; e = "packages: a,b,c,"; }
    { t = "{{#os}}os {{.}} packages: {{#packages}}{{.}},{{/packages}} {{/os}}"; v = { packages = ["a" "b" "c"]; os = ["win" "mac"]; };
      e = "os win packages: a,b,c, os mac packages: a,b,c, "; }
    { t = "hello, {{^name}}no friend{{/name}}"; v = { }; e = "hello, no friend"; }
    { t = "hello, {{^name}}no friend{{/name}}"; v = { name = false; }; e = "hello, no friend"; }
    { t = "hello, {{name}}"; v = {}; e = "hello, "; }
    { t = "hello, {{#person}}{{name}} {{/person}}"; v = { name = "Default"; person = [1 { name = "Alex"; }]; }; e = "hello, Default Alex "; }
    { t = "1 + 2 = {{n}}"; v = { n = 3; }; e = "1 + 2 = 3"; }
    { t = "dot syntax is {{obj.goes.deep}}"; v = { obj = { goes = { deep = "deep"; }; }; }; e = "dot syntax is deep"; }
    { t = "dot syntax in section is {{#obj.goes}}{{deep}}{{/obj.goes}}"; v = { obj = { goes = { deep = "deep"; }; }; }; e = "dot syntax in section is deep"; }
    { t = "with escape: {{html}}, without: {{&html}}"; v = { html = "<tag>"; }; e = "with escape: &lt;tag&gt;, without: <tag>"; }
  ];
  runTest = case: let
    result = (mustache { template = case.t; view = case.v; config = { lib = pkgs.lib; escapeFunction = pkgs.lib.strings.escapeXML; }; });
    expected = case.e;
  in
    if result != expected then throw "EXPECTED: '${expected}', GOT: '${result}'" else result;
  results = builtins.map runTest tests;
in results


