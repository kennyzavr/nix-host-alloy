{
  alib,
  lib,
  config,
  ...
}:
let
  # TODO: keepalive
  alloy = config;

  overlayIndexes = alloy.facts."indexes/overlays".value;

  portRangeType = lib.types.submodule {
    options = {
      from = lib.mkOption {
        type = lib.types.port;
      };
      to = lib.mkOption {
        type = lib.types.port;
      };
    };
  };

  firewallType = lib.types.submodule (
    { config, ... }: {
      options = {
        allowedTCPPorts = lib.mkOption {
          default = [ ];
          type = lib.types.listOf lib.types.port;
        };
        allowedUDPPorts = lib.mkOption {
          default = [ ];
          type = lib.types.listOf lib.types.port;
        };
        allowedTCPPortRanges = lib.mkOption {
          default = [ ];
          type = lib.types.listOf portRangeType;
        };
        allowedUDPPortRanges = lib.mkOption {
          default = [ ];
          type = lib.types.listOf portRangeType;
        };
        extraInputRules = lib.mkOption {
          default = "";
          type = lib.types.lines;
        };
        inputRules = lib.mkOption {
          type = lib.types.functionTo lib.types.lines;
          readOnly = true;
          internal = true;
        };
      };

      config = {
        inputRules = prefix: ''
          ${lib.concatMapStringsSep "\n" (port: ''
            ${prefix} tcp dport ${toString port} accept
          '') config.allowedTCPPorts}

          ${lib.concatMapStringsSep "\n" (port: ''
            ${prefix} udp dport ${toString port} accept
          '') config.allowedUDPPorts}

          ${lib.concatMapStringsSep "\n" (range: ''
            ${prefix} tcp dport ${toString range.from}-${toString range.to} accept
          '') config.allowedTCPPortRanges}

          ${lib.concatMapStringsSep "\n" (range: ''
            ${prefix} udp dport ${toString range.from}-${toString range.to} accept
          '') config.allowedUDPPortRanges}

          ${lib.concatStringsSep "\n" (
            map (line: if line == "" then "" else "${prefix} ${line}") (
              lib.splitString "\n" config.extraInputRules
            )
          )}
        '';
      };
    }
  );

  overlaySubmodule =
    { config, name, ... }:
    {
      options = {
        idx = lib.mkOption {
          type = lib.types.ints.unsigned;
          readOnly = true;
          default = overlayIndexes.${name};
        };
        ipv6Prefix = lib.mkOption {
          type = lib.types.strMatching "^fd[0-9a-fA-F]{2}(:[0-9a-fA-F]{4}){2}$";
          default = "fdf2:82e2:${lib.fixedWidthString 4 "0" (lib.toHexString config.idx)}";
        };
        links = lib.mkOption {
          default = [ ];
          type = lib.types.listOf (lib.types.submodule overlayLinkSubmodule);
        };
        wg = {
          presharedKeySecret = lib.mkOption {
            type = lib.types.str;
            default = "overlays/${name}/wg/preshared.key";
          };
        };
      };
    };

  overlayLinkSubmodule =
    { config, name, ... }:
    {
      options = {
        id = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default =
            lib.pipe
              [
                config.a.host
                config.b.host
              ]
              [
                (builtins.sort builtins.lessThan)
                (lib.concatStringsSep "_")
              ];
        };
        a = {
          host = lib.mkOption {
            type = lib.types.str;
          };
          wg = {
            persistentKeepalive = lib.mkOption {
              default = null;
              type = lib.types.nullOr lib.types.ints.u16;
            };
          };
        };
        b = {
          host = lib.mkOption {
            type = lib.types.str;
          };
          wg = {
            persistentKeepalive = lib.mkOption {
              default = null;
              type = lib.types.nullOr lib.types.ints.u16;
            };
          };
        };
      };
    };

  hostOverlaySubmodule =
    host: hostName:
    { config, name, ... }:
    let
      overlay = alloy.overlays.${name};
    in
    {
      options = {
        ipv6Prefix = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = "${overlay.ipv6Prefix}:${lib.fixedWidthString 4 "0" (lib.toHexString host.idx)}";
        };
        ipv6 = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = "${config.ipv6Prefix}:0000:0000:0000:0001";
        };
        firewall = lib.mkOption {
          default = { };
          type = firewallType;
        };
        babeld = {
          localPort = lib.mkOption {
            type = lib.types.port;
            default = 33120 + overlay.idx;
          };
        };
        wg = {
          privateKeySecret = lib.mkOption {
            type = lib.types.str;
            default = "overlays/${name}/wg/${hostName}.key";
          };
          publicKeyFact = lib.mkOption {
            type = lib.types.str;
            default = "overlays/${name}/wg/${hostName}.key.pub";
          };
          port = lib.mkOption {
            type = lib.types.port;
            default = 52400 + overlay.idx;
          };
          endpoint = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
          };
        };
      };
    };

  jailOverlaySubmodule =
    jail: jailName:
    { config, name, ... }:
    let
      host = alloy.hosts.${jail.host};
    in
    {
      options = {
        ipv6 = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = "${host.overlays.${name}.ipv6Prefix}:0000:0000:000c:${
            lib.fixedWidthString 4 "0" (lib.toHexString jail.idx)
          }";
        };
        firewall = lib.mkOption {
          type = firewallType;
          default = { };
        };
      };
    };

  mkBridgeIface = overlay: "al-br${toString overlay.idx}";
  mkDummyIface = overlay: "al-d${toString overlay.idx}";
  mkWgIface = overlay: "al-wg${toString overlay.idx}";
  mkGreIface = overlay: host: "al-gre${toString overlay.idx}-${toString host.idx}";
  mkGenericGreIface = overlay: "al-gre${toString overlay.idx}-*";
  mkVethIface = overlay: jail: "al-v${toString jail.idx}-${toString overlay.idx}";

  mkOverlay =
    overlay: overlayName:
    [
      {
        generators.instances."overlays/${overlayName}/wg/psk" = {
          imports = [ alloy.generators.templates."wg/psk" ];
          privateKey = "overlays/${overlayName}/wg/preshared.key";
        };
      }
    ]
    ++ (lib.pipe alloy.hosts [
      (lib.filterAttrs (_: host: builtins.hasAttr overlayName host.overlays))
      (lib.mapAttrsToList (
        hostName: host: {
          generators.instances."overlays/${overlayName}/hosts/${hostName}/keypair" = {
            imports = [ alloy.generators.templates."wg/keypair" ];
            privateKey = "overlays/${overlayName}/wg/${hostName}.key";
            publicKey = "overlays/${overlayName}/wg/${hostName}.key.pub";
          };
        }
      ))
    ])
    ++ (lib.pipe overlay.links [
      (lib.map (
        link:
        let
          hostA = alloy.hosts.${link.a.host};
          hostB = alloy.hosts.${link.b.host};
        in
        {
          assertions = [
            {
              assertion = link.a.host != link.b.host;
              message = ''
                [Alloy] Invalid overlay link

                Overlay '${overlayName}' attempts to create a link where both ends point to the same host '${link.a.host}'.
                A link must connect two different hosts.
              '';
            }
            {
              assertion =
                hostA.overlays.${overlayName}.wg.endpoint != null
                || hostB.overlays.${overlayName}.wg.endpoint != null;
              message = ''
                [Alloy] Missing WireGuard endpoint for overlay link

                Overlay '${overlayName}' defines a link between host '${link.a.host}' and host '${link.b.host}'.
                At least one host in the link must have a defined WireGuard endpoint (cannot be null) 
                so they can establish a connection.
              '';
            }
          ];
        }
      ))
    ])
    ++ [
      {
        assertions = [
          {
            assertion = lib.length overlay.links == lib.length (lib.unique (map (l: l.id) overlay.links));
            message = ''
              [Alloy] Duplicate links in overlay

              Overlay '${overlayName}' contains multiple links between the same pair of hosts.
              Each pair of hosts can only have a single link defined between them in the overlay.
            '';
          }
        ];
      }
    ];

  mkHost =
    host: hostName:
    lib.flatten (
      lib.mapAttrsToList (
        overlayName: hostOverlay: mkHostOverlay host hostName hostOverlay overlayName
      ) host.overlays
    );

  mkHostOverlay =
    host: hostName: hostOverlay: overlayName:
    let
      overlay = alloy.overlays.${overlayName};
      bridgeIface = mkBridgeIface overlay;
      dummyIface = mkDummyIface overlay;
      wgIface = mkWgIface overlay;
      genericGreIface = mkGenericGreIface overlay;

      jails = lib.pipe alloy.jails [
        (lib.filterAttrs (_: jail: jail.host == hostName && builtins.hasAttr overlayName jail.overlays))
        (lib.mapAttrsToList (
          jailName: jail:
          let
            jailOverlay = jail.overlays.${overlayName};
            vethIface = mkVethIface overlay jail;
          in
          {
            systemd.network.networks."10-${vethIface}" = {
              matchConfig.Name = vethIface;
              networkConfig.Bridge = bridgeIface;
            };

            containers."alloy-jail-${jailName}" = {
              extraVeths.${vethIface} = {
                hostBridge = bridgeIface;
              };

              config = {
                networking.firewall.extraInputRules = jailOverlay.firewall.inputRules ''iifname "${vethIface}"'';

                systemd.network.networks."10-${vethIface}" = {
                  matchConfig.Name = vethIface;
                  address = [ "${jailOverlay.ipv6}/64" ];
                  routes = [
                    {
                      Destination = "${overlay.ipv6Prefix}::/48";
                      Gateway = hostOverlay.ipv6;
                    }
                  ];
                };
              };
            };
          }
        ))
      ];

      links = lib.pipe overlay.links [
        (lib.filter (l: l.a.host == hostName || l.b.host == hostName))
        (lib.map (
          link:
          let
            isA = link.a.host == hostName;
            thisNode = if isA then link.a else link.b;
            peerNode = if isA then link.b else link.a;
            peerHostName = peerNode.host;
            peerHost = alloy.hosts.${peerHostName};
            peerHostOverlay = peerHost.overlays.${overlayName};

            greIface = mkGreIface overlay peerHost;
            minIdx = if host.idx < peerHost.idx then host.idx else peerHost.idx;
            maxIdx = if host.idx < peerHost.idx then peerHost.idx else host.idx;

            linkSubnet = "${overlay.ipv6Prefix}:0000:0001:${
              lib.fixedWidthString 4 "0" (lib.toHexString minIdx)
            }:${lib.fixedWidthString 4 "0" (lib.toHexString maxIdx)}";

            thisWgIpv6 = "${linkSubnet}:${if host.idx == minIdx then "1" else "2"}";
            peerWgIpv6 = "${linkSubnet}:${if peerHost.idx == minIdx then "1" else "2"}";
          in
          {
            systemd.network.netdevs."10-${wgIface}" = {
              wireguardPeers = [
                {
                  PublicKey = alloy.facts.${peerHostOverlay.wg.publicKeyFact}.value;
                  PresharedKeyFile = host.secrets.${overlay.wg.presharedKeySecret}.path;
                  AllowedIPs = "${peerWgIpv6}/128";
                  Endpoint = lib.mkIf (
                    peerHostOverlay.wg.endpoint != null
                  ) "${peerHostOverlay.wg.endpoint}:${toString peerHostOverlay.wg.port}";
                  # PersistentKeepalive = lib.mkIf (
                  #   thisNode.wg.persistentKeepalive != null
                  # ) thisNode.wg.persistentKeepalive;
                }
              ];
            };
            systemd.network.networks."10-${wgIface}" = {
              addresses = [
                {
                  Address = "${thisWgIpv6}/128";
                  PreferredLifetime = "0";
                }
              ];
              routes = [
                {
                  Destination = "${peerWgIpv6}/128";
                }
              ];
            };

            systemd.network.netdevs."10-${greIface}" = {
              netdevConfig = {
                Kind = "ip6gre";
                Name = greIface;
                MTUBytes = "1372";
              };
              tunnelConfig = {
                Local = thisWgIpv6;
                Remote = peerWgIpv6;
                Independent = true;
              };
            };
            systemd.network.networks."10-${greIface}" = {
              matchConfig = {
                Name = greIface;
              };
              networkConfig = {
                LinkLocalAddressing = "ipv6";
                IPv6Forwarding = true;
              };
              linkConfig = {
                ActivationPolicy = "up";
              };
            };

            networking.firewall.extraInputRules = ''
              iifname "${greIface}" udp dport 6696 accept 
              ${hostOverlay.firewall.inputRules ''iifname "${greIface}"''}
            '';

            environment.etc."alloy/overlays/${overlayName}/babeld/config".text = lib.mkAfter ''
              interface ${greIface} type tunnel
              interface ${greIface} link-quality true

              in  if ${greIface} ip ${overlay.ipv6Prefix}::/48 eq 64 allow
              out if ${greIface} ip ${overlay.ipv6Prefix}::/48 eq 64 allow
              in  if ${greIface} deny
              out if ${greIface} deny
            '';
          }
        ))
      ];
    in
    {
      secrets.${overlay.wg.presharedKeySecret} = {
        permissions = {
          owner = "systemd-network";
          group = "systemd-network";
          mode = "0640";
        };
      };

      secrets.${hostOverlay.wg.privateKeySecret} = {
        permissions = {
          owner = "systemd-network";
          group = "systemd-network";
          mode = "0640";
        };
      };

      nixosModule =
        { config, pkgs, ... }:
        {
          imports = [ ] ++ links ++ jails;

          systemd.network.netdevs."10-${wgIface}" = {
            netdevConfig = {
              Kind = "wireguard";
              Name = wgIface;
            };
            wireguardConfig = {
              PrivateKeyFile = host.secrets.${hostOverlay.wg.privateKeySecret}.path;
              ListenPort = hostOverlay.wg.port;
            };
          };
          systemd.network.networks."10-${wgIface}" = {
            matchConfig.Name = wgIface;
          };

          systemd.network.netdevs."10-${bridgeIface}" = {
            netdevConfig = {
              Kind = "bridge";
              Name = bridgeIface;
            };
          };
          systemd.network.networks."10-${bridgeIface}" = {
            matchConfig = {
              Name = bridgeIface;
            };
            address = [ "${hostOverlay.ipv6}/64" ];
            networkConfig = {
              IPv6Forwarding = true;
            };
          };

          systemd.network.netdevs."10-${dummyIface}" = {
            netdevConfig = {
              Kind = "dummy";
              Name = dummyIface;
            };
          };
          systemd.network.networks."10-${dummyIface}" = {
            matchConfig = {
              Name = dummyIface;
            };
            networkConfig = {
              Bridge = bridgeIface;
            };
          };

          networking.firewall.allowedUDPPorts = [ hostOverlay.wg.port ];
          networking.firewall.filterForward = true;
          networking.firewall.extraForwardRules = ''
            iifname "${genericGreIface}" oifname "${genericGreIface}" accept
            iifname "${genericGreIface}" oifname "${bridgeIface}" accept
            iifname "${bridgeIface}" oifname "${genericGreIface}" accept
          '';
          networking.firewall.extraReversePathFilterRules = ''
            iifname "${genericGreIface}" accept
          '';
          networking.firewall.extraInputRules = ''
            iifname "${wgIface}" meta l4proto gre accept
          '';

          environment.etc."alloy/overlays/${overlayName}/babeld/config".text = lib.mkBefore ''
            skip-kernel-setup true

            local-port ${toString hostOverlay.babeld.localPort}
            protocol-port 6696

            redistribute ip ${hostOverlay.ipv6Prefix}::/64 allow
            redistribute deny
          '';

          systemd.services."alloy-overlay-${overlayName}-babeld" = {
            description = "Babel routing daemon for alloy overlay ${overlayName}";
            after = [ "network.target" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              ExecStart = "${pkgs.babeld}/bin/babeld -I /run/alloy/overlays/${overlayName}/babeld/babeld.pid -S /var/lib/alloy/overlays/${overlayName}/babeld/state -c /etc/alloy/overlays/${overlayName}/babeld/config";
              AmbientCapabilities = [ "CAP_NET_ADMIN" ];
              CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
              DevicePolicy = "closed";
              DynamicUser = true;
              IPAddressAllow = [
                "fe80::/64"
                "ff00::/8"
                "::1/128"
                "127.0.0.0/8"
              ];
              IPAddressDeny = "any";
              LockPersonality = true;
              NoNewPrivileges = true;
              MemoryDenyWriteExecute = true;
              ProtectSystem = "strict";
              ProtectClock = true;
              ProtectKernelTunables = true;
              ProtectKernelModules = true;
              ProtectKernelLogs = true;
              ProtectControlGroups = true;
              RestrictAddressFamilies = [
                "AF_NETLINK"
                "AF_INET6"
                "AF_INET"
              ];
              RestrictNamespaces = true;
              RestrictRealtime = true;
              RestrictSUIDSGID = true;
              RemoveIPC = true;
              ProtectHome = true;
              ProtectHostname = true;
              ProtectProc = "invisible";
              PrivateMounts = true;
              PrivateTmp = true;
              PrivateDevices = true;
              PrivateUsers = false;
              ProcSubset = "pid";
              SystemCallArchitectures = "native";
              SystemCallFilter = [
                "@system-service"
                "~@privileged @resources"
              ];
              UMask = "0177";
              RuntimeDirectory = "alloy/overlays/${overlayName}/babeld";
              StateDirectory = "alloy/overlays/${overlayName}/babeld";
            };
          };
        };
    };
