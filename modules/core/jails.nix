{
  alib,
  lib,
  config,
  ...
}:
let
  alloy = config;

  indexFact = alloy.vars.facts.${alloy.vars.provisioners."jail-indexes".facts.index.name};

  jailModule =
    { config, name, ... }:
    {
      options = {
        id = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = name;
        };
        idx = lib.mkOption {
          type = lib.types.int;
          readOnly = true;
        };
        host = lib.mkOption {
          type = lib.types.str;
        };
        localIdx = lib.mkOption {
          type = lib.types.int;
          readOnly = true;
        };
        nixpkgs = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
        };
        nixosModule = lib.mkOption {
          default = { };
          type = lib.types.deferredModule;
        };
      };
      config = {
        idx = indexFact.value.items.${config.id};
        localIdx =
          (lib.lists.findFirstIndex (j: j.id == config.id) null (
            lib.pipe alloy.jails [
              builtins.attrValues
              (lib.filter (j: j.host == config.host))
              (lib.sort (a: b: a.id < b.id))
            ]
          ))
          + 1;
      };
    };
  mkHostJail = host: jail: {
    nixosModule = { pkgs, ... }: {
      containers."alloy-jail-${jail.id}" = {
        autoStart = true;
        ephemeral = true;
        privateUsers = "no";
        nixpkgs = lib.mkIf (jail.nixpkgs != null) jail.nixpkgs;
        config = { ... }: {
          imports = [
            jail.nixosModule
          ];

          nixpkgs.pkgs = lib.mkIf (jail.nixpkgs == null) pkgs;

          networking.useNetworkd = true;
          systemd.network.enable = true;
          networking.nftables.enable = true;
          networking.useHostResolvConf = false;
        };
      };
    };
  };

  mkHostJails =
    host:
    let
      jails = lib.pipe alloy.jails [
        builtins.attrValues
        (lib.filter (jail: jail.host == host.id))
        (lib.map (mkHostJail host))
      ];
    in
    {
      nixosModule = { ... }: {
        imports = lib.map (jail: jail.nixosModule) jails;
      };
    };
in
{
  options = {
    jails = alib.extend jailModule;
    hosts = alib.extend (
      { config, ... }: {
        config.nixosModule = (mkHostJails config).nixosModule;
      }
    );
  };

  config = {
    assertions = lib.pipe alloy.jails [
      builtins.attrValues
      (lib.map (jail: [
        {
          assertion = jail.localIdx >= 1 && jail.localIdx <= 253;
          message = "alloy: jail '${jail.id}': localIdx must be between 1 and 253 (a host supports at most 253 jails)";
        }
      ]))
      lib.flatten
    ];
    vars.provisioners."jail-indexes" = {
      spec.index-allocator = {
        minValue = 1;
        maxValue = 999;
        reuseValues = true;
        keys = lib.mapAttrsToList (_: h: h.id) alloy.jails;
      };
      facts.index = { };
    };
  };
}

