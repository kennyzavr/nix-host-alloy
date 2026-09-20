{
  flake.alloyModules.core =
    {
      alib,
      lib,
      config,
      ...
    }:
    let
      v4Submodule = {
        options = {
          address = lib.mkOption {
            type = alib.types.ip.v4addr;
          };
          gateway = lib.mkOption {
            type = lib.types.nullOr alib.types.ip.v4addr;
          };
          prefixLength = lib.mkOption {
            type = lib.types.ints.between 0 32;
          };
        };
      };
      v6Submodule = {
        options = {
          address = lib.mkOption {
            type = alib.types.ip.v6addr;
          };
          gateway = lib.mkOption {
            type = lib.types.nullOr alib.types.ip.v6addr;
          };
          prefixLength = lib.mkOption {
            type = lib.types.ints.between 0 128;
          };
        };
      };
      netSubmodule = { config, name, ... }: {
        options = alib.types.netMatchOpts // {
          static = lib.mkOption {
            default = false;
            type = lib.types.bool;
          };
          primary = lib.mkOption {
            default = false;
            type = lib.types.bool;
          };
          default = lib.mkOption {
            default = false;
            type = lib.types.bool;
          };
          iface = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
          };
          v4 = lib.mkOption {
            type = lib.types.nullOr (lib.types.submodule v4Submodule);
          };
          v6 = lib.mkOption {
            type = lib.types.nullOr (lib.types.submodule v6Submodule);
          };
        };
      };
      mkNet =
        net:
        let
          netConfig = {
            matchConfig.Name = net.iface;
            addresses =
              (lib.optional (net.v4 != null) {
                Address = "${net.v4.address}/${toString net.v4.prefixLength}";
              })
              ++ (lib.optional (net.v6 != null) {
                Address = "${net.v6.address}/${toString net.v6.prefixLength}";
              });
            # FIXME: add assertion that checks net.v4/v6.gateway != null
            routes =
              (lib.optional (net.v4 != null && net.v4.gateway != null) {
                Gateway = net.v4.gateway;
                Destination =
                  if net.default then "0.0.0.0/0" else "${net.v4.gateway}/${toString net.v4.prefixLength}";
                Source = net.v4.address;
              })
              ++ (lib.optional (net.v6 != null && net.v6.gateway != null) {
                Gateway = net.v6.gateway;
                Destination = if net.default then "::/0" else "${net.v6.gateway}/${toString net.v6.prefixLength}";
                Source = net.v6.address;
              });
          };
        in
        {
          nixosModule = {
            systemd.network.networks = lib.optionalAttrs net.static {
              "10-${net.iface}" = netConfig;
            };
            boot.initrd.systemd.network.networks = lib.optionalAttrs net.static {
              "10-${net.iface}" = netConfig;
            };
          };
        };
      hostSubmodule = { config, name, ... }: {
        options.primaryNet = lib.mkOption {
          readOnly = true;
          type = lib.types.submodule netSubmodule;
        };
        options.nets = lib.mkOption {
          default = { };
          type = lib.types.attrsOf (lib.types.submodule netSubmodule);
        };
        config =
          let
            defaultNets = builtins.attrNames (lib.filterAttrs (_: net: net.default) config.nets);
            primaryNets = builtins.attrNames (lib.filterAttrs (_: net: net.primary) config.nets);

            configs = lib.mapAttrsToList (_: mkNet) config.nets;
          in
          {
            assertions = [
              {
                assertion = builtins.length defaultNets <= 1;
                message = "[Alloy] Host '${name}': at most one net can be configured as a default network, got: ${toString (builtins.length defaultNets)}";
              }
              {
                assertion = builtins.length primaryNets == 1;
                message = "[Alloy] Host '${name}': one primary net must be configured, got: ${toString (builtins.length primaryNets)}";
              }
            ]
            ++ lib.concatLists (
              lib.mapAttrsToList (netName: net: [
                {
                  assertion = net.v4 != null || net.v6 != null;
                  message = "[Alloy] Host '${name}', net '${netName}': at least of one ip block must be specified (v4 or v6)";
                }
              ]) config.nets
            );

            primaryNet = config.nets.${builtins.head primaryNets};

            nixosModule = lib.mkMerge [
              (lib.mkMerge (lib.catAttrs "nixosModule" configs))
              {
                networking.useNetworkd = true;
                systemd.network.enable = true;
                boot.initrd.systemd.network.enable = true;

                networking.nftables.enable = true;
                networking.hostName = name;

                boot.kernel.sysctl = {
                  "net.ipv4.ip_forward" = true;
                  "net.ipv6.conf.all.forwarding" = true;
                  "net.ipv4.conf.all.accept_redirects" = false;
                  "net.ipv6.conf.all.accept_redirects" = false;
                  "net.ipv4.conf.all.ip_nonlocal_bind" = true;
                  "net.ipv6.conf.all.ip_nonlocal_bind" = true;
                };
              }
            ];
          };
      };
    in
    {
      options.hosts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
      };
    };
}
