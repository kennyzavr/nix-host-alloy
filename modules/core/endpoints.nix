{
  flake.alloyModules.core =
    {
      alib,
      lib,
      config,
      ...
    }:
    let
      alloy = config;

      targetType = lib.types.submodule {
        options = {
          ipv6 = lib.mkOption {
            type = alib.types.ip.v6addr;
          };
          overlay = lib.mkOption {
            type = lib.types.str;
          };
          backup = lib.mkOption {
            default = false;
            type = lib.types.bool;
          };
          down = lib.mkOption {
            default = false;
            type = lib.types.bool;
          };
          weight = lib.mkOption {
            default = 1;
            type = lib.types.ints.positive;
          };
        };
      };

      endpointType = lib.types.submodule (
        { config, name, ... }: {
          options = {
            loadBalancing.policy = lib.mkOption {
              default = "least-connections";
              type = lib.types.enum [
                "round-robin"
                "least-connections"
                "ip-hash"
                "random"
              ];
            };
            targets = lib.mkOption {
              default = [ ];
              type = lib.types.unique { message = "the endpoint targets can be set only once"; } (
                lib.types.listOf targetType
              );
            };
            port = lib.mkOption {
              type = lib.types.port;
            };
            proxyv2 = lib.mkOption {
              default = null;
              type = lib.types.nullOr lib.types.bool;
            };
            httpBuffering = lib.mkOption {
              default = null;
              type = lib.types.nullOr lib.types.bool;
            };
            overlays = lib.mkOption {
              type = lib.types.attrsOf (lib.types.submodule { });
              readOnly = true;
            };
          };
          config = {
            overlays = lib.genAttrs (lib.unique (lib.map (t: t.overlay) config.targets)) (_: { });
          };
        }
      );
    in
    {
      options.endpoints = lib.mkOption {
        default = { };
        type = lib.types.attrsOf endpointType;
      };

      options.hosts = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options.endpoints = lib.mkOption {
              default = { };
              type = lib.types.attrsOf (lib.types.submodule { });
            };
          }
        );
      };

      options.jails = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options.endpoints = lib.mkOption {
              default = { };
              type = lib.types.attrsOf (lib.types.submodule { });
            };
          }
        );
      };

      config = {
        assertions = lib.flatten (
          lib.mapAttrsToList (
            endpointName: endpoint:
            [
              {
                assertion = alib.types.dns.label.check endpointName;
                message = "[Alloy] Endpoint name '${endpointName}' contains invalid characters or is too long. Use only lowercase letters, numbers, and hyphens (max 63 characters).";
              }
              {
                assertion = builtins.length endpoint.targets > 0;
                message = "[Alloy] Endpoint '${endpointName}': missing targets. Each endpoint must have at least one target specified in the 'targets' list.";
              }
            ]
            ++ (lib.imap1 (i: target: [
              {
                assertion = builtins.hasAttr target.overlay alloy.overlays;
                message = "[Alloy] Endpoint '${endpointName}' target #${toString i}: uses an unknown overlay '${target.overlay}'. This overlay is not defined in 'config.overlays'.";
              }
              {
                assertion =
                  builtins.hasAttr target.overlay alloy.overlays
                  -> lib.hasPrefix alloy.overlays.${target.overlay}.ipv6Prefix target.ipv6;
                message = "[Alloy] Endpoint '${endpointName}' target #${toString i}: IPv6 address '${target.ipv6}' does not belong to the prefix of overlay '${target.overlay}' (prefix: '${
                  alloy.overlays.${target.overlay}.ipv6Prefix
                }').";
              }
            ]) endpoint.targets)
          ) alloy.endpoints
        );
      };
    };
}