# # TODO check forward listener ports to uniqueness
# # TODO prevent catch_all nat output rules
# {
#   alib,
#   lib,
#   config,
#   ...
# }:
# let
#   alloy = config;
#   secretType =
#     jail:
#     lib.types.submodule (
#       { config, name, ... }: {
#         options = {
#           id = lib.mkOption {
#             type = lib.types.str;
#             readOnly = true;
#             default = name;
#           };
#           mountPoint = lib.mkOption {
#             type = lib.types.str;
#             default = alloy.secrets.${config.id}.path;
#           };
#           permissions = lib.mkOption {
#             type = alib.types.permissions;
#           };
#         };
#         config.permissions.mode = lib.mkOptionDefault "0400";
#       }
#     );
#   volumeType =
#     jail:
#     lib.types.submodule (
#       { config, name, ... }: {
#         options = {
#           id = lib.mkOption {
#             type = lib.types.str;
#             readOnly = true;
#             default = name;
#           };
#           mountPoint = lib.mkOption {
#             type = lib.types.str;
#             default = alloy.volumes.${config.id}.path;
#           };
#           readOnly = lib.mkOption {
#             type = lib.types.bool;
#             default = false;
#           };
#         };
#       }
#     );
#   netType =
#     host: jail:
#     lib.types.submodule (
#       { config, name, ... }: {
#         options = {
#           id = lib.mkOption {
#             type = lib.types.str;
#             readOnly = true;
#             default = name;
#           };
#           dlabel = lib.mkOption {
#             default = jail.id;
#             type = alib.types.dns.label;
#           };
#           dname = lib.mkOption {
#             readOnly = true;
#             default = "${config.dlabel}.jail.${alloy.nets.${config.id}.dname}";
#             type = alib.types.dns.name;
#           };
#           ipv6 = lib.mkOption {
#             type = lib.types.str;
#             readOnly = true;
#             default = "${host.nets.${config.id}.ipv6Prefix or ""}:0000:0000:000c:${
#               lib.fixedWidthString 4 "0" (lib.toHexString jail.idx)
#             }";
#           };
#           iface = lib.mkOption {
#             type = lib.types.str;
#             readOnly = true;
#             default = "al-v${toString jail.idx}-${toString alloy.nets.${config.id}.idx}";
#           };
#           tls = {
#             secret = lib.mkOption {
#               readOnly = true;
#               default = "nets/${config.id}/tls/${jail.id}.jail.key";
#               type = lib.types.str;
#             };
#             permissions = lib.mkOption {
#               type = alib.types.permissions;
#             };
#             keyPath = lib.mkOption {
#               readOnly = true;
#               default = "/run/alloy/nets/${config.id}/tls";
#               type = lib.types.str;
#             };
#             certPath = lib.mkOption {
#               readOnly = true;
#               default = alloy.secrets.${config.tls.secret}.generator.tls-x509-leaf.certPath;
#               type = lib.types.path;
#             };
#           };
#         };
#         config.tls.permissions.mode = lib.mkOptionDefault "0400";
#       }
#     );
#   portType = lib.types.either lib.types.port (
#     lib.types.submodule {
#       options = {
#         from = lib.mkOption {
#           type = lib.types.port;
#         };
#         to = lib.mkOption {
#           type = lib.types.port;
#         };
#         __toString = lib.mkOption {
#           type = lib.types.unspecified;
#           internal = true;
#           visible = false;
#         };
#       };
#       config = {
#         __toString = self: "${toString self.from}-${toString self.to}";
#       };
#     }
#   );
#   forwardType = lib.types.submodule (
#     { config, ... }: {
#       options = {
#         port = lib.mkOption {
#           type = portType;
#         };
#         targetPort = lib.mkOption {
#           type = portType;
#           default = config.port;
#         };
#         proto = lib.mkOption {
#           type = lib.types.enum [
#             "tcp"
#             "udp"
#           ];
#         };
#       }
#       // alib.types.netMatchOpts;
#     }
#   );
#   listenerType = lib.types.submodule {
#     options = {
#       openFirewall = lib.mkOption {
#         default = true;
#         type = lib.types.bool;
#       };
#       port = lib.mkOption {
#         type = lib.types.port;
#       };
#       proto = lib.mkOption {
#         type = lib.types.enum [
#           "tcp"
#           "udp"
#         ];
#       };
#     };
#   };
#   jailType =
#     { config, name, ... }:
#     let
#       host = alloy.hosts.${config.host};
#     in
#     {
#       options = {
#         id = lib.mkOption {
#           type = lib.types.str;
#           readOnly = true;
#           default = name;
#         };
#         idx = lib.mkOption {
#           type = lib.types.int;
#           readOnly = true;
#           default = alloy.indexes."jails".get name;
#         };
#         localIdx = lib.mkOption {
#           type = lib.types.int;
#           readOnly = true;
#         };
#         # name = lib.mkOption {
#         #   type = lib.types.str;
#         #   readOnly = true;
#         #   default = "alloy-jail-${config.id}";
#         # };
#         host = lib.mkOption {
#           type = lib.types.str;
#         };
#         # secrets = lib.mkOption {
#         #   default = { };
#         #   type = lib.types.attrsOf (secretType config);
#         # };
#         # volumes = lib.mkOption {
#         #   default = { };
#         #   type = lib.types.attrsOf (volumeType config);
#         # };
#         # nets = lib.mkOption {
#         #   default = { };
#         #   type = lib.types.attrsOf (netType host config);
#         # };
#         # forwards = lib.mkOption {
#         #   default = [ ];
#         #   type = lib.types.listOf forwardType;
#         # };
#         # listeners = lib.mkOption {
#         #   default = [ ];
#         #   type = lib.types.listOf listenerType;
#         # };
#         # uplink = {
#         #   allowEgress = lib.mkOption {
#         #     default = false;
#         #     type = lib.types.bool;
#         #   };
#         #   ipv4 = lib.mkOption {
#         #     type = lib.types.str;
#         #     readOnly = true;
#         #   };
#         #   ipv6 = lib.mkOption {
#         #     type = lib.types.str;
#         #     readOnly = true;
#         #   };
#         #   iface = lib.mkOption {
#         #     type = lib.types.str;
#         #     readOnly = true;
#         #     default = "al-v${toString config.idx}-0";
#         #   };
#         # };
#         nixpkgs = lib.mkOption {
#           type = lib.types.nullOr lib.types.path;
#           default = null;
#         };
#         nixosModule = lib.mkOption {
#           default = { };
#           type = lib.types.deferredModule;
#         };
#       };
#       config = {
#         # TODO: 1 <= localIdx <= 253
#         localIdx = lib.findFirstIndex (j: j.id == config.id) null (
#           lib.pipe alloy.jails [
#             builtins.attrValues
#             (lib.filter (j: j.host == config.host))
#             (lib.sort (a: b: a.id < b.id))
#           ]
#         );
#         uplink.ipv4 = "10.99.0.${toString (config.localIdx + 1)}";
#         uplink.ipv6 = "fd00:99::${toString (config.localIdx + 1)}";
#       };
#     };
#   mkjail =
#     host: jail:
#     let
#       volumeMounts = lib.mapAttrs' (
#         _: volume:
#         lib.nameValuePair "volume-${volume.id}" {
#           hostPath = alloy.volumes.${volume.id}.path;
#           mountPoint = volume.mountPoint;
#           isReadOnly = volume.readOnly;
#         }
#       ) jail.volumes;
#       secretMounts = lib.mapAttrs' (
#         _: secret:
#         lib.nameValuePair "secret-${secret.id}" {
#           hostPath = alloy.secrets.${secret.id}.path;
#           mountPoint = "/run/alloy/secrets-mounts/${secret.id}";
#           isReadOnly = true;
#         }
#       ) jail.secrets;
#       netMounts = lib.mapAttrs' (
#         _: net:
#         lib.nameValuePair "net-${net.id}" {
#           hostPath = alloy.secrets.${net.tls.secret}.path;
#           mountPoint = "/run/alloy/nets-mounts/${net.id}/tls";
#           isReadOnly = true;
#         }
#       ) jail.nets;
#       netExtraVeths = lib.mapAttrs' (
#         _: jailNet:
#         lib.nameValuePair jailNet.iface {
#           hostBridge = host.nets.${jailNet.id}.iface;
#         }
#       ) jail.nets;
#       defaultExtraVeth = {
#         ${jail.uplink.iface} = {
#           hostBridge = host.jails.uplink.iface;
#         };
#       };
#       host = alloy.hosts.${jail.host};
#     in
#     {
#       nftables.natPreroutingRules = lib.pipe jail.forwards [
#         (lib.map (
#           forward:
#           let
#             hasV4 = forward.ipv4 != null;
#             hasV6 = forward.ipv6 != null;
#             catchAll = !hasV4 && !hasV6;
#             ifaceMatch = lib.optionalString (forward.iface != null) "iifname \"${forward.iface}\"";
#             ruleV4 = lib.optionalString (hasV4 || catchAll) ''
#               ${ifaceMatch} ${lib.optionalString hasV4 "ip daddr ${forward.ipv4}"} ${forward.proto} dport ${toString forward.port} dnat ip to ${jail.uplink.ipv4}:${toString forward.targetPort}
#             '';
#             ruleV6 = lib.optionalString (hasV6 || catchAll) ''
#               ${ifaceMatch} ${lib.optionalString hasV6 "ip6 daddr ${forward.ipv6}"} ${forward.proto} dport ${toString forward.port} dnat ip6 to [${jail.uplink.ipv6}]:${toString forward.targetPort}
#             '';
#           in
#           "${ruleV4}${ruleV6}"
#         ))
#         (lib.concatStringsSep "")
#       ];

