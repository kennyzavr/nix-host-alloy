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
          port = lib.mkOption {
            type = lib.types.port;
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

      endpointType = lib.types.submodule {
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
        };
      };
    in
    {
      options.endpoints = lib.mkOption {
        default = { };
        type = lib.types.attrsOf endpointType;
      };

      config = {
        assertions = lib.flatten (
          lib.mapAttrsToList (
            endpointName: endpoint:
            [
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
