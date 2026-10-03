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
              type = lib.types.uniq (lib.types.listOf targetType);
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
          lib.mapAttrsToList (endpointName: endpoint: [
            {
              assertion = alib.types.dns.label.check endpointName;
              message = "[Alloy] Endpoint name '${endpointName}' contains invalid characters or is too long. Use only lowercase letters, numbers, and hyphens (max 63 characters).";
            }
            {
              assertion = builtins.length endpoint.targets > 0;
              message = "[Alloy] Endpoint '${endpointName}': missing targets. Each endpoint must have at least one target specified in the 'targets' list.";
            }
          ]) alloy.endpoints
        );
      };
    };
}