#       # TODO правило forward вида tcp dport 80 dnat ... перехватит весь локальный трафик хоста на порт 80
#       # nftables.natOutputRules = lib.pipe jail.forwards [
#       #   (lib.map (
#       #     forward:
#       #     let
#       #       hasV4 = forward.ipv4 != null;
#       #       hasV6 = forward.ipv6 != null;
#       #       catchAll = !hasV4 && !hasV6;
#       #       ruleV4 = lib.optionalString (hasV4 || catchAll) ''
#       #         ${lib.optionalString hasV4 "ip daddr ${forward.ipv4}"} ${forward.proto} dport ${toString forward.port} dnat ip to ${jail.uplink.ipv4}:${toString forward.targetPort}
#       #       '';
#       #       ruleV6 = lib.optionalString (hasV6 || catchAll) ''
#       #         ${lib.optionalString hasV6 "ip6 daddr ${forward.ipv6}"} ${forward.proto} dport ${toString forward.port} dnat ip6 to [${jail.uplink.ipv6}]:${toString forward.targetPort}
#       #       '';
#       #     in
#       #     "${ruleV4}${ruleV6}"
#       #   ))
#       #   (lib.concatStringsSep "")
#       # ];

#       nftables.forwardRules = ''
#         ${lib.concatMapStringsSep "\n" (forward: ''
#           ip daddr ${jail.uplink.ipv4} ${forward.proto} dport ${toString forward.targetPort} accept
#           ip6 daddr ${jail.uplink.ipv6} ${forward.proto} dport ${toString forward.targetPort} accept
#         '')}
#         ${lib.optionalString (!jail.uplink.allowEgress) ''
#           iifname ${host.jails.uplink.iface} ip  saddr ${jail.uplink.ipv4} ct state new drop
#           iifname ${host.jails.uplink.iface} ip6 saddr ${jail.uplink.ipv6} ct state new drop
#         ''}
#       '';

