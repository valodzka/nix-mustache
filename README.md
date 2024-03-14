
# Pure nix mustache implementation
Pure nix implementation of [mustache](https://mustache.github.io/) template engine.

## Examples

``` nix
# basic usage, library should be local
let 
  pkgs = import <nixpkgs> { config = {}; overlays = []; };
  mustache = import ./mustache { inherit (pkgs) lib; };
in
  mustache { template = "Hello, {{name}}!"; view = { name = "nix"; }; }

# (unreproducible) library loading from github & custom escape
let
  pkgs = import <nixpkgs> { config = {}; overlays = []; };
  repo = builtins.fetchGit {
    url = "https://github.com/valodzka/nix-mustache.git";
    ref = "master";
  };
  mustache = import (repo + "/mustache") { lib = pkgs.lib; };
  escape = string: builtins.replaceStrings ["nix"] ["NIX"] string;
in
  mustache { template = "Hello, {{name}}!"; view = { name = "nix"; }; config = { inherit escape; }; }
```

### Configs templating

Given template `Corefile.mustache` & nix file `coredns-config.nix`:

```
# generated for {{pkgs.coredns.name}}
.:53 {
  forward .{{#dnsServers}} {{.}}{{/dnsServers}}
  log

  {{#brokenSites}}
  template IN AAAA {{.}} {
    rcode NXDOMAIN
  }
  {{/brokenSites}}
}
```

``` nix
{ pkgs ? import <nixpkgs>  { config = {}; overlays = []; }, mustache ? import ./mustache { lib = pkgs.lib; } }:

let
  config = mustache {
    template = ./Corefile.mustache;
    view = {
      brokenSites = ["broken.com" "big-isp.com"];
      dnsServers = ["8.8.8.8" "8.8.4.4"];
      pkgs = pkgs;
    };
  };
  corefile = pkgs.writeTextFile {
      name = "Corefile";
      destination = "/etc/coredns/Corefile";
      text = config;
  };
in corefile
```

Run `nix-env --install --file coredns-config.nix` and it will generate:

```
# generated for coredns-1.11.1
.:53 {
  forward . 8.8.8.8 8.8.4.4
  log

  template IN AAAA broken.com {
    rcode NXDOMAIN
  }
  template IN AAAA big-isp.com {
    rcode NXDOMAIN
  }
}
```

## Features
- variables`{{escaped}}`, `{{&unescaped}}`, `{{{unescaped}}}` (default escape function does nothing)
- sections `{{#section}}`
- inverted sections `{{^inverted}}`
- lambdas `{{#lambda}}`
- comments `{{!comment}}`
- variables dot notation `{{obj.prop}}`
- partials `{{>partial}}`
- set delimiter `{{=<% %>=}}`
- tests, spec

## Tests
### Run [mustache spec](https://github.com/mustache/spec)
Implements all non optional modules.

    nix-instantiate --eval spec.nix
    
### Run tests

    nix-instantiate --strict --eval --json test.nix | jq .
