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

      hostSubmodule = {
        options = alib.types.netMatchOpts;
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
            default = [ ];
            type = lib.types.nullOr (lib.types.listOf lib.types.str);
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
          allOverlays = lib.pipe srv.routes [
            (lib.mapAttrsToList (
              _: route: builtins.attrNames alloy.endpoints.${route.upstream.endpoint}.overlays
            ))
            lib.flatten
            lib.unique
          ];

          sortedRoutes = lib.pipe srv.routes [
            (lib.mapAttrsToList (name: route: route // { inherit name; }))
            (lib.imap (idx: route: route // { inherit idx; }))
            (builtins.sort (a: b: builtins.stringLength alloy.dns.zones.${a.zone}.apex > builtins.stringLength alloy.dns.zones.${b.zone}.apex))
          ];
        in
        {
          assertions = [
            {
              assertion =
                srv.allowedOverlays != [ ]
                -> lib.all (overlayName: builtins.elem overlayName srv.allowedOverlays) allOverlays;
              message = "[Alloy] dns-edge '${srvName}': there are some dns endpoint targets with addresses outside of the allowed overlays";
            }
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
              {
                assertion = builtins.hasAttr hostName alloy.hosts -> (hostCfg.ipv4 != null || hostCfg.ipv6 != null);
                message = "[Alloy] dns-edge '${srvName}': host '${hostName}' must have specified at least one ip address (ipv4 or ipv6)";
              }
            ]) srv.hosts
          ));

          dns.zones = lib.mapAttrs' (
            _: route:
            lib.nameValuePair route.zone {
              nname = "ns1";
              nameservers = lib.flatten (
                lib.mapAttrsToList (
                  _: host:
                  [ ] ++ (lib.optional (host.ipv4 != null) host.ipv4) ++ (lib.optional (host.ipv6 != null) host.ipv6)
                ) srv.hosts
              );
            }
          ) srv.routes;

          dns.records = lib.flatten (
            lib.map (
              route:
              (lib.imap1 (
                hostIdx: host:
                let
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
                ++ (lib.optional (host.ipv4 != null) {
                  domain = {
                    zone = route.zone;
                    name = nsPrefix;
                  };
                  data.a = host.ipv4;
                })
                ++ (lib.optional (parentZone != null && host.ipv4 != null) {
                  domain = {
                    zone = parentZone;
                    name = "${nsPrefix}.${subzone}";
                  };
                  data.a = host.ipv4;
                })
                ++ (lib.optional (host.ipv6 != null) {
                  domain = {
                    zone = route.zone;
                    name = nsPrefix;
                  };
                  data.aaaa = host.ipv6;
                })
                ++ (lib.optional (parentZone != null && host.ipv6 != null) {
                  domain = {
                    zone = parentZone;
                    name = "${nsPrefix}.${subzone}";
                  };
                  data.aaaa = host.ipv6;
                })
              ) (builtins.attrValues srv.hosts))
            ) sortedRoutes
          );

          jails = lib.mapAttrs' (
            hostName: hostCfg:
            lib.nameValuePair "dns-edge-${hostName}" (
              { config, ... }:
              let
                jail = config;
              in
              {
                host = hostName;

                uplink.forwards = lib.optionals (hostCfg.ipv4 != null || hostCfg.ipv6 != null) [
                  {
                    proto = "tcp";
                    port = 53;
                    inherit (hostCfg) iface ipv4 ipv6;
                  }
                  {
                    proto = "udp";
                    port = 53;
                    inherit (hostCfg) iface ipv4 ipv6;
                  }
                ];

                overlays = lib.genAttrs allOverlays (_: { });

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
                      '') allOverlays}

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
                                address = "[${target.ipv6}]:${toString endpoint.port}",
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