#       nftables.inputRules = ''
#         iifname "${host.jails.uplink.iface}" ip saddr ${jail.uplink.ipv4} udp dport 53 ${
#           if jail.uplink.allowEgress then "accept" else "drop"
#         }
#         iifname "${host.jails.uplink.iface}" ip6 saddr ${jail.uplink.ipv6} udp dport 53 ${
#           if jail.uplink.allowEgress then "accept" else "drop"
#         }
#       '';

#       nixosModule = { pkgs, ... }: {
#         systemd.network.networks = lib.mkMerge (
#           [ ]
#           ++ [
#             {
#               "10-${host.jails.uplink.iface}" = {
#                 matchConfig.Name = host.jails.uplink.iface;
#                 address = [
#                   "${host.jails.uplink.ipv4}/24"
#                   "${host.jails.uplink.ipv6}/64"
#                 ];
#                 networkConfig = {
#                   ConfigureWithoutCarrier = true;
#                 };
#               };
#               "10-${jail.uplink.iface}" = {
#                 matchConfig.Name = jail.uplink.iface;
#                 networkConfig.Bridge = host.jails.uplink.iface;
#                 bridgeConfig.Isolated = true;
#               };
#             }
#           ]
#           ++ (lib.flip lib.mapAttrsToList jail.nets (
#             _: jailNet: {
#               "10-${jailNet.iface}" = {
#                 matchConfig.Name = jailNet.iface;
#                 networkConfig.Bridge = host.nets.${jailNet.id}.iface;
#               };
#             }
#           ))
#         );

#           networking.useNetworkd = true;
#           systemd.network.enable = true;
#           networking.nftables.enable = true;

