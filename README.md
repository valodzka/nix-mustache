
# Pure nix mustache implementation
Pure nix implementation of [mustache](https://mustache.github.io/) template engine.

## Examples

``` nix
# basic usage
(import ./mustache){ template = "Hello, {{name}}!"; view = { name = "nix"; }; }

# with escape
let
  mustache = import ./mustache;
  escapeFunction = string: builtins.replaceStrings ["nix"] ["NIX"] string;
in
  mustache { template = "Hello, {{name}}!"; view = { name = "nix"; }; config = { inherit escapeFunction; }; }
```

### Configs templating

Given template `Corefile.mustache` & nix file `coredns-config.nix`:

```
# generated for {{pkgs.coredns.name}}
.:53 {
  forward . 8.8.8.8
  log
  {{#brokenSites}}
  template IN AAAA {{.}} {
    rcode NXDOMAIN
  }
  {{/brokenSites}}
}
```

``` nix
{ pkgs ? import <nixpkgs>  { config = {}; overlays = []; }, mustache ? import ./mustache }:

let
  template = builtins.readFile ./Corefile.mustache;
  config = mustache {
    template = template;
    view = {
      brokenSites = ["broken.com" "big-isp.com"];
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
  forward . 8.8.8.8
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
- [x] variables`{{escaped}}`, `{{&unescaped}}` (default escape function does nothing)
- [x] sections `{{#section}}`
- [x] inverted sections `{{^inverted}}`
- [x] lambdas `{{#lambda}}`
- [x] comments `{{!comment}}`
- [x] variables dot notation `{{obj.prop}}`
- [x] tests

## Not implemented
- [ ] partials `{{>partial}}`
- [ ] set delimiter `{{=<% %>=}}`
- [ ] `{{{unescaped}}}`

## Run tests

    nix-instantiate --strict --eval --json test.nix