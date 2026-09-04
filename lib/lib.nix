{
  lib,
  alib,
  modulesPath,
  inputs,
}:
{
  inherit modulesPath;

  types = import ./types.nix {
    inherit lib;
    inherit alib;
  };

  modules = import ../modules;

  extend =
    module:
    lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule module);
    };

  getDbRecord =
    db: tableName: key:
    if !(builtins.hasAttr tableName db.tables) then
      builtins.throw "alloy: state: table '${tableName}' not found in the database. The state is likely not generated or outdated. Please run cli command 'nixpkgs run .#your-alloy-cli -- state generate -a'."
    else if !(builtins.hasAttr key db.tables.${tableName}.records) then
      builtins.throw "alloy: state: record '${key}' not found in table '${tableName}'. The state is likely not generated or outdated. Please run 'nixpkgs run .#your-alloy-cli -- state generate -a'."
    else
      db.tables.${tableName}.records.${key};

  evalModules =
    evalArgs:
    let
      res = lib.evalModules {
        modules = [
          alib.modules
        ]
        ++ (evalArgs.modules or [ ]);
        specialArgs = (evalArgs.specialArgs or { }) // {
          inherit (alib) modulesPath;
          inherit alib;
          alloy-internal-inputs = {
            inherit (inputs) agenix agenix-rekey;
          };
        };
      };
      firstFailedAssertion = lib.findFirst (a: !a.assertion) null res.config.assertions;
    in
    if (evalArgs.checkAssertions or true) && firstFailedAssertion != null then
      builtins.throw firstFailedAssertion.message
    else
      res;

  evalModule = module: alib.evalModules { modules = lib.toList module; };

  mkCli =
    {
      pkgs,
      module,
    }:
    let
      res = alib.evalModules {
        modules = [ module ];
        checkAssertions = false;
      };
    in
    res.config.cli.script { inherit pkgs; };
  # pkgs.writeShellScriptBin "alloy" ''
  #   ${res.config.cli.script { inherit flake pkgs; }} "$@"
  # '';

  mkArpaIpv6 =
    ipv6:
    let
      cleanIpv6 = builtins.replaceStrings [ ":" ] [ "" ] ipv6;
      len = builtins.stringLength cleanIpv6;
      reversedChars = builtins.genList (i: builtins.substring (len - 1 - i) 1 cleanIpv6) len;
    in
    assert lib.assertMsg (
      builtins.match "^(([0-9a-f]{4})(:[0-9a-f]{4}){0,7})?$" ipv6 != null
    ) "mkArapIpv6: expected ipv6 blocks, got ${ipv6}";
    builtins.concatStringsSep "." reversedChars + ".ip6.arpa.";

  findBestZone =
    fqdn: zones:
    let
      matchingZones = lib.filter (
        z:
        (lib.removeSuffix "." fqdn) == z
        || lib.hasSuffix ".${lib.removeSuffix "." z}" (lib.removeSuffix "." fqdn)
      ) zones;
      sortedZones = lib.sort (a: b: builtins.stringLength a > builtins.stringLength b) matchingZones;
    in
    if sortedZones == [ ] then null else builtins.head sortedZones;

  mkIdOpt =
    name: desc:
    lib.mkOption {
      readOnly = true;
      type = lib.types.str;
      default = name;
    };

  # ref =
  #   entityName: entityMap: id:
  #   if builtins.hasAttr id entityMap then
  #     entityMap.${id}
  #   else
  #     throw ''
  #       alloy: ${entityName} '${id}' is not defined.
  #       Available ${entityName}s: [${lib.concatStringsSep ", " (builtins.attrNames entityMap)}]
  #     '';

  resolveZoneNode =
    zones: node:
    assert lib.assertMsg (builtins.hasAttr node.zone zones)
      "alloy: dns: resolveZoneNode 'zone ${node.zone}, name ${node.name}': the zone is not defined";
    "${if node.name == "@" then "" else "${lib.removeSuffix "." node.name}."}${
      lib.removeSuffix "." zones.${node.zone}.apex
    }.";

  stripStorePrefix =
    p:
    let
      s = toString p;
      m = builtins.match "^/nix/store/[a-z0-9]{32}-[^/]+/(.*)$" s;
    in
    if m != null then
      builtins.head m
    else
      p;
}