#         systemd.network.netdevs."10-${host.jails.uplink.iface}" = {
#           netdevConfig = {
#             Kind = "bridge";
#             Name = host.jails.uplink.iface;
#           };
#         };

#         systemd.services."alloy-jails-coredns" = {
#           description = "dns server for alloy jails";
#           after = [ "network.target" ];
#           wantedBy = [ "multi-user.target" ];
#           serviceConfig = {
#             ExecStart = "${pkgs.coredns}/bin/coredns -conf=${pkgs.writeText "alloy-jails-coredns" ''
#               .:53 {
#                 bind ${host.jails.uplink.ipv4} ${host.jails.uplink.ipv6}
#                 forward . /etc/resolv.conf
#                 cache 30
#               }
#             ''}";
#             ExecReload = "${pkgs.coreutils}/bin/kill -SIGUSR1 $MAINPID";
#             Restart = "on-failure";
#             RestartSec = "2s";
#             LimitNPROC = 512;
#             LimitNOFILE = 1048576;
#             DynamicUser = true;
#             AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
#             CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
#             ProtectSystem = "strict";
#             ProtectHome = true;
#             PrivateTmp = true;
#             PrivateDevices = true;
#             ProtectKernelTunables = true;
#             ProtectControlGroups = true;
#             RestrictNamespaces = true;
#           };
#         };

#         containers."${jail.name}" = {
#           bindMounts = volumeMounts // secretMounts // netMounts;
#           autoStart = true;
#           ephemeral = true;
#           privateUsers = "no";
#           extraVeths = netExtraVeths // defaultExtraVeth;
#           nixpkgs = lib.mkIf (jail.nixpkgs != null) jail.nixpkgs;
#           config = { ... }: {
#             imports = [
#               {
#                 nixpkgs.pkgs = lib.mkIf (jail.nixpkgs == null) pkgs;
#                 networking.useNetworkd = true;
#                 networking.useHostResolvConf = false;
#                 systemd.network.enable = true;
#                 services.resolved.enable = true;
#                 networking.firewall.interfaces = {
#                   ${jail.uplink.iface}.allowedUDPPorts = lib.pipe jail.forwards [
#                     (lib.filter (f: builtins.isInt f.targetPort && f.proto == "udp"))
#                     (lib.map (f: f.targetPort))
#                   ];
#                   ${jail.uplink.iface}.allowedUDPPortRages = lib.pipe jail.forwards [
#                     (lib.filter (f: builtins.isAttrs f.targetPort && f.proto == "udp"))
#                     (lib.map (f: f.targetPort))
#                   ];
#                   ${jail.uplink.iface}.allowedTCPPorts = lib.pipe jail.forwards [
#                     (lib.filter (f: builtins.isInt f.targetPort && f.proto == "tcp"))
#                     (lib.map (f: f.targetPort))
#                   ];
#                   ${jail.uplink.iface}.allowedTCPPortRages = lib.pipe jail.forwards [
#                     (lib.filter (f: builtins.isAttrs f.targetPort && f.proto == "tcp"))
#                     (lib.map (f: f.targetPort))
#                   ];
#                 }
#                 // (lib.pipe jail.nets [
#                   builtins.attrValues
#                   (lib.map (
#                     jailNet:
#                     lib.nameValuePair jailNet.iface {
#                       allowedUDPPorts = lib.pipe jail.listeners [
#                         (lib.filter (l: builtins.isInt l.port && l.proto == "udp"))
#                         (lib.map (f: f.port))
#                       ];
#                       allowedUDPPortRages = lib.pipe jail.forwards [
#                         (lib.filter (f: builtins.isAttrs f.port && f.proto == "udp"))
#                         (lib.map (f: f.port))
#                       ];
#                       allowedTCPPorts = lib.pipe jail.forwards [
#                         (lib.filter (f: builtins.isInt f.port && f.proto == "tcp"))
#                         (lib.map (f: f.port))
#                       ];
#                       allowedTCPPortRages = lib.pipe jail.forwards [
#                         (lib.filter (f: builtins.isAttrs f.port && f.proto == "tcp"))
#                         (lib.map (f: f.port))
#                       ];
#                     }
#                   ))
#                 ]);

