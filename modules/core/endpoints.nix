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
          ip = lib.mkOption {
            type = alib.types.ip.addr;
            description = "IP address of this endpoint target. Overlay targets use IPv6; direct targets may use IPv4 or IPv6.";
          };
          backup = lib.mkOption {
            default = false;
            type = lib.types.bool;
            description = "Use this target only when regular targets are unavailable.";
          };
          down = lib.mkOption {
            default = false;
            type = lib.types.bool;
            description = "Mark this target as unavailable to load balancers.";
          };
          weight = lib.mkOption {
            default = 1;
            type = lib.types.ints.positive;
            description = "Relative load-balancing weight of this target.";
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
              description = "Policy used to select a target when a service supports endpoint load balancing.";
            };
            targets = lib.mkOption {
              default = [ ];
              type = lib.types.uniq (lib.types.listOf targetType);
              description = "Backend targets for this endpoint. Service modules consume their addresses and target flags.";
            };
            port = lib.mkOption {
              type = lib.types.port;
              description = "Port exposed by this endpoint.";
            };
            proxyv2 = lib.mkOption {
              default = null;
              type = lib.types.nullOr lib.types.bool;
              description = "Whether to use the PROXY protocol v2 when supported; null lets the consuming service choose.";
            };
            httpBuffering = lib.mkOption {
              default = null;
              type = lib.types.nullOr lib.types.bool;
              description = "Whether to buffer proxied HTTP responses; null lets the consuming service choose.";
            };
            httpResponseTimeout = lib.mkOption {
              default = null;
              type = lib.types.nullOr lib.types.int;
              description = "How long wait in seconds HTTP responses from upstream; null lets the consuming service choose.";
            };
          };
        }
      );
    in
    {
      options.endpoints = lib.mkOption {
        default = { };
        type = lib.types.attrsOf endpointType;
        description = "Named network endpoints and their backend targets.";
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
          lib.mapAttrsToList (endpointName: endpoint: [
            {
              assertion = alib.types.dns.label.check endpointName;
              message = "[Alloy] Endpoint '${endpointName}': The name must be a valid DNS label.";
            }
            {
              assertion = builtins.length endpoint.targets > 0;
              message = "[Alloy] Endpoint '${endpointName}': Declare at least one target in `targets`.";
            }
          ]) alloy.endpoints
        );
      };
    };
}
