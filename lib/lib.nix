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

  # findBestZone =
  #   fqdn: zones:
  #   let
  #     matchingZones = lib.filter (
  #       z:
  #       (lib.removeSuffix "." fqdn) == z
  #       || lib.hasSuffix ".${lib.removeSuffix "." z}" (lib.removeSuffix "." fqdn)
  #     ) zones;
  #     sortedZones = lib.sort (a: b: builtins.stringLength a > builtins.stringLength b) matchingZones;
  #   in
  #   if sortedZones == [ ] then null else builtins.head sortedZones;

  resolveZoneNode =
    zones: node:
    assert lib.assertMsg (builtins.hasAttr node.zone zones)
      "alloy: dns: resolveZoneNode 'zone ${node.zone}, name ${node.name}': the zone is not defined";
    "${if node.name == "@" then "" else "${lib.removeSuffix "." node.name}."}${
      lib.removeSuffix "." zones.${node.zone}.apex
    }.";
}