#                 boot.kernel.sysctl = {
#                   "net.ipv6.ip_nonlocal_bind" = 1;
#                   "net.ipv4.ip_nonlocal_bind" = 1;
#                 };

#                 security.pki.certificateFiles =
#                   (lib.mapAttrsToList (_: jailNet: alloy.nets.${jailNet.id}.tls.certPath) jail.nets)
#                   ++ alloy.tls.pki.certificateFiles;
#                 system.activationScripts.setupjailSecrets = {
#                   deps = [
#                     "users"
#                     "groups"
#                   ];
#                   text = lib.concatMapAttrsStringSep "\n" (_: jailSecret: ''
#                     install -D \
#                       -m "${jailSecret.permissions.mode}" \
#                       -o "${jailSecret.permissions.owner}" \
#                       -g "${jailSecret.permissions.group}" \
#                       "/run/alloy/secrets-mounts/${jailSecret.id}" \
#                       "${jailSecret.mountPoint}"
#                   '') jail.secrets;
#                 };
#                 system.activationScripts.setupJailNetSecrets = {
#                   deps = [
#                     "users"
#                     "groups"
#                   ];
#                   text = lib.concatMapAttrsStringSep "\n" (_: jailNet: ''
#                     install -D \
#                       -m "${jailNet.tls.permissions.mode}" \
#                       -o "${jailNet.tls.permissions.owner}" \
#                       -g "${jailNet.tls.permissions.group}" \
#                       "/run/alloy/nets-mounts/${jailNet.id}/tls" \
#                       "${jailNet.tls.keyPath}"
#                   '') jail.nets;
#                 };

#                 systemd.network.networks = lib.mkMerge (
#                   [
#                     {
#                       "10-${jail.uplink.iface}" = {
#                         matchConfig.Name = jail.uplink.iface;
#                         address = [
#                           "${jail.uplink.ipv4}/24"
#                           "${jail.uplink.ipv6}/64"
#                         ];
#                         routes = [
#                           {
#                             Gateway = host.jails.uplink.ipv4;
#                           }
#                           {
#                             Gateway = host.jails.uplink.ipv6;
#                           }
#                         ];
#                         networkConfig = {
#                           DNS = [
#                             host.jails.uplink.ipv4
#                             host.jails.uplink.ipv6
#                           ];
#                         };
#                       };
#                     }
#                   ]
#                   ++ (lib.flip lib.mapAttrsToList jail.nets (
#                     _: jailNet:
#                     let
#                       net = alloy.nets.${jailNet.id};
#                       hostNet = host.nets.${net.id};
#                     in
#                     {
#                       "10-${jailNet.iface}" = {
#                         matchConfig.Name = jailNet.iface;
#                         address = [ "${jailNet.ipv6}/64" ];
#                         routes = [
#                           {
#                             Destination = "${net.ipv6Prefix}::/48";
#                             Gateway = hostNet.ipv6;
#                           }
#                         ];
#                         networkConfig = {
#                           DNS = [ hostNet.ipv6 ];
#                           Domains = [
#                             "~${net.dns.zone}"
#                             "~${net.dns.rzone}"
#                           ];
#                         };
#                       };
#                     }
#                   ))
#                 );
#               }
#               jail.nixosModule
#             ];
#           };
#         };
#       };
#     };
#   mkHost =
#     host:
#     let
#       jails = lib.map (c: mkjail host c) (
#         lib.filter (c: c.host == host.id) (builtins.attrValues alloy.jails)
#       );
#     in
#     {
#       nixosModule = { pkgs, ... }: {
#         imports = lib.map (c: c.nixosModule) jails;

