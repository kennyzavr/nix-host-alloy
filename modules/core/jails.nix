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

      mkVethIpv4 =
        jail:
        "10.99.${toString (jail.uplink.localIdx / 253)}.${
          toString ((lib.mod jail.uplink.localIdx 253) + 2)
        }";
      mkVethIpv6 = jail: "fd00:99::${lib.toHexString (jail.uplink.localIdx + 2)}";
      mkVethIface = jail: "al-v${toString (jail.idx)}-0";

      portType = lib.types.either lib.types.port (
        lib.types.submodule {
          options = {
            from = lib.mkOption {
              type = lib.types.port;
              description = "First port in the forwarded range, inclusive.";
            };
            to = lib.mkOption {
              type = lib.types.port;
              description = "Last port in the forwarded range, inclusive.";
            };
            __toString = lib.mkOption {
              type = lib.types.unspecified;
              internal = true;
            };
          };
          config.__toString = self: "${toString self.from}-${toString self.to}";
        }
      );

      forwardType = lib.types.submodule (
        { config, ... }: {
          options = {
            port = lib.mkOption {
              type = portType;
              description = "Host port or port range that receives forwarded traffic.";
            };
            targetPort = lib.mkOption {
              type = portType;
              default = config.port;
              description = "Port or matching-length range inside the jail; defaults to `port`.";
            };
            proto = lib.mkOption {
              type = lib.types.enum [
                "tcp"
                "udp"
              ];
              description = "Transport protocol for this port forward.";
            };
            openFirewall = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether to open the forwarded host port in the host firewall.";
            };
            iface = lib.mkOption {
              default = null;
              type = lib.types.nullOr lib.types.str;
              description = "Limit forwarding to traffic arriving on this host interface.";
            };
            ip = lib.mkOption {
              default = null;
              type = lib.types.nullOr alib.types.ip.addr;
              description = "Limit forwarding to traffic addressed to this host IP; null matches any address.";
            };
          };
        }
      );

      jailSubmodule =
        {
          name,
          config,
          options,
          ...
        }:
        {
          options = {
            idx = lib.mkOption {
              type = lib.types.ints.unsigned;
              readOnly = true;
              default = alloy.indexes."jails".get name;
            };
            host = lib.mkOption {
              type = lib.types.str;
              description = "Host that runs this jail.";
            };
            uplink = {
              allowEgress = lib.mkOption {
                default = false;
                type = lib.types.bool;
                description = "Allow this jail to initiate connections outside its uplink.";
              };
              forwards = lib.mkOption {
                default = [ ];
                type = lib.types.listOf forwardType;
                description = "Host-to-jail port forwarding rules.";
              };
              ipv6 = lib.mkOption {
                type = lib.types.str;
              };
              ipv4 = lib.mkOption {
                type = lib.types.str;
              };
              localIdx = lib.mkOption {
                type = lib.types.ints.unsigned;
                readOnly = true;
              };
            };
            stateVersion = lib.mkOption {
              type = lib.types.str;
              default = alloy.hosts.${config.host}.stateVersion;
              description = "NixOS state version used by this jail; defaults to its host's state version.";
            };
            nixosModule = lib.mkOption {
              type = lib.types.deferredModule;
              default = { };
              description = "NixOS module merged into this jail's generated configuration.";
              apply =
                module:
                let
                  moduleLocation = "jails.${lib.strings.escapeNixIdentifier name}.nixosModule";
                in
                {
                  _class = "nixos";
                  _file = moduleLocation;
                  key = moduleLocation;
                  imports = [
                    module
                    {
                      system.stateVersion = lib.mkDefault config.stateVersion;
                    }
                  ];
                };
            };
            assertions = lib.mkOption {
              type = lib.types.listOf alib.types.assertion;
              default = [ ];
            };
            warnings = lib.mkOption {
              type = lib.types.listOf alib.types.warning;
              default = [ ];
            };
            tags = lib.mkOption {
              default = [ ];
              type = lib.types.listOf lib.types.str;
            };
          };

          config = {
            uplink.ipv4 = mkVethIpv4 config;
            uplink.ipv6 = mkVethIpv6 config;
            uplink.localIdx = lib.pipe alloy.jails [
              (lib.mapAttrsToList (
                jailName: jail: {
                  name = jailName;
                  inherit jail;
                }
              ))
              (lib.filter ({ jail, ... }: jail.host == config.host))
              (lib.sort (a: b: a.name < b.name))
              (lib.lists.findFirstIndex (j: j.name == name) null)
            ];

            assertions = [
              {
                assertion = alib.types.dns.label.check name;
                message = "[Alloy] Jail '${name}': The name must be a valid DNS label.";
              }
              {
                assertion = builtins.hasAttr config.host alloy.hosts;
                message = ''
                  [Alloy] Jail '${name}': Host '${config.host}' is not defined in `hosts`.

                  Jail host definitions:
                  ${lib.concatStringsSep "\n" (map (f: "  - ${f}") options.host.files)}
                '';
              }
            ]
            ++ (lib.flatten (
              lib.imap0 (forwardIdx: forward: [
                {
                  assertion =
                    (builtins.isInt forward.port -> builtins.isInt forward.targetPort)
                    || (builtins.isAttrs forward.port -> builtins.isAttrs forward.targetPort);
                  message = "[Alloy] Jail '${name}', port forward #${toString forwardIdx}: `port` and `targetPort` must both be integers or both be `{ from, to }` ranges.";
                }
                {
                  assertion = builtins.isAttrs forward.port -> forward.port.from <= forward.port.to;
                  message = "[Alloy] Jail '${name}', port forward #${toString forwardIdx}: `port.from` must be less than or equal to `port.to`.";
                }
                {
                  assertion = builtins.isAttrs forward.targetPort -> forward.targetPort.from <= forward.targetPort.to;
                  message = "[Alloy] Jail '${name}', port forward #${toString forwardIdx}: `targetPort.from` must be less than or equal to `targetPort.to`.";
                }
                {
                  assertion =
                    (builtins.isAttrs forward.port && builtins.isAttrs forward.targetPort)
                    -> (forward.port.to - forward.port.from) == (forward.targetPort.to - forward.targetPort.from);
                  message = "[Alloy] Jail '${name}', port forward #${toString forwardIdx}: `port` and `targetPort` ranges must have the same length.";
                }
                {
                  assertion = forward.ip != null || forward.iface != null;
                  message = "[Alloy] Jail '${name}', port forward #${toString forwardIdx}: No `ip` address or `iface` is set. This creates a catch-all rule on port ${toString forward.port} across the host. Set `ip.v4`, `ip.v6`, or `iface` to limit the rule.";
                }
              ]) config.uplink.forwards
            ));
          };
        };

      hostSubmodule = { name, config, ... }: {
        config =
          let
            bridgeIpv4 = "10.99.0.1";
            bridgeIpv6 = "fd00:99::1";
            bridgeIface = "al-br0";
          in
          {
            nixosModule = { pkgs, ... }: {
              systemd.network.netdevs."10-${bridgeIface}" = {
                netdevConfig = {
                  Kind = "bridge";
                  Name = bridgeIface;
                };
              };

              networking.nftables.tables."alloy-jail-nat" = {
                family = "inet";
                content =
                  let
                    forwardsRules = lib.concatMap (
                      jail:
                      lib.map (forward: {
                        prerouting = ''
                          ${lib.optionalString (forward.iface != null) ''iifname "${forward.iface}"''} ${
                            lib.optionalString (forward.ip ? v4) "ip daddr ${forward.ip.v4}"
                          } ${forward.proto} dport ${toString forward.port} dnat ip to ${mkVethIpv4 jail}:${toString forward.targetPort}
                          ${lib.optionalString (forward.iface != null) ''iifname "${forward.iface}"''} ${
                            lib.optionalString (forward.ip ? v6) "ip6 daddr ${forward.ip.v6}"
                          } ${forward.proto} dport ${toString forward.port} dnat ip6 to [${mkVethIpv6 jail}]:${toString forward.targetPort}
                        '';
                        output = ''
                          ${lib.optionalString (forward.ip ? v4) ''
                            ip daddr ${forward.ip.v4} ${forward.proto} dport ${toString forward.port} dnat ip to ${mkVethIpv4 jail}:${toString forward.targetPort}
                          ''}
                          ${lib.optionalString (forward.ip ? v6) ''
                            ip6 daddr ${forward.ip.v6} ${forward.proto} dport ${toString forward.port} dnat ip6 to [${mkVethIpv6 jail}]:${toString forward.targetPort}
                          ''}
                        '';
                      }) jail.uplink.forwards
                    ) (lib.filter (j: j.host == name) (builtins.attrValues alloy.jails));
                  in
                  ''
                    chain prerouting {
                      type nat hook prerouting priority dstnat; policy accept;
                      ${lib.concatMapStringsSep "\n" (x: x.prerouting) forwardsRules}
                    }
                    chain output {
                      type nat hook output priority dstnat; policy accept;
                      ${lib.concatMapStringsSep "\n" (x: x.output) forwardsRules}
                    }
                    chain postrouting {
                      type nat hook postrouting priority srcnat; policy accept;
                      ip saddr 10.99.0.0/24 masquerade
                      ip6 saddr fd00:99::/64 masquerade
                    }
                  '';
              };

              networking.firewall.extraForwardRules = ''
                ${lib.concatMapStringsSep "\n" (jail: ''
                  ${lib.concatMapStringsSep "\n" (forward: ''
                    ip daddr ${mkVethIpv4 jail} ${forward.proto} dport ${toString forward.targetPort} accept
                    ip6 daddr ${mkVethIpv6 jail} ${forward.proto} dport ${toString forward.targetPort} accept
                  '') jail.uplink.forwards}
                  ${lib.optionalString (!jail.uplink.allowEgress) ''
                    iifname ${mkVethIface jail} ip saddr ${mkVethIpv4 jail} ct state new drop
                    iifname ${mkVethIface jail} ip6 saddr ${mkVethIpv6 jail} ct state new drop
                  ''}
                '') (lib.filter (j: j.host == name) (builtins.attrValues alloy.jails))}

                iifname "${bridgeIface}" oifname != "al-*" accept
              '';

              networking.firewall.extraInputRules = ''
                ${lib.concatMapStringsSep "\n" (jail: ''
                  iifname "${bridgeIface}" ip saddr ${mkVethIpv4 jail} udp dport 53 ${
                    if jail.uplink.allowEgress then "accept" else "drop"
                  }
                  iifname "${bridgeIface}" ip6 saddr ${mkVethIpv6 jail} udp dport 53 ${
                    if jail.uplink.allowEgress then "accept" else "drop"
                  }
                '') (lib.filter (j: j.host == name) (builtins.attrValues alloy.jails))}
              '';

              systemd.network.networks =
                lib.listToAttrs (
                  lib.map (
                    jail:
                    lib.nameValuePair "10-${mkVethIface jail}" {
                      matchConfig.Name = mkVethIface jail;
                      networkConfig.Bridge = bridgeIface;
                    }
                  ) (lib.filter (j: j.host == name) (builtins.attrValues alloy.jails))
                )
                // {
                  "10-${bridgeIface}" = {
                    matchConfig.Name = bridgeIface;
                    address = [
                      "${bridgeIpv4}/24"
                      "${bridgeIpv6}/64"
                    ];
                    networkConfig = {
                      ConfigureWithoutCarrier = true;
                    };
                  };
                };

              containers = lib.mapAttrs' (
                jailName: jail:
                lib.nameValuePair "alloy-jail-${jailName}" {
                  autoStart = true;
                  ephemeral = true;
                  privateUsers = "no";
                  extraVeths = {
                    ${mkVethIface jail} = {
                      hostBridge = bridgeIface;
                    };
                  };
                  config = { ... }: {
                    imports = [
                      jail.nixosModule
                    ];

                    nixpkgs.pkgs = lib.mkDefault pkgs;
                    networking.useNetworkd = true;
                    systemd.network.enable = true;
                    networking.nftables.enable = true;
                    networking.useHostResolvConf = false;

                    networking.firewall.interfaces.${mkVethIface jail} = {
                      allowedUDPPorts = lib.pipe jail.uplink.forwards [
                        (lib.filter (f: f.openFirewall && builtins.isInt f.targetPort && f.proto == "udp"))
                        (lib.map (f: f.targetPort))
                      ];
                      allowedUDPPortRanges = lib.pipe jail.uplink.forwards [
                        (lib.filter (f: f.openFirewall && builtins.isAttrs f.targetPort && f.proto == "udp"))
                        (lib.map (f: f.targetPort))
                      ];
                      allowedTCPPorts = lib.pipe jail.uplink.forwards [
                        (lib.filter (f: f.openFirewall && builtins.isInt f.targetPort && f.proto == "tcp"))
                        (lib.map (f: f.targetPort))
                      ];
                      allowedTCPPortRanges = lib.pipe jail.uplink.forwards [
                        (lib.filter (f: f.openFirewall && builtins.isAttrs f.targetPort && f.proto == "tcp"))
                        (lib.map (f: f.targetPort))
                      ];
                    };

                    systemd.network.networks."10-${mkVethIface jail}" = {
                      matchConfig.Name = mkVethIface jail;
                      address = [
                        "${mkVethIpv4 jail}/24"
                        "${mkVethIpv6 jail}/64"
                      ];
                      routes = [
                        { Gateway = bridgeIpv4; }
                        { Gateway = bridgeIpv6; }
                      ];
                      networkConfig = {
                        DNS = [
                          "8.8.8.8"
                          "8.8.4.4"
                        ];
                      };
                    };
                  };
                }
              ) (lib.filterAttrs (_: jail: jail.host == name) alloy.jails);
            };
          };
      };
    in
    {
      options.jails = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule jailSubmodule);
      };

      options.hosts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
      };

      config = {
        warnings = lib.flatten (lib.mapAttrsToList (_: jail: jail.warnings) alloy.jails);

        assertions =
          lib.flatten (lib.mapAttrsToList (_: jail: jail.assertions) alloy.jails)
          ++ (lib.flatten (
            lib.mapAttrsToList (hostName: host: [
              {
                assertion =
                  builtins.length (lib.filter (jail: jail.host == hostName) (builtins.attrValues alloy.jails))
                  <= 256 * 253;
                message = "[Alloy] Host '${hostName}': A host can serve at most ${toString (256 * 253)} jails.";
              }
            ]) alloy.hosts
          ));

        indexes."jails" = {
          keys = builtins.attrNames alloy.jails;
          minValue = 1;
          maxValue = 999;
        };

        build.state = { ... }: {
          jails = lib.mapAttrs (_: jail: {
            inherit (jail) host tags;
          }) alloy.jails;
        };
      };
    };
}
