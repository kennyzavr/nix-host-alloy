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
                description = "Configure a static IPv4 address.";
                type = lib.types.submodule {
                  options = {
                    address = lib.mkOption {
                      type = alib.types.ip.v4addr;
                      description = "Static IPv4 address assigned to this network interface.";
                    };
                    gateway = lib.mkOption {
                      type = lib.types.nullOr alib.types.ip.v4addr;
                      description = "Optional IPv4 gateway used to create a route.";
                    };
                    gatewayOnLink = lib.mkOption {
                      default = false;
                      type = lib.types.bool;
                      description = "Treat the configured gateway as directly reachable on this interface.";
                    };
                    prefixLength = lib.mkOption {
                      type = lib.types.ints.between 0 32;
                      description = "IPv4 prefix length for the static address.";
                    };
                  };
                };
              };
              dhcp = lib.mkOption {
                description = "Obtain IPv4 configuration through DHCP.";
                type = lib.types.submodule { };
              };
            };
          };
          advertiseAddress = lib.mkOption {
            type = alib.types.ip.v4addr;
            default = config.mode.static.address;
            description = "IPv4 address published for services; set explicitly when the address is assigned dynamically.";
          };
        };
      };
      v6Submodule = { config, ... }: {
        options = {
          mode = lib.mkOption {
            type = lib.types.attrTag {
              static = lib.mkOption {
                description = "Configure a static IPv6 address.";
                type = lib.types.submodule {
                  options = {
                    address = lib.mkOption {
                      type = alib.types.ip.v6addr;
                      description = "Static IPv6 address assigned to this network interface.";
                    };
                    gateway = lib.mkOption {
                      type = lib.types.nullOr alib.types.ip.v6addr;
                      description = "Optional IPv6 gateway used to create a route.";
                    };
                    gatewayOnLink = lib.mkOption {
                      default = false;
                      type = lib.types.bool;
                      description = "Treat the configured gateway as directly reachable on this interface.";
                    };
                    prefixLength = lib.mkOption {
                      type = lib.types.ints.between 0 128;
                      description = "IPv6 prefix length for the static address.";
                    };
                  };
                };
              };
              auto = lib.mkOption {
                description = "Accept IPv6 router advertisements for automatic address configuration.";
                type = lib.types.submodule {
                };
              };
            };
          };
          advertiseAddress = lib.mkOption {
            type = alib.types.ip.v6addr;
            default = config.mode.static.address;
            description = "IPv6 address published for services; set explicitly when the address is assigned automatically.";
          };
        };
      };
      netSubmodule = { config, name, ... }: {
        options = {
          managed = lib.mkOption {
            default = false;
            type = lib.types.bool;
            description = "Generate systemd-networkd configuration for this interface in the host and initrd.";
          };
          primary = lib.mkOption {
            default = false;
            type = lib.types.bool;
            description = "Mark this network as the host's primary network.";
          };
          default = lib.mkOption {
            default = false;
            type = lib.types.bool;
            description = "Install a default route through this network's configured gateway.";
          };
          iface = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            description = "Interface name matched by systemd-networkd when `managed` is enabled.";
          };
          v4 = lib.mkOption {
            type = lib.types.nullOr (lib.types.submodule v4Submodule);
            description = "IPv4 configuration for this network, or null to omit IPv4.";
          };
          v6 = lib.mkOption {
            type = lib.types.nullOr (lib.types.submodule v6Submodule);
            description = "IPv6 configuration for this network, or null to omit IPv6.";
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
                PreferredSource = net.v4.mode.static.address;
                GatewayOnLink = net.v4.mode.static.gatewayOnLink;
              })
              ++ (lib.optional (net.v6 != null && net.v6.mode ? static && net.v6.mode.static.gateway != null) {
                Gateway = net.v6.mode.static.gateway;
                Destination =
                  if net.default then
                    "::/0"
                  else
                    "${net.v6.mode.static.gateway}/${toString net.v6.mode.static.prefixLength}";
                PreferredSource = net.v6.mode.static.address;
                GatewayOnLink = net.v6.mode.static.gatewayOnLink;
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
          description = "Name of the network marked as primary on this host.";
        };
        options.nets = lib.mkOption {
          default = { };
          type = lib.types.attrsOf (lib.types.submodule netSubmodule);
          description = "Named network interfaces configured for this host.";
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
                message = "[Alloy] Host '${name}': At most one network can be the default network; found ${toString (builtins.length defaultNets)}.";
              }
            ]
            ++ lib.concatLists (
              lib.mapAttrsToList (netName: net: [
                {
                  assertion = net.v4 != null || net.v6 != null;
                  message = "[Alloy] Host '${name}', network '${netName}': Configure at least one IP block (`v4` or `v6`).";
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
