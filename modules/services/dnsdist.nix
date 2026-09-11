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

      serviceSubmodule = { config, name, ... }: {
        options = {
          enable = lib.mkOption {
            default = true;
            type = lib.types.bool;
          };
          gateway = lib.mkOption {
            default = name;
            type = lib.types.str;
          };
          allowedOverlays = lib.mkOption {
            default = [ ];
            type = lib.types.nullOr (lib.types.listOf lib.types.str);
          };
          hosts = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
          };
        };
      };

      mkService =
        srvName: srv:
        let
          gateway = alloy.gateways.${srv.gateway};
          routes = gateway.dns.routes;

          allOverlays = lib.pipe routes [
            (lib.mapAttrsToList (
              _: route: lib.map (target: target.overlay) alloy.endpoints.${route.upstream.endpoint}.targets
            ))
            lib.flatten
            lib.unique
          ];

          suffixes = lib.pipe routes [
            (lib.mapAttrsToList (
              routeName: route: lib.map (suffix: { inherit routeName route suffix; }) route.suffixes
            ))
            lib.flatten
            (lib.sort (a: b: builtins.stringLength a.suffix > builtins.stringLength b.suffix))
          ];
        in
        {
          assertions = [
            {
              assertion =
                srv.allowedOverlays != [ ]
                -> lib.all (overlayName: builtins.elem overlayName srv.allowedOverlays) allOverlays;
              message = "[Alloy] dnsdist '${srvName}': there are some dns endpoint targets with addresses outside of the allowed overlays";
            }
            {
              assertion = srv.hosts != { };
              message = "[Alloy] dnsdist '${srvName}': at least one host must be specified";
            }
          ]
          ++ (lib.flatten (
            lib.mapAttrsToList (hostName: hostCfg: [
              {
                assertion = builtins.hasAttr hostName alloy.hosts;
                message = "[Alloy] dnsdist '${srvName}': host '${hostName}' is unknown";
              }
              {
                assertion = builtins.hasAttr hostName alloy.hosts -> (hostCfg.ipv4 != null || hostCfg.ipv6 != null);
                message = "[Alloy] dnsdist '${srvName}': host '${hostName}' must have specified at least one ip address (ipv4 or ipv6)";
              }
            ]) srv.hosts
          ));

          gateways.${srv.gateway}.dns.entrypoints = lib.mapAttrs (_: hostCfg: {
            inherit (hostCfg) ipv4 ipv6;
          }) srv.hosts;

          hosts = lib.mapAttrs (hostName: hostCfg: {
            nixosModule = {
              networking.firewall.interfaces = lib.optionalAttrs (hostCfg.iface != null) {
                ${hostCfg.iface}.allowedUDPPorts = [ 53 ];
                ${hostCfg.iface}.allowedTCPPorts = [ 53 ];
              };
            };
          }) srv.hosts;

          jails = lib.mapAttrs' (
            hostName: hostCfg:
            lib.nameValuePair "dnsdist-${hostName}" (
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

                      ${lib.concatMapAttrsStringSep "\n" (
                        routeName: route:
                        let
                          endpoint = alloy.endpoints.${route.upstream.endpoint};
                        in
                        ''
                          ${lib.concatImapStringsSep "\n" (
                            targetIdx: target:
                            lib.optionalString (!target.down) ''
                              newServer({
                                address = "[${target.ipv6}]:${toString endpoint.port}",
                                pool = "${routeName}",
                                name = "${routeName}-${toString targetIdx}",
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
                          }, "${routeName}")
                        ''
                      ) routes}

                      ${lib.concatMapStringsSep "\n" ({ suffix, routeName, ... }: ''
                        smn_${lib.replaceStrings [ "." "-" ] [ "_" "_" ] suffix} = newSuffixMatchNode()
                        smn_${lib.replaceStrings [ "." "-" ] [ "_" "_" ] suffix}:add(newDNSName("${suffix}"))
                        addAction(SuffixMatchNodeRule(smn_${lib.replaceStrings [ "." "-" ] [ "_" "_" ] suffix}), PoolAction("${routeName}"))
                      '') suffixes}
                    '';
                  };
                };
              }
            )
          ) srv.hosts;
        };
    in
    {
      options.services.dnsdist = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule serviceSubmodule);
      };

      config =
        let
          services = lib.pipe alloy.services.dnsdist [
            (lib.filterAttrs (_: srv: srv.enable))
            (lib.mapAttrsToList mkService)
          ];
        in
        {
          assertions = lib.mkMerge (lib.map (s: s.assertions) services);
          gateways = lib.mkMerge (lib.map (s: s.gateways) services);
          hosts = lib.mkMerge (lib.map (s: s.hosts) services);
          jails = lib.mkMerge (lib.map (s: s.jails) services);
        };
    };
}
