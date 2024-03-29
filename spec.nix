
let
  pkgs = import <nixpkgs> { config = {}; overlays = []; };
  lib = pkgs.lib;
  mustache = import ./mustache { inherit lib; };
  spec = builtins.fetchGit {
    url = "https://github.com/mustache/spec.git";
    rev = "6648085ec62ddc1282284b107792e67978d8b13c";
    ref = "master";
  };
  parts = ["interpolation" "comments" "sections" "inverted" "partials" "delimiters" "~lambdas"];

  prepareData = data:
    let
      lambdaFile = builtins.toFile "eval" data.lambda.nix;
    in 
      if data ? lambda then data // { lambda = import lambdaFile; } else data;

  checkPart = part:
    let
      json = builtins.readFile (spec + "/specs/${builtins.trace "# CHECKING: ${part}" part}.json");
      attrs = builtins.fromJSON json;
      tests = attrs.tests;
      runTest = case:
        let
          result = mustache {
            template = case.template;
            view = prepareData case.data;
            config = {
              escape = lib.strings.escapeXML;
              partial = name: if builtins.hasAttr name case.partials then case.partials.${name} else null;
            };
          };
          expected = case.expected;
        in
          if result != expected then lib.debug.traceVal "FAIL: ${case.name}: EXPECTED: '${expected}', GOT: '${result}'" else lib.debug.traceVal "PASS: ${case.name}";
    in builtins.map runTest (builtins.filter
      #(t: true)
      (t: t.name != "Interpolation - Multiple Calls") # nix doesn't have state
      tests);
  failed = lib.lists.count (result: lib.strings.hasPrefix "FAIL:" result) (lib.lists.flatten (builtins.map checkPart parts));
in
  if failed == 0 then "ALL PASSED" else "FAILED: ${toString failed}"

