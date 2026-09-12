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
          upstream = {
            endpoint = lib.mkOption {
              type = lib.types.str;
            };
          };
        };
      };

      httpRouteSubmodule = { config, ... }: {
        options = {
          domain = lib.mkOption {
            type = alib.types.zoneNode;
          };
          addDnsRecords = lib.mkOption {
            default = true;
            type = lib.types.bool;
          };
          downstream = {
            http2 = lib.mkOption {
              default = true;
              type = lib.types.bool;
            };
            http3 = lib.mkOption {
              default = false;
              type = lib.types.bool;
            };
            tls.mode = lib.mkOption {
              default = "none";
              type = lib.types.enum [
                "none"
                "add"
                "force"
                "only"
              ];
            };
            tls.cert = lib.mkOption {
              default = null;
              type = lib.types.nullOr lib.types.str;
            };
          };
          upstream = {
            tls.enable = lib.mkOption {
              default = false;
              type = lib.types.bool;
            };
            endpoint = lib.mkOption {
              type = lib.types.str;
            };
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
              type = lib.types.uniq (lib.types.attrsOf (lib.types.submodule entrypointSubmodule));
            };
            routes = lib.mkOption {
              default = { };
              type = lib.types.attrsOf (lib.types.submodule dnsRouteSubmodule);
            };
          };
          http = {
            entrypoints = lib.mkOption {
              default = { };
              type = lib.types.uniq (lib.types.attrsOf (lib.types.submodule entrypointSubmodule));
            };
            routes = lib.mkOption {
              default = { };
              type = lib.types.attrsOf (lib.types.submodule httpRouteSubmodule);
            };
          };
          raw = {
            entrypoints = lib.mkOption {
              default = { };
              type = lib.types.attrsOf (lib.types.submodule entrypointSubmodule);
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
        dns.records = lib.pipe alloy.gateways [
          (lib.mapAttrsToList (
            _: gw:
            lib.mapAttrsToList (
              _: r:
              lib.mapAttrsToList (
                _: ep:
                [ ]
                ++ (lib.optional (r.addDnsRecords && ep.ipv4 != null) {
                  domain = r.domain;
                  data.a = ep.ipv4;
                })
                ++ (lib.optional (r.addDnsRecords && ep.ipv6 != null) {
                  domain = r.domain;
                  data.a = ep.ipv6;
                })
              ) gw.http.entrypoints
            ) gw.http.routes
          ))
          lib.flatten
        ];

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
              assertion = builtins.hasAttr route.upstream.endpoint alloy.endpoints;
              message = "[Alloy] Gateway '${gwName}' DNS route '${routeName}' refers to an unknown endpoint '${route.upstream.endpoint}'. Please ensure it is defined in 'config.endpoints'.";
            }) gw.dns.routes)
            ++ (lib.mapAttrsToList (epName: ep: {
              assertion = ep.ipv4 != null || ep.ipv6 != null;
              message = "[Alloy] Gateway '${gwName}' HTTP entrypoint '${epName}' must specify at least one IP address (ipv4 or ipv6).";
            }) gw.http.entrypoints)
            ++ (lib.mapAttrsToList (routeName: route: {
              assertion = builtins.hasAttr route.upstream.endpoint alloy.endpoints;
              message = "[Alloy] Gateway '${gwName}' HTTP route '${routeName}' refers to an unknown endpoint '${route.upstream.endpoint}'. Please ensure it is defined in 'config.endpoints'.";
            }) gw.http.routes)
            ++ (lib.mapAttrsToList (routeName: route: {
              assertion = route.downstream.tls.mode != "none" -> route.downstream.tls.cert != null;
              message = "[Alloy] Gateway '${gwName}' HTTP route '${routeName}' specifies tls.mode '${route.downstream.tls.mode}' but tls.cert is not set. You must specify a valid certificate reference in 'tls.cert'.";
            }) gw.http.routes)
            ++ (lib.mapAttrsToList (routeName: route: {
              assertion =
                (route.downstream.tls.cert != null) -> builtins.hasAttr route.downstream.tls.cert alloy.tls.certs;
              message = "[Alloy] Gateway '${gwName}' HTTP route '${routeName}' refers to an unknown TLS certificate '${route.downstream.tls.cert}'. Please ensure it is defined in 'config.tls.certs'.";
            }) gw.http.routes)
          ) alloy.gateways
        );
      };
    };
}