in
{
  options = {
    overlays = lib.mkOption {
      default = { };
      type = lib.types.attrsOf (lib.types.submodule overlaySubmodule);
    };

    hosts = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { config, name, ... }: {
            options = {
              overlays = lib.mkOption {
                default = { };
                type = lib.types.attrsOf (lib.types.submodule (hostOverlaySubmodule config name));
              };
            };
            config =
              let
                overlayConfigs = mkHost config name;
              in
              {
                secrets = lib.mkMerge (lib.catAttrs "secrets" overlayConfigs);
                nixosModule = lib.mkMerge (lib.catAttrs "nixosModule" overlayConfigs);
              };
          }
        )
      );
    };

    jails = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { config, name, ... }:
          let
            host = alloy.hosts.${config.host} or null;
          in
          {
            options = {
              overlays = lib.mkOption {
                default = { };
                type = lib.types.attrsOf (lib.types.submodule (jailOverlaySubmodule config name));
              };
            };
            config = {
              assertions = lib.mapAttrsToList (overlayName: overlay: {
                assertion = host != null -> builtins.hasAttr overlayName host.overlays;
                message = ''
                  [Alloy] Missing host overlay for jail

                  Jail '${name}' uses overlay '${overlayName}', but its target host '${config.host}' 
                  does not participate in this overlay.

                  To fix this, add the overlay '${overlayName}' to the host '${config.host}' configuration.
                '';
              }) config.overlays;
            };
          }
        )
      );
    };
  };

  config =
    let
      overlayConfigs = lib.flatten (
        lib.mapAttrsToList (overlayName: overlay: mkOverlay overlay overlayName) alloy.overlays
      );
    in
    {
      assertions = lib.flatten (builtins.catAttrs "assertions" overlayConfigs);

      generators = lib.mkMerge [
        (lib.mkMerge (builtins.catAttrs "generators" overlayConfigs))
        {
          instances."indexes/overlays" = {
            imports = [ alloy.generators.templates."index" ];
            name = "indexes/overlays";
            minValue = 1;
            maxValue = 99;
            keys = builtins.attrNames alloy.overlays;
          };

          templates."wg/psk" = { config, lib, ... }: {
            options = {
              privateKey = lib.mkOption { type = lib.types.str; };
            };
            config = {
              packages = { pkgs, ... }: [ pkgs.wireguard-tools ];
              secrets.${config.privateKey} = { };
              script = ''
                import subprocess
                if not AlloySecretsAPI.exists("${config.privateKey}") or getattr(args, "force", False):
                    new_key = subprocess.run(["wg", "genpsk"], capture_output=True, text=True, check=True).stdout.strip()
                    AlloySecretsAPI.set("${config.privateKey}", new_key.encode(), force=getattr(args, "force", False), add_to_git=getattr(args, "add_to_git", False))
                else:
                    CLI.skip("Secret '${config.privateKey}' already exists. Use --force to overwrite.")
              '';
            };
          };

          templates."wg/keypair" = { config, lib, ... }: {
            options = {
              privateKey = lib.mkOption { type = lib.types.str; };
              publicKey = lib.mkOption { type = lib.types.str; };
            };
            config = {
              packages = { pkgs, ... }: [ pkgs.wireguard-tools ];
              secrets.${config.privateKey} = { };
              facts.${config.publicKey}.type = lib.types.str;
              script = ''
                import subprocess

                needs_generation = getattr(args, "force", False)
                if not AlloySecretsAPI.exists("${config.privateKey}"):
                    needs_generation = True
                if not AlloyFactsAPI.exists("${config.publicKey}"):
                    needs_generation = True
                    
                if needs_generation:
                    priv_key = subprocess.run(["wg", "genkey"], capture_output=True, text=True, check=True).stdout.strip()
                    pub_key = subprocess.run(["wg", "pubkey"], input=priv_key, capture_output=True, text=True, check=True).stdout.strip()
                    
                    AlloySecretsAPI.set("${config.privateKey}", priv_key.encode(), force=True, add_to_git=getattr(args, "add_to_git", False))
                    AlloyFactsAPI.set("${config.publicKey}", f'"{pub_key}"', force=True, add_to_git=getattr(args, "add_to_git", False))
                else:
                    CLI.skip("Keys '${config.privateKey}' and '${config.publicKey}' already exist. Use --force to overwrite.")
              '';
            };
          };
        }
      ];
    };
}
