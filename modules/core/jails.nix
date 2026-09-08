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

  indexes = alloy.facts."jail-index-table".value;

  portType = lib.types.either lib.types.port (
    lib.types.submodule {
      options = {
        from = lib.mkOption { type = lib.types.port; };
        to = lib.mkOption { type = lib.types.port; };
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
        port = lib.mkOption { type = portType; };
        targetPort = lib.mkOption {
          type = portType;
          default = config.port;
        };
        proto = lib.mkOption {
          type = lib.types.enum [
            "tcp"
            "udp"
          ];
        };
        openFirewall = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
      }
      // alib.types.netMatchOpts;
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
        name = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = name;
        };
        idx = lib.mkOption {
          type = lib.types.ints.unsigned;
          readOnly = true;
          default = indexes.${name};
        };
        host = lib.mkOption {
          type = lib.types.str;
        };
        uplink = {
          allowEgress = lib.mkOption {
            default = false;
            type = lib.types.bool;
          };
          forwards = lib.mkOption {
            default = [ ];
            type = lib.types.listOf forwardType;
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
        nixosModule = lib.mkOption {
          type = lib.types.deferredModule;
          default = { };
          apply = module: {
            _class = "nixos";
            _file = "jails.${lib.strings.escapeNixIdentifier name}.nixosModule";
            imports = [ module ];
          };
        };
        assertions = lib.mkOption {
          type = lib.types.listOf alib.types.assertion;
          default = [ ];
        };
      };

      config = {
        uplink.ipv4 = mkVethIpv4 config;
        uplink.ipv6 = mkVethIpv6 config;
        uplink.localIdx = (
          lib.lists.findFirstIndex (j: j.name == name) null (
            lib.pipe alloy.jails [
              builtins.attrValues
              (lib.filter (j: j.host == config.host))
              (lib.sort (a: b: a.name < b.name))
            ]
          )
        );

        assertions = [
          {
            assertion = builtins.hasAttr config.host alloy.hosts;
            message = ''
              [Alloy] Invalid host reference in jail '${name}'

              You attempted to assign jail '${name}' to host '${config.host}',
              but this host is not declared in 'hosts'.

              Location:
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
              message = "alloy: jail '${name}': forward '${toString forwardIdx}': both port and targetPort must have the same type: either integer or { from, to } range";
            }
            {
              assertion = builtins.isAttrs forward.port -> forward.port.from <= forward.port.to;
              message = "alloy: jail '${name}': forward '${toString forwardIdx}': port's 'from' must be less than or equal to port's 'to'";
            }
            {
              assertion = builtins.isAttrs forward.targetPort -> forward.targetPort.from <= forward.targetPort.to;
              message = "alloy: jail '${name}': forward '${toString forwardIdx}': target ports's 'from' must be less than or equal to target ports's 'to'";
            }
            {
              assertion =
                (builtins.isAttrs forward.port && builtins.isAttrs forward.targetPort)
                -> (forward.port.to - forward.port.from) == (forward.targetPort.to - forward.targetPort.from);
              message = "alloy: jail '${name}': forward '${toString forwardIdx}': both port and targetPort must have the same range length";
            }
            {
              assertion = forward.ipv4 != null || forward.ipv6 != null || forward.iface != null;
              message = ''
                [Alloy] Insecure NAT Forward rule in jail '${name}'!

                Forward index '${toString forwardIdx}' does not specify `ipv4`, `ipv6`, or `iface`.
                This creates an unconditional catch-all rule that will intercept ALL traffic on port ${toString forward.port}
                across the entire host, including internal traffic from other containers!

                To fix this, specify at least one of:
                - ipv4 (host public IP)
                - ipv6 (host public IPv6)
                - iface (host external interface)
              '';
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
                  lib.map (
                    forward:
                    let
                      hasV4 = forward.ipv4 != null;
                      hasV6 = forward.ipv6 != null;
                      catchAll = !hasV4 && !hasV6;
                      ifaceMatch = lib.optionalString (forward.iface != null) "iifname \"${forward.iface}\"";
                      ruleV4 = lib.optionalString (hasV4 || catchAll) ''
                        ${ifaceMatch} ${lib.optionalString hasV4 "ip daddr ${forward.ipv4}"} ${forward.proto} dport ${toString forward.port} dnat ip to ${mkVethIpv4 jail}:${toString forward.targetPort}
                      '';
                      ruleV6 = lib.optionalString (hasV6 || catchAll) ''
                        ${ifaceMatch} ${lib.optionalString hasV6 "ip6 daddr ${forward.ipv6}"} ${forward.proto} dport ${toString forward.port} dnat ip6 to [${mkVethIpv6 jail}]:${toString forward.targetPort}
                      '';
                      ruleV4Output = lib.optionalString hasV4 ''
                        ip daddr ${forward.ipv4} ${forward.proto} dport ${toString forward.port} dnat ip to ${mkVethIpv4 jail}:${toString forward.targetPort}
                      '';
                      ruleV6Output = lib.optionalString hasV6 ''
                        ip6 daddr ${forward.ipv6} ${forward.proto} dport ${toString forward.port} dnat ip6 to [${mkVethIpv6 jail}]:${toString forward.targetPort}
                      '';
                    in
                    {
                      prerouting = "${ruleV4}${ruleV6}";
                      output = "${ruleV4Output}${ruleV6Output}";
                    }
                  ) jail.uplink.forwards
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
                imports = [ jail.nixosModule ];

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
    generators.instances."jail-index-table" = {
      imports = [ alloy.generators.templates."index-table" ];
      name = "jail-index-table";
      keys = builtins.attrNames alloy.jails;
      minValue = 1;
      maxValue = 999;
    };

    assertions =
      lib.flatten (lib.mapAttrsToList (_: jail: jail.assertions) alloy.jails)
      ++ (lib.flatten (
        lib.mapAttrsToList (hostName: host: [
          {
            assertion =
              builtins.length (lib.filter (jail: jail.host == hostName) (builtins.attrValues alloy.jails))
              <= 256 * 253;
            message = "alloy: host '${hostName}': a host can serve no more than ${toString (256 * 253)} jails";
          }
        ]) alloy.hosts
      ));
  };
}
