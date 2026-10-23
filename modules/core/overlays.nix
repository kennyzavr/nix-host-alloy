{ withSystem, ... }: {
  flake.alloyModules.core =
    {
      alib,
      lib,
      config,
      ...
    }:
    let
      alloy = config;

      portRangeType = lib.types.submodule {
        options = {
          from = lib.mkOption {
            type = lib.types.port;
            description = "First port in the forwarded range, inclusive.";
          };
          to = lib.mkOption {
            type = lib.types.port;
            description = "Last port in the forwarded range, inclusive.";
          };
        };
      };

      firewallType = lib.types.submodule (
        { config, ... }: {
          options = {
            allowedTCPPorts = lib.mkOption {
              default = [ ];
              type = lib.types.listOf lib.types.port;
              description = "TCP ports accepted by the overlay firewall.";
            };
            allowedUDPPorts = lib.mkOption {
              default = [ ];
              type = lib.types.listOf lib.types.port;
              description = "UDP ports accepted by the overlay firewall.";
            };
            allowedTCPPortRanges = lib.mkOption {
              default = [ ];
              type = lib.types.listOf portRangeType;
              description = "TCP port ranges accepted by the overlay firewall.";
            };
            allowedUDPPortRanges = lib.mkOption {
              default = [ ];
              type = lib.types.listOf portRangeType;
              description = "UDP port ranges accepted by the overlay firewall.";
            };
            extraInputRules = lib.mkOption {
              default = "";
              type = lib.types.lines;
              description = "Additional nftables input-rule statements appended to the generated overlay firewall rules.";
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
              default = alloy.indexes."overlays".get name;
            };
            ipv6Prefix = lib.mkOption {
              type = lib.types.strMatching "^fd[0-9a-fA-F]{2}(:[0-9a-fA-F]{4}){2}$";
              default = "fdf2:82e2:${lib.fixedWidthString 4 "0" (lib.toLower (lib.toHexString config.idx))}";
              description = "IPv6 /48 prefix allocated to this overlay; host and jail addresses are derived from it.";
            };
            links = lib.mkOption {
              default = [ ];
              type = lib.types.listOf (lib.types.submodule overlayLinkSubmodule);
              description = "WireGuard links connecting pairs of hosts in this overlay.";
            };
            tags = lib.mkOption {
              default = [ ];
              type = lib.types.listOf lib.types.str;
              description = "Labels used to select or group this overlay in CLI operations.";
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
              description = "Stable identifier derived from the sorted names of the link's two hosts.";
            };
            a = {
              host = lib.mkOption {
                type = lib.types.str;
                description = "Host at this end of the WireGuard link.";
              };
              wg = {
                persistentKeepalive = lib.mkOption {
                  default = 0;
                  type = lib.types.ints.u16;
                  description = "WireGuard persistent keepalive interval in seconds for this link peer.";
                };
              };
            };
            b = {
              host = lib.mkOption {
                type = lib.types.str;
                description = "Host at this end of the WireGuard link.";
              };
              wg = {
                persistentKeepalive = lib.mkOption {
                  default = 0;
                  type = lib.types.ints.u16;
                  description = "WireGuard persistent keepalive interval in seconds for this link peer.";
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
              default = "${overlay.ipv6Prefix}:${
                lib.fixedWidthString 4 "0" (lib.toLower (lib.toHexString host.idx))
              }";
            };
            ipv6 = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              default = "${config.ipv6Prefix}:0000:0000:0000:0001";
            };
            firewall = lib.mkOption {
              default = { };
              type = firewallType;
              description = "Firewall rules for traffic entering this host through the overlay.";
            };
            babeld = {
              localPort = lib.mkOption {
                type = lib.types.port;
                default = 33120 + overlay.idx;
                description = "Babel daemon port used by this host on the overlay.";
              };
            };
            wg = {
              port = lib.mkOption {
                type = lib.types.port;
                default = 52400 + overlay.idx;
                description = "Local WireGuard listen port for this host on the overlay.";
              };
              endpoint = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                description = "Publicly reachable WireGuard endpoint for this host, or null when it accepts connections only.";
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
                lib.fixedWidthString 4 "0" (lib.toLower (lib.toHexString jail.idx))
              }";
            };
            firewall = lib.mkOption {
              type = firewallType;
              default = { };
            };
          };
        };

      endpointSubmodule = { config, ... }: {
        options = {
          targets = lib.mkOption {
            type = lib.types.uniq (lib.types.listOf (lib.types.submodule endpointTargetSubmodule));
          };
          overlays = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule { });
            readOnly = true;
          };
        };
        config = {
          overlays = lib.pipe config.targets [
            (lib.filter (target: target.overlay != null))
            (lib.map (target: target.overlay))
            lib.unique
            (lib.map (overlay: lib.nameValuePair overlay { }))
            builtins.listToAttrs
          ];
        };
      };

      endpointTargetSubmodule = {
        options.overlay = lib.mkOption {
          default = null;
          type = lib.types.nullOr lib.types.str;
          description = "Overlay for this target; set only for IPv6 addresses in that overlay. Null denotes a direct address, including IPv4.";
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
        let
          pskSecret = "overlay/${overlayName}/wg/preshared.key";
          pskGen = "overlay/${overlayName}/wg/preshared-key";
        in
        [
          {
            secrets.${pskSecret} = { };

            generators.instances.${pskGen} = {
              tags = [
                "overlay"
                "overlay/${overlayName}"
              ];
              secrets.${pskSecret} = { };
              package =
                { system, ... }:
                let
                  pkgs = withSystem system ({ pkgs, ... }: pkgs);
                in
                pkgs.writeShellApplication {
                  name = "wg-psk-generator";
                  runtimeInputs = [ pkgs.wireguard-tools ];
                  text = ''
                    preshared_key=$(wg genpsk)
                    "$ALLOY_BIN" secrets set "${pskSecret}" <<< "$preshared_key"
                  '';
                };
            };
          }
        ]
        ++ (lib.pipe alloy.hosts [
          (lib.filterAttrs (_: host: builtins.hasAttr overlayName host.overlays))
          (lib.mapAttrsToList (
            hostName: host:
            let
              privKeySecret = "overlay/${overlayName}/wg/hosts/${hostName}.key";
              pubKeyFact = "overlay/${overlayName}/wg/hosts/${hostName}.key.pub";
              keysGen = "overlay/${overlayName}/wg/hosts/${hostName}";
            in
            {
              secrets.${privKeySecret} = { };
              facts.${pubKeyFact} = { };

              generators.instances.${keysGen} = {
                tags = [
                  "overlay"
                  "overlay/${overlayName}"
                ]
                ++ host.tags;
                secrets.${privKeySecret} = { };
                facts.${pubKeyFact} = { };
                package =
                  { system, ... }:
                  let
                    pkgs = withSystem system ({ pkgs, ... }: pkgs);
                  in
                  pkgs.writeShellApplication {
                    name = "wg-keypair-generator";
                    runtimeInputs = [ pkgs.wireguard-tools ];
                    text = ''
                      priv_key=$(wg genkey) 
                      pub_key=$(wg pubkey <<< "$priv_key")

                      "$ALLOY_BIN" secrets set "${privKeySecret}" <<< "$priv_key"
                      "$ALLOY_BIN" facts set "${pubKeyFact}" <<< "$pub_key"
                    '';
                  };
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
                  message = "[Alloy] Overlay '${overlayName}', link '${link.id}': Both ends refer to host '${link.a.host}'. A link must connect two different hosts.";
                }
                {
                  assertion =
                    hostA.overlays.${overlayName}.wg.endpoint != null
                    || hostB.overlays.${overlayName}.wg.endpoint != null;
                  message = "[Alloy] Overlay '${overlayName}', link '${link.id}': Hosts '${link.a.host}' and '${link.b.host}' both lack a WireGuard endpoint. Set an endpoint on at least one host so they can establish a connection.";
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
                message = "[Alloy] Overlay '${overlayName}': Multiple links connect the same pair of hosts. Define only one link for each host pair.";
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
                  lib.fixedWidthString 4 "0" (lib.toLower (lib.toHexString minIdx))
                }:${lib.fixedWidthString 4 "0" (lib.toLower (lib.toHexString maxIdx))}";

                thisWgIpv6 = "${linkSubnet}:${if host.idx == minIdx then "1" else "2"}";
                peerWgIpv6 = "${linkSubnet}:${if peerHost.idx == minIdx then "1" else "2"}";
              in
              {
                systemd.network.netdevs."10-${wgIface}" = {
                  wireguardPeers = [
                    {
                      PublicKey = alloy.facts."overlay/${overlayName}/wg/hosts/${peerHostName}.key.pub".value;
                      PresharedKeyFile = host.secrets."overlay/${overlayName}/wg/preshared.key".path;
                      AllowedIPs = "${peerWgIpv6}/128";
                      Endpoint = lib.mkIf (
                        peerHostOverlay.wg.endpoint != null
                      ) "${peerHostOverlay.wg.endpoint}:${toString peerHostOverlay.wg.port}";
                      PersistentKeepalive = thisNode.wg.persistentKeepalive;
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
          secrets."overlay/${overlayName}/wg/preshared.key" = {
            permissions = {
              owner = "systemd-network";
              group = "systemd-network";
              mode = "0640";
            };
          };

          secrets."overlay/${overlayName}/wg/hosts/${hostName}.key" = {
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
                  PrivateKeyFile = host.secrets."overlay/${overlayName}/wg/hosts/${hostName}.key".path;
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
          description = "Named private network overlays connecting hosts and jails.";
        };

        mkEndpointOverlaysWarn = lib.mkOption {
          readOnly = true;
          type = lib.types.unspecified;
        };

        endpoints = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule endpointSubmodule);
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
                    message = "[Alloy] Jail '${name}': Overlay '${overlayName}' is not configured on host '${config.host}'. Add it to `hosts.${config.host}.overlays`.";
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
          mkEndpointOverlaysWarn =
            endpointName: allowedOverlays: contextMsg:
            let
              endpoint = alloy.endpoints.${endpointName};
              invalidTargets = lib.pipe endpoint.targets [
                (lib.imap0 (idx: target: { inherit idx target; }))
                (lib.filter (
                  { idx, target }: target.overlay != null && !(builtins.elem target.overlay allowedOverlays)
                ))
              ];
            in
            {
              condition = allowedOverlays != null -> invalidTargets == [ ];
              message =
                lib.optionalString (allowedOverlays != null)
                  "[Alloy] ${contextMsg} Endpoint '${endpointName}' has targets on overlays outside the allowed set. Allowed overlays: [ ${lib.concatStringsSep ", " allowedOverlays} ]. Invalid targets: [ ${
                    lib.concatMapStringsSep ", " (
                      { idx, target }:
                      ''${toString idx}: { overlay = "${target.overlay}"; ip = "${target.ip.v6 or target.ip.v4}"; } ''
                    ) invalidTargets
                  } ].";
            };

          assertions =
            [ ]
            ++ (lib.flatten (builtins.catAttrs "assertions" overlayConfigs))
            ++ (lib.pipe alloy.endpoints [
              (lib.mapAttrsToList (
                endpointName: endpoint:
                lib.imap1 (i: target: [
                  {
                    assertion = target.overlay != null -> builtins.hasAttr target.overlay alloy.overlays;
                    message = "[Alloy] Endpoint '${endpointName}', target #${toString i}: Overlay '${target.overlay}' is not defined in `overlays`.";
                  }
                  {
                    assertion =
                      builtins.hasAttr "v6" target.ip
                      -> target.overlay != null
                      -> builtins.hasAttr target.overlay alloy.overlays
                      -> lib.hasPrefix alloy.overlays.${target.overlay}.ipv6Prefix target.ip.v6;
                    message = "[Alloy] Endpoint '${endpointName}', target #${toString i}: IPv6 address '${target.ip.v6}' is outside overlay '${target.overlay}' prefix '${
                      alloy.overlays.${target.overlay}.ipv6Prefix
                    }'.";
                  }
                  {
                    assertion = target.overlay != null -> !(builtins.hasAttr "v4" target.ip);
                    message = "[Alloy] Endpoint '${endpointName}', target #${toString i}: Targets in overlay '${target.overlay}' must use IPv6. Set an address in the overlay's IPv6 prefix.";
                  }
                ]) endpoint.targets
              ))
              lib.flatten
            ]);

          indexes."overlays" = {
            minValue = 1;
            maxValue = 99;
            keys = builtins.attrNames alloy.overlays;
          };

          secrets = lib.mkMerge (builtins.catAttrs "secrets" overlayConfigs);
          facts = lib.mkMerge (builtins.catAttrs "facts" overlayConfigs);

          generators = lib.mkMerge (builtins.catAttrs "generators" overlayConfigs);
        };
    };
}
