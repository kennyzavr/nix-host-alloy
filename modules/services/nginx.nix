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

      serviceSubmodule = { name, ... }: {
        options = {
          enable = lib.mkOption {
            default = true;
            type = lib.types.bool;
          };
          # TODO: add assertion - only one service per a gateway
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
          routes = gateway.http.routes;

          allOverlays = lib.pipe routes [
            (lib.mapAttrsToList (
              _: route: lib.map (target: target.overlay) alloy.endpoints.${route.upstream.endpoint}.targets
            ))
            lib.flatten
            lib.unique
          ];
        in
        {
          assertions = [
            {
              assertion =
                srv.allowedOverlays != [ ]
                -> lib.all (overlayName: builtins.elem overlayName srv.allowedOverlays) allOverlays;
              message = "[Alloy] nginx '${srvName}': there are some endpoint targets with addresses outside of the allowed overlays";
            }
            {
              assertion = srv.hosts != { };
              message = "[Alloy] nginx '${srvName}': at least one host must be specified";
            }
          ]
          ++ (lib.flatten (
            lib.mapAttrsToList (hostName: hostCfg: [
              {
                assertion = builtins.hasAttr hostName alloy.hosts;
                message = "[Alloy] ngin '${srvName}': host '${hostName}' is unknown";
              }
              {
                assertion = builtins.hasAttr hostName alloy.hosts -> (hostCfg.ipv4 != null || hostCfg.ipv6 != null);
                message = "[Alloy] nginx '${srvName}': host '${hostName}' must have specified at least one ip address (ipv4 or ipv6)";
              }
            ]) srv.hosts
          ));

          gateways.${srv.gateway}.http.entrypoints = lib.mapAttrs (_: hostCfg: {
            inherit (hostCfg) ipv4 ipv6;
          }) srv.hosts;

          hosts = lib.mapAttrs (hostName: hostCfg: {
            nixosModule = {
              networking.firewall.interfaces = lib.optionalAttrs (hostCfg.iface != null) {
                ${hostCfg.iface}.allowedUDPPorts = [
                  443
                ];
                ${hostCfg.iface}.allowedTCPPorts = [
                  80
                  443
                ];
              };
            };
          }) srv.hosts;

          jails = lib.mapAttrs' (
            hostName: hostCfg:
            lib.nameValuePair "nginx-${srvName}-${hostName}" (
              { config, ... }:
              let
                jail = config;
              in
              {
                host = hostName;

                uplink.forwards = lib.optionals (hostCfg.ipv4 != null || hostCfg.ipv6 != null) [
                  {
                    proto = "tcp";
                    port = 80;
                    inherit (hostCfg) iface ipv4 ipv6;
                  }
                  {
                    proto = "tcp";
                    port = 443;
                    inherit (hostCfg) iface ipv4 ipv6;
                  }
                  {
                    proto = "udp";
                    port = 443;
                    inherit (hostCfg) iface ipv4 ipv6;
                  }
                ];

                overlays = lib.genAttrs allOverlays (_: _: { });

                acme.certs = lib.pipe routes [
                  (lib.filterAttrs (_: r: r.downstream.tls.mode != "none" && r.downstream.tls.cert != null))
                  (lib.mapAttrsToList (
                    _: route: {
                      ${route.downstream.tls.cert} = {
                        restartServices = [ "nginx.service" ];
                      };
                    }
                  ))
                  lib.mkMerge
                ];

                nixosModule = { pkgs, ... }: {
                  networking.firewall.allowedUDPPorts = [
                    443
                  ];
                  networking.firewall.allowedTCPPorts = [
                    80
                    443
                  ];

                  users.users.nginx = {
                    extraGroups = lib.mapAttrsToList (_: cert: cert.group) jail.acme.certs;
                  };

                  services.nginx = {
                    enable = true;
                    appendHttpConfig = ''
                      ${lib.concatMapAttrsStringSep "\n" (
                        routeName: route:
                        let
                          endpoint = alloy.endpoints.${route.upstream.endpoint};
                          policy = endpoint.loadBalancing.policy;
                        in
                        ''
                          upstream route-${routeName} {
                            ${
                              if policy == "round-robin" then
                                ""
                              else if policy == "least-connections" then
                                "least_conn;"
                              else if policy == "ip-hash" then
                                "ip_hash;"
                              else if policy == "random" then
                                "random;"
                              else
                                ""
                            }
                            ${lib.concatMapStringsSep "\n" (target: ''
                              server [${target.ipv6}]:${toString endpoint.port} weight=${toString target.weight} ${lib.optionalString target.backup "backup"} ${lib.optionalString target.down "down"};
                            '') endpoint.targets}
                          }
                        ''
                      ) routes}
                    '';
                    virtualHosts = lib.mapAttrs' (
                      routeName: route:
                      lib.nameValuePair "route-${routeName}" (
                        let
                          isSsl = route.downstream.tls.mode != "none";
                          acmeCert = jail.acme.certs.${route.downstream.tls.cert};
                        in
                        {
                          serverName = route.serverName;
                          addSSL = route.downstream.tls.mode == "add";
                          onlySSL = route.downstream.tls.mode == "only";
                          forceSSL = route.downstream.tls.mode == "force";
                          sslCertificate = lib.mkIf isSsl acmeCert.certPath;
                          sslCertificateKey = lib.mkIf isSsl acmeCert.keyPath;
                          http2 = route.downstream.http2;
                          http3 = route.downstream.http3;
                          quic = route.downstream.http3;
                          locations."/" = {
                            recommendedProxySettings = true;
                            proxyPass = "${if route.upstream.tls.enable then "https" else "http"}://route-${routeName}";
                          };
                        }
                      )
                    ) routes;
                  };
                };
              }
            )
          ) srv.hosts;
        };
    in
    {
      options.services.nginx = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule serviceSubmodule);
      };

      config =
        let
          services = lib.pipe alloy.services.nginx [
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