#         networking.nftables.tables."alloy-jail-nat" = {
#           family = "inet";
#           content = ''
#             chain prerouting {
#               type nat hook prerouting priority dstnat; policy accept;
#               ${lib.concatMapStringsSep "\n" (c: c.nftables.natPreroutingRules) jails}
#             }
#             chain output {
#               type nat hook output priority dstnat; policy accept;
#               ${lib.concatMapStringsSep "\n" (c: c.nftables.natOutputRules) jails}
#             }
#             chain postrouting {
#               type nat hook postrouting priority srcnat; policy accept;
#               ip saddr 10.99.0.0/24 masquerade
#               ip6 saddr fd00:99::/64 masquerade
#             }
#           '';
#         };

#         networking.firewall.filterForward = true;
#         networking.firewall.extraForwardRules = ''
#           ${lib.concatMapStringsSep "\n" (c: c.nftables.forwardRules) jails}
#           iifname "al-br0" oifname != "al-*" accept
#         '';

#         networking.firewall.extraInputRules = ''
#           ${lib.concatMapStringsSep "\n" (c: c.nftables.inputRules) jails}
#         '';
#       };
#     };
# in
# {
#   options = {
#     jails = alib.extend jailType;
#     hosts = alib.extend (
#       { config, ... }:
#       let
#         host = config;
#       in
#       {
#         options.jails = {
#           uplink = {
#             iface = lib.mkOption {
#               type = lib.types.str;
#               readOnly = true;
#               default = "al-br0";
#             };
#             ipv4 = lib.mkOption {
#               type = lib.types.str;
#               readOnly = true;
#               default = "10.99.0.1";
#             };
#             ipv6 = lib.mkOption {
#               type = lib.types.str;
#               readOnly = true;
#               default = "fd00:99::1";
#             };
#           };
#         };
#         config.nixosModule = (mkHost host).nixosModule;
#       }
#     );
#   };

