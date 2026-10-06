{
  flake.alloyModules.services =
    {
      alib,
      lib,
      config,
      ...
    }:
    let
      alloy = config;

      hostSubmodule = { config, name, ... }: {
        options.net = lib.mkOption {
          default = alloy.hosts.${name}.primaryNet;
          type = lib.types.str;
        };
      };

      routeSubmodule = { name, ... }: {
        options = {
          zone = lib.mkOption {
            default = name;
            type = lib.types.str;
          };
          upstream = {
            endpoint = lib.mkOption {
              type = lib.types.str;
            };
          };
        };
      };

      serviceSubmodule = { config, name, ... }: {
        options = {
          enable = lib.mkOption {
            default = true;
            type = lib.types.bool;
          };
          allowedOverlays = lib.mkOption {
            default = null;
            type = lib.types.nullOr (lib.types.listOf lib.types.str);
            apply =
              allowedOverlays:
              if allowedOverlays != null then
                lib.pipe config.routes [
                  (lib.mapAttrsToList (routeName: route: { inherit routeName route; }))
                  (lib.foldl (
                    overlays:
                    { routeName, route }:
                    alloy.checkEndpointOverlays "Service dns-edge '${name}': route '${routeName}':"
                      route.upstream.endpoint
                      overlays
                  ) allowedOverlays)
                  lib.unique
                ]
              else
                lib.pipe config.routes [
                  (lib.mapAttrsToList (
                    _: route: builtins.attrNames alloy.endpoints.${route.upstream.endpoint}.overlays
                  ))
                  lib.flatten
                  lib.unique
                ];
          };
          hosts = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
          };
          routes = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (lib.types.submodule routeSubmodule);
          };
        };
      };

      mkService =
        srvName: srv:
        let
          sortedRoutes = lib.pipe srv.routes [
            (lib.mapAttrsToList (name: route: route // { inherit name; }))
            (lib.imap (idx: route: route // { inherit idx; }))
            (builtins.sort (
              a: b:
              builtins.stringLength alloy.dns.zones.${a.zone}.apex
              > builtins.stringLength alloy.dns.zones.${b.zone}.apex
            ))
          ];
        in
        {
          assertions = [
            {
              assertion = srv.hosts != { };
              message = "[Alloy] dns-edge '${srvName}': at least one host must be specified";
            }
          ]
          ++ (lib.flatten (
            lib.mapAttrsToList (hostName: hostCfg: [
              {
                assertion = builtins.hasAttr hostName alloy.hosts;
                message = "[Alloy] dns-edge '${srvName}': host '${hostName}' is unknown";
              }
            ]) srv.hosts
          ));

          dns.zones = lib.mapAttrs' (
            _: route:
            lib.nameValuePair route.zone {
              nname = "ns1";
              nameservers = lib.flatten (
                lib.mapAttrsToList (
                  hostName: hostCfg:
                  let
                    host = alloy.hosts.${hostName};
                    hostNet = host.nets.${hostCfg.net};
                  in
                  [ ]
                  ++ (lib.optional (hostNet.v4 != null) hostNet.v4.address)
                  ++ (lib.optional (hostNet.v6 != null) hostNet.v6.address)
                ) srv.hosts
              );
            }
          ) srv.routes;

          dns.records = lib.flatten (
            lib.map (
              route:
              (lib.imap0 (
                hostIdx:
                { hostName, hostCfg }:
                let
                  host = alloy.hosts.${hostName};
                  hostNet = host.nets.${hostCfg.net};
                  nsPrefix = "ns${toString hostIdx}";
                  parentZone = alloy.dns.zones.${route.zone}.parentZone;
                  zoneApex = lib.removeSuffix "." alloy.dns.zones.${route.zone}.apex;
                  parentZoneApex = lib.removeSuffix "." alloy.dns.zones.${parentZone}.apex;
                  subzone = lib.removeSuffix ".${parentZoneApex}" zoneApex;
                in
                [
                  {
                    domain = {
                      zone = route.zone;
                      name = "@";
                    };
                    data.ns = nsPrefix;
                  }
                ]
                ++ (lib.optional (parentZone != null) {
                  domain = {
                    zone = parentZone;
                    name = subzone;
                  };
                  data.ns = "${nsPrefix}.${subzone}";
                })
                ++ (lib.optional (hostNet.v4 != null) {
                  domain = {
                    zone = route.zone;
                    name = nsPrefix;
                  };
                  data.a = hostNet.v4.address;
                })
                ++ (lib.optional (parentZone != null && hostNet.v4 != null) {
                  domain = {
                    zone = parentZone;
                    name = "${nsPrefix}.${subzone}";
                  };
                  data.a = hostNet.v4.address;
                })
                ++ (lib.optional (hostNet.v6 != null) {
                  domain = {
                    zone = route.zone;
                    name = nsPrefix;
                  };
                  data.aaaa = hostNet.v6.address;
                })
                ++ (lib.optional (parentZone != null && hostNet.v6 != null) {
                  domain = {
                    zone = parentZone;
                    name = "${nsPrefix}.${subzone}";
                  };
                  data.aaaa = hostNet.v6.adress;
                })
              ) (lib.mapAttrsToList (hostName: hostCfg: { inherit hostName hostCfg; }) srv.hosts))
            ) sortedRoutes
          );

          jails = lib.mapAttrs' (
            hostName: hostCfg:
            let
              host = alloy.hosts.${hostName};
              hostNet = host.nets.${hostCfg.net};
            in
            lib.nameValuePair "dns-edge-${hostName}" (
              { config, ... }:
              let
                jail = config;
              in
              {
                host = hostName;

                tags = [
                  "dns-edge"
                  "dns-edge/${srvName}"
                ];

                uplink.forwards =
                  (lib.optionals (hostNet.v4 != null) [
                    {
                      proto = "tcp";
                      port = 53;
                      inherit (hostNet) iface;
                      ip.v4 = hostNet.v4.address;
                    }
                    {
                      proto = "udp";
                      port = 53;
                      inherit (hostNet) iface;
                      ip.v4 = hostNet.v4.address;
                    }
                  ])
                  ++ (lib.optionals (hostNet.v6 != null) [
                    {
                      proto = "tcp";
                      port = 53;
                      inherit (hostNet) iface;
                      ip.v6 = hostNet.v6.address;
                    }
                    {
                      proto = "udp";
                      port = 53;
                      inherit (hostNet) iface;
                      ip.v6 = hostNet.v6.address;
                    }
                  ]);

                overlays = lib.genAttrs srv.allowedOverlays (_: { });

                nixosModule = { pkgs, ... }: {
                  networking.firewall.allowedUDPPorts = [ 53 ];
                  networking.firewall.allowedTCPPorts = [ 53 ];

                  services.dnsdist = {
                    enable = true;
                    listenAddress = "127.0.0.2";
                    listenPort = 5353;
                    extraConfig = ''
                      addLocal('[::1]:5353')
                      addLocal('${jail.uplink.ipv4}:53')
                      addLocal('[${jail.uplink.ipv6}]:53')
                      ${lib.concatMapStringsSep "\n" (overlayName: ''
                        addLocal('[${jail.overlays.${overlayName}.ipv6}]:53')                        
                      '') srv.allowedOverlays}

                      setACL({
                        '0.0.0.0/0',
                        '::/0'
                      })

                      ${lib.concatMapStringsSep "\n" (
                        route:
                        let
                          endpoint = alloy.endpoints.${route.upstream.endpoint};
                        in
                        ''
                          ${lib.concatImapStringsSep "\n" (
                            targetIdx: target:
                            lib.optionalString (!target.down) ''
                              newServer({
                                address = "${
                                  if target.ip ? v6 then "[${target.ip.v6}]" else target.ip.v4
                                }:${toString endpoint.port}",
                                pool = "${route.name}",
                                name = "${route.name}-${toString targetIdx}",
                                order = ${toString (if target.backup then 2 else 1)},
                                weight = ${toString target.weight}
                              })
                            ''
                          ) endpoint.targets}

                          setPoolServerPolicy(${
                            if endpoint.loadBalancing.policy == "round-robin" then
                              "wrr"
                            else if endpoint.loadBalancing.policy == "ip-hash" then
                              "chashed"
                            else if endpoint.loadBalancing.policy == "least-connections" then
                              "leastOutstanding"
                            else
                              "roundrobin"
                          }, "${route.name}")

                          smn${toString route.idx} = newSuffixMatchNode()
                          smn${toString route.idx}:add(newDNSName("${alloy.dns.zones.${route.zone}.apex}"))
                          addAction(SuffixMatchNodeRule(smn${toString route.idx}), PoolAction("${route.name}"))
                        ''
                      ) sortedRoutes}
                    '';
                  };
                };
              }
            )
          ) srv.hosts;
        };
    in
    {
      options.services.dns-edge = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule serviceSubmodule);
      };

      config =
        let
          services = lib.pipe alloy.services.dns-edge [
            (lib.filterAttrs (_: srv: srv.enable))
            (lib.mapAttrsToList mkService)
          ];
        in
        {
          assertions = lib.mkMerge (lib.map (s: s.assertions) services);
          dns = lib.mkMerge (lib.map (s: s.dns) services);
          jails = lib.mkMerge (lib.map (s: s.jails) services);
        };
    };
}
