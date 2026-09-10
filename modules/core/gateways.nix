{
  flake.alloyModules.core =
    {
      lib,
      alib,
      config,
      ...
    }:
    let
      alloy = config;

      dnsRouteSubmodule = { config, ... }: {
        options = {
          suffixes = lib.mkOption {
            default = [ ];
            type = lib.types.listOf alib.types.dns.name;
          };
          endpoint = lib.mkOption {
            type = lib.types.str;
          };
        };
      };

      entrypointSubmodule = { config, name, ... }: {
        options = {
          ipv4 = lib.mkOption {
            type = lib.types.nullOr alib.types.ip.v4addr;
            default = null;
          };
          ipv6 = lib.mkOption {
            type = lib.types.nullOr alib.types.ip.v6addr;
            default = null;
          };
        };
      };

      gatewaySubmodule = { config, name, ... }: {
        options = {
          dns = {
            entrypoints = lib.mkOption {
              default = { };
              type = lib.types.attrsOf (lib.types.submodule entrypointSubmodule);
            };
            routes = lib.mkOption {
              default = { };
              type = lib.types.attrsOf (lib.types.submodule dnsRouteSubmodule);
            };
          };
        };
      };
    in
    {
      options.gateways = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule gatewaySubmodule);
      };

      config = {
        assertions = lib.flatten (
          lib.mapAttrsToList (
            gwName: gw:
            [
              {
                assertion = gw.dns.routes != { } -> gw.dns.entrypoints != { };
                message = "[Alloy] Gateway '${gwName}' defines DNS routes but has no DNS entrypoints. Please define at least one entrypoint under 'dns.entrypoints' to receive traffic.";
              }
            ]
            ++ (lib.mapAttrsToList (epName: ep: {
              assertion = ep.ipv4 != null || ep.ipv6 != null;
              message = "[Alloy] Gateway '${gwName}' DNS entrypoint '${epName}' must specify at least one IP address (ipv4 or ipv6).";
            }) gw.dns.entrypoints)
            ++ (lib.mapAttrsToList (routeName: route: {
              assertion = builtins.hasAttr route.endpoint alloy.endpoints;
              message = "[Alloy] Gateway '${gwName}' DNS route '${routeName}' refers to an unknown endpoint '${route.endpoint}'. Please ensure it is defined in 'config.endpoints'.";
            }) gw.dns.routes)
          ) alloy.gateways
        );
      };
    };
}
