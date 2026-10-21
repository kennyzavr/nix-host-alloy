{
  flake.alloyModules.core =
    {
      alib,
      lib,
      config,
      ...
    }:
    let
      v4Submodule = { config, ... }: {
        options = {
          mode = lib.mkOption {
            type = lib.types.attrTag {
              static = lib.mkOption {
                type = lib.types.submodule {
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
              };
              dhcp = lib.mkOption {
                type = lib.types.submodule { };
              };
            };
          };
          advertiseAddress = lib.mkOption {
            type = alib.types.ip.v4addr;
            default = config.mode.static.address;
          };
        };
      };
      v6Submodule = { config, ... }: {
        options = {
          mode = lib.mkOption {
            type = lib.types.attrTag {
              static = lib.mkOption {
                type = lib.types.submodule {
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
              };
              auto = lib.mkOption {
                type = lib.types.submodule {
                };
              };
            };
          };
          advertiseAddress = lib.mkOption {
            type = alib.types.ip.v6addr;
            default = config.mode.static.address;
          };
        };
      };
      netSubmodule = { config, name, ... }: {
        options = {
          managed = lib.mkOption {
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
              (lib.optional (net.v4 != null && net.v4.mode ? static) {
                Address = "${net.v4.mode.static.address}/${toString net.v4.mode.static.prefixLength}";
              })
              ++ (lib.optional (net.v6 != null && net.v6.mode ? static) {
                Address = "${net.v6.mode.static.address}/${toString net.v6.mode.static.prefixLength}";
              });

            routes =
              (lib.optional (net.v4 != null && net.v4.mode ? static && net.v4.mode.static.gateway != null) {
                Gateway = net.v4.mode.static.gateway;
                Destination =
                  if net.default then
                    "0.0.0.0/0"
                  else
                    "${net.v4.mode.static.gateway}/${toString net.v4.mode.static.prefixLength}";
                Source = net.v4.mode.static.address;
              })
              ++ (lib.optional (net.v6 != null && net.v6.mode ? static && net.v6.mode.static.gateway != null) {
                Gateway = net.v6.mode.static.gateway;
                Destination =
                  if net.default then
                    "::/0"
                  else
                    "${net.v6.mode.static.gateway}/${toString net.v6.mode.static.prefixLength}";
                Source = net.v6.mode.static.address;
              });

            networkConfig = {
              DHCP = if net.v4 != null && net.v4.mode ? dhcp then "ipv4" else "no";
              IPv6AcceptRA = net.v6 != null && net.v6.mode ? auto;
            };
          };
        in
        {
          nixosModule = {
            systemd.network.networks = lib.optionalAttrs net.managed {
              "10-${net.iface}" = netConfig;
            };
            boot.initrd.systemd.network.networks = lib.optionalAttrs net.managed {
              "10-${net.iface}" = netConfig;
            };
          };
        };
      hostSubmodule = { config, name, ... }: {
        options.primaryNet = lib.mkOption {
          readOnly = true;
          type = lib.types.str;
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
            ]
            ++ lib.concatLists (
              lib.mapAttrsToList (netName: net: [
                {
                  assertion = net.v4 != null || net.v6 != null;
                  message = "[Alloy] Host '${name}', net '${netName}': at least of one ip block must be specified (v4 or v6)";
                }
              ]) config.nets
            );

            primaryNet = builtins.head primaryNets;

            nixosModule = lib.mkMerge [
              (lib.mkMerge (lib.catAttrs "nixosModule" configs))
              {
                networking.useNetworkd = true;
                networking.useDHCP = false;
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
