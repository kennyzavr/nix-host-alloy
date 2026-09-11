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
          serverName = lib.mkOption {
            type = lib.types.str;
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

      rawStreamSubmodule = gw: raw: { config, name, ... }: {
        options = {
          proto = lib.mkOption {
            type = lib.types.enum [
              "tcp"
            ];
            default = "tcp";
          };
          downstream = {
            port = lib.mkOption {
              type = lib.types.port;
            };
            tls.enable = lib.mkOption {
              default = false;
              type = lib.types.bool;
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

      smtpRelaySubmodule = { config, name, ... }: {
        options = {
          domains = lib.mkOption {
            default = [];
            type = lib.types.listOf lib.types.str;
            description = "Destination domains that should be routed to this upstream. Empty list means catch-all/default.";
          };
          upstream = {
            endpoint = lib.mkOption {
              type = lib.types.str;
            };
            tls = {
              enable = lib.mkOption {
                default = true;
                type = lib.types.bool;
                description = "Use STARTTLS (explicit TLS) when connecting to upstream";
              };
              verify = lib.mkOption {
                default = true;
                type = lib.types.bool;
                description = "Verify upstream TLS certificate";
              };
            };
          };
        };
      };

      smtpGatewaySubmodule = { config, ... }: {
        options = {
          entrypoints = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (lib.types.submodule entrypointSubmodule);
          };
          hostname = lib.mkOption {
            type = lib.types.str;
          };
          maxMsgSizeMB = lib.mkOption {
            default = 35;
            type = lib.types.ints.positive;
          };
          explicitTLS.mode = lib.mkOption {
            default = "require";
            type = lib.types.enum [
              "none"
              "optional"
              "require"
            ];
          };
          explicitTLS.cert = lib.mkOption {
            default = null;
            type = lib.types.nullOr lib.types.str;
          };
          relays = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (lib.types.submodule smtpRelaySubmodule);
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
          http = {
            entrypoints = lib.mkOption {
              default = { };
              type = lib.types.attrsOf (lib.types.submodule entrypointSubmodule);
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
            streams = lib.mkOption {
              default = { };
              type = lib.types.attrsOf (lib.types.submodule (rawStreamSubmodule config config.raw));
            };
          };
          smtp = lib.mkOption {
            default = { };
            type = lib.types.submodule smtpGatewaySubmodule;
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
            ++ (lib.mapAttrsToList (epName: ep: {
              assertion = ep.ipv4 != null || ep.ipv6 != null;
              message = "[Alloy] Gateway '${gwName}' RAW entrypoint '${epName}' must specify at least one IP address (ipv4 or ipv6).";
            }) gw.raw.entrypoints)
            ++ (lib.mapAttrsToList (streamName: stream: {
              assertion = builtins.hasAttr stream.upstream.endpoint alloy.endpoints;
              message = "[Alloy] Gateway '${gwName}' RAW stream '${streamName}' refers to an unknown endpoint '${stream.upstream.endpoint}'. Please ensure it is defined in 'config.endpoints'.";
            }) gw.raw.streams)
            ++ (lib.mapAttrsToList (streamName: stream: {
              assertion = stream.downstream.tls.enable -> stream.downstream.tls.cert != null;
              message = "[Alloy] Gateway '${gwName}' RAW stream '${streamName}' has downstream TLS enabled, but tls.cert is not set. You must specify a valid certificate reference in 'tls.cert'.";
            }) gw.raw.streams)
            ++ (lib.mapAttrsToList (streamName: stream: {
              assertion = (stream.downstream.tls.cert != null) -> builtins.hasAttr stream.downstream.tls.cert alloy.tls.certs;
              message = "[Alloy] Gateway '${gwName}' RAW stream '${streamName}' refers to an unknown TLS certificate '${stream.downstream.tls.cert}'. Please ensure it is defined in 'config.tls.certs'.";
            }) gw.raw.streams)
            ++ (lib.mapAttrsToList (epName: ep: {
              assertion = ep.ipv4 != null || ep.ipv6 != null;
              message = "[Alloy] Gateway '${gwName}' SMTP entrypoint '${epName}' must specify at least one IP address (ipv4 or ipv6).";
            }) gw.smtp.entrypoints)
            ++ (lib.mapAttrsToList (relayName: relay: {
              assertion = builtins.hasAttr relay.upstream.endpoint alloy.endpoints;
              message = "[Alloy] Gateway '${gwName}' SMTP relay '${relayName}' refers to an unknown endpoint '${relay.upstream.endpoint}'. Please ensure it is defined in 'config.endpoints'.";
            }) gw.smtp.relays)
            ++ [
              {
                assertion = gw.smtp.explicitTLS.mode != "none" -> gw.smtp.explicitTLS.cert != null;
                message = "[Alloy] Gateway '${gwName}' SMTP specifies explicitTLS.mode '${gw.smtp.explicitTLS.mode}' but explicitTLS.cert is not set. You must specify a valid certificate reference in 'explicitTLS.cert'.";
              }
              {
                assertion = (gw.smtp.explicitTLS.cert != null) -> builtins.hasAttr gw.smtp.explicitTLS.cert alloy.tls.certs;
                message = "[Alloy] Gateway '${gwName}' SMTP refers to an unknown TLS certificate '${gw.smtp.explicitTLS.cert}'. Please ensure it is defined in 'config.tls.certs'.";
              }
            ]
          ) alloy.gateways
        );
      };
    };
}