#   config = {
#     indexes."jails" = {
#       minValue = 1;
#       maxValue = 999;
#       items = lib.mapAttrs (_: _: { }) alloy.jails;
#     };
#     dns.records = lib.pipe alloy.jails [
#       (lib.mapAttrsToList (
#         _: jail:
#         lib.mapAttrsToList (_: jailNet: [
#           {
#             name = jailNet.dname;
#             type = "AAAA";
#             rdata = jailNet.ipv6;
#           }
#           {
#             name = alib.mkArpaIpv6 jailNet.ipv6;
#             type = "PTR";
#             rdata = jailNet.dname;
#           }
#         ]) jail.nets
#       ))
#       lib.flatten
#     ];
#     secrets = lib.pipe alloy.jails [
#       (lib.mapAttrsToList (
#         _: jail:
#         [ ]
#         ++ (lib.mapAttrsToList (_: jailSecret: {
#           ${jailSecret.id} = {
#             hosts = [ jail.host ];
#           };
#         }) jail.secrets)
#         ++ (lib.mapAttrsToList (_: jailNet: {
#           ${jailNet.tls.secret} = {
#             hosts = [ jail.host ];
#             generator.tls-x509-leaf = {
#               root = alloy.nets.${jailNet.id}.tls.secret;
#               subject = "Alloy ${jail.id} jail";
#               san.dnsNames = [ jailNet.dname ];
#               san.ipAddrs = [ { v6 = jailNet.ipv6; } ];
#             };
#           };
#         }) jail.nets)
#       ))
#       lib.flatten
#       lib.mkMerge
#     ];
#     volumes = lib.pipe alloy.jails [
#       (lib.mapAttrsToList (
#         _: jail:
#         lib.mapAttrsToList (_: jailVolume: {
#           ${jailVolume.id} = {
#             hosts = [ jail.host ];
#           };
#         }) jail.volumes
#       ))
#       lib.flatten
#       lib.mkMerge
#     ];
#     assertions =
#       [ ]
#       ++ (lib.pipe alloy.jails [
#         builtins.attrValues
#         (lib.map (
#           jail:
#           [
#             {
#               assertion = builtins.hasAttr jail.host alloy.hosts;
#               message = "alloy: jails: jail '${jail.id}' is deployed on host '${jail.host}', but this host is not defined.";
#             }
#           ]
#           ++ (lib.flatten (
#             lib.mapAttrsToList (_: volume: [
#               {
#                 assertion = builtins.hasAttr volume.id alloy.volumes;
#                 message = "alloy: jails: jail '${jail.id}' uses volume '${volume.id}', but this volume is not defined";
#               }
#             ]) jail.volumes
#           ))
#           ++ (lib.flatten (
#             lib.mapAttrsToList (_: secret: [
#               {
#                 assertion = builtins.hasAttr secret.id alloy.secrets;
#                 message = "alloy: jails: jail '${jail.id}' uses secret '${secret.id}', but this secret is not defined";
#               }
#             ]) jail.secrets
#           ))
#           ++ (lib.flatten (
#             lib.mapAttrsToList (_: network: [
#               {
#                 assertion = builtins.hasAttr network.id alloy.nets;
#                 message = "alloy: jails: jail '${jail.id}' connected to network '${network.id}', but this network is not defined";
#               }
#               {
#                 assertion = builtins.hasAttr network.id (alloy.hosts.${jail.host}.nets);
#                 message = "alloy: jails: jail '${jail.id}' is deployed on host '${jail.host}', but this host is not connected to network '${network.id}'";
#               }
#             ]) jail.nets
#           ))
#           ++ (lib.flatten (
#             lib.imap0 (forwardIdx: forward: [
#               {
#                 assertion =
#                   (builtins.isInt forward.port -> builtins.isInt forward.targetPort)
#                   || (builtins.isAttrs forward.port -> builtins.isAttrs forward.targetPort);
#                 message = "alloy: jail '${jail.id}': forward '${toString forwardIdx}': both port and targetPort must have the same type: either integer or { from, to } range";
#               }
#               {
#                 assertion = builtins.isAttrs forward.port -> forward.port.from <= forward.port.to;
#                 message = "alloy: jail '${jail.id}': forward '${toString forwardIdx}': port's 'from' must be less than or equal to port's 'to'";
#               }
#               {
#                 assertion = builtins.isAttrs forward.targetPort -> forward.targetPort.from <= forward.targetPort.to;
#                 message = "alloy: jail '${jail.id}': forward '${toString forwardIdx}': target ports's 'from' must be less than or equal to target ports's 'to'";
#               }
#               {
#                 assertion =
#                   (builtins.isAttrs forward.port && builtins.isAttrs forward.targetPort)
#                   -> (forward.port.to - forward.port.from) == (forward.targetPort.to - forward.targetPort.from);
#                 message = "alloy: jail '${jail.id}': forward '${toString forwardIdx}': both port and targetPort must have the same range with";
#               }
#             ]) jail.forwards
#           ))
#         ))
#         lib.flatten
#       ])
#       ++ (lib.pipe alloy.hosts [
#         builtins.attrValues
#         (lib.map (host: [
#           {
#             assertion = builtins.length (lib.filter (jail: jail.host == host.id) alloy.jails) <= 253;
#             message = "alloy: host '${host.id}': a host can serve no more than 253 jails";
#           }
#         ]))
#         lib.flatten
#       ])
#       ++ (lib.pipe alloy.nets [
#         builtins.attrValues
#         (lib.map (network: [
#           (
#             let
#               jails = lib.pipe alloy.jails [
#                 builtins.attrValues
#                 (lib.filter (jail: builtins.hasAttr network.id jail.nets))
#               ];
#               groups = lib.groupBy (jail: jail.nets.${network.id}.dlabel) jails;
#               collisions = lib.filterAttrs (_: jails: builtins.length jails > 1) groups;
#             in
#             {
#               assertion = collisions == { };
#               message = "alloy: network '${network.id}': jails dlabel collision detected, multiple jails share the same dlabel: [ ${
#                 lib.concatStringsSep "; " (
#                   lib.mapAttrsToList (
#                     dlabel: jails:
#                     let
#                       jailIds = lib.concatMapStringsSep ", " (jail: "'${jail.id}'") jails;
#                     in
#                     "${dlabel} is used by jails { ${jailIds} }"
#                   ) collisions
#                 )
#               } ]. Each jail must have a strictly unique dlabel per network.";
#             }
#           )
#         ]))
#         lib.flatten
#       ]);
#   };
# }
