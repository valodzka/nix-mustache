
let
  pkgs = (import <nixpkgs>  { config = {}; overlays = []; });
  lib = pkgs.lib;
  mustache = (import ./mustache);
  spec = builtins.fetchGit {
    url = "https://github.com/mustache/spec.git";
    rev = "6648085ec62ddc1282284b107792e67978d8b13c";
    ref = "master";
  };
  parts = ["interpolation" "comments" "sections" "inverted"];
  checkPart = part:
    let
      
      json = builtins.readFile (spec + "/specs/${builtins.trace "# CHECKING: ${part}" part}.json");
      attrs = builtins.fromJSON json;
      runTest = case:
        let
          result = (mustache { template = case.template; view = case.data; config = { lib = pkgs.lib; escapeFunction = pkgs.lib.strings.escapeXML; }; });
          expected = case.expected;
        in
          if result != expected then lib.debug.traceVal "FAIL: ${case.name}: EXPECTED: '${expected}', GOT: '${result}'" else lib.debug.traceVal "PASS: ${case.name}";
    in builtins.map runTest attrs.tests;
  failed = lib.lists.count (result: lib.strings.hasPrefix "FAIL:" result) (lib.lists.flatten (builtins.map checkPart parts));
in
  if failed == 0 then "ALL PASSED" else "FAILED: ${toString failed}"

