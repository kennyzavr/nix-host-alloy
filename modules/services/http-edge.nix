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

      hostType = lib.types.submodule {
        options = alib.types.netMatchOpts;
      };

      routeSubmodule = { config, ... }: {
        options = {
          domain = lib.mkOption {
            type = alib.types.zoneNode;
          };
          addDnsRecords = lib.mkOption {
            default = true;
            type = lib.types.bool;
          };
          downstream = {
            http2 = lib.mkOption {
              default = true;
              type = lib.types.bool;
            };
            http3 = lib.mkOption {
              default = false;
              type = lib.types.bool;
            };
            tls.mode = lib.mkOption {
              default = "none";
              type = lib.types.enum [
                "none"
                "add"
                "force"
                "only"
              ];
            };
            tls.cert = lib.mkOption {
              default = null;
              type = lib.types.nullOr lib.types.str;
            };
          };
          upstream = {
            endpoint = lib.mkOption {
              type = lib.types.str;
            };
          };
        };
      };

      serviceSubmodule = { name, ... }: {
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
            type = lib.types.attrsOf hostType;
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
        in
        {
          assertions = [
            {
              assertion =
                srv.allowedOverlays != [ ]
                -> lib.all (overlayName: builtins.elem overlayName srv.allowedOverlays) allOverlays;
              message = "[Alloy] http-edge '${srvName}': there are some endpoint targets with addresses outside of the allowed overlays";
            }
            {
              assertion = srv.hosts != { };
              message = "[Alloy] http-edge '${srvName}': at least one host must be specified";
            }
          ]
          ++ (lib.flatten (
            lib.mapAttrsToList (hostName: hostCfg: [
              {
                assertion = builtins.hasAttr hostName alloy.hosts;
                message = "[Alloy] http-edge '${srvName}': host '${hostName}' is unknown";
              }
              {
                assertion = builtins.hasAttr hostName alloy.hosts -> (hostCfg.ipv4 != null || hostCfg.ipv6 != null);
                message = "[Alloy] http-edge '${srvName}': host '${hostName}' must have specified at least one ip address (ipv4 or ipv6)";
              }
            ]) srv.hosts
          ));

          dns.records = lib.pipe srv.routes [
            (lib.filterAttrs (_: route: route.addDnsRecords))
            (lib.mapAttrsToList (
              _: route:
              lib.mapAttrsToList (
                _: host:
                [ ]
                ++ (lib.optional (host.ipv4 != null) {
                  inherit (route) domain;
                  data.a = host.ipv4;
                })
                ++ (lib.optional (host.ipv6 != null) {
                  inherit (route) domain;
                  data.aaaa = host.ipv6;
                })
              ) srv.hosts
            ))
            lib.flatten
          ];

          jails = lib.mapAttrs' (
            hostName: hostCfg:
            lib.nameValuePair "http-edge-${srvName}-${hostName}" (
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

                tls.certs = lib.pipe srv.routes [
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

                mtls.permissions = {
                  owner = "nginx";
                  group = "nginx";
                  mode = "0640";
                };

                nixosModule = { pkgs, ... }: {
                  networking.firewall.allowedUDPPorts = [
                    443
                  ];
                  networking.firewall.allowedTCPPorts = [
                    80
                    443
                  ];

                  users.users.nginx = {
                    extraGroups = lib.mapAttrsToList (_: cert: cert.group) jail.tls.certs;
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
                      ) srv.routes}
                    '';
                    virtualHosts = lib.mapAttrs' (
                      routeName: route:
                      lib.nameValuePair "route-${routeName}" (
                        let
                          isTls = route.downstream.tls.mode != "none";
                          cert = jail.tls.certs.${route.downstream.tls.cert};
                          endpoint = alloy.endpoints.${route.upstream.endpoint};
                        in
                        {
                          serverName = alloy.dns.resolveNode route.domain;
                          addSSL = route.downstream.tls.mode == "add";
                          onlySSL = route.downstream.tls.mode == "only";
                          forceSSL = route.downstream.tls.mode == "force";
                          sslCertificate = lib.mkIf isTls cert.certPath;
                          sslCertificateKey = lib.mkIf isTls cert.keyPath;
                          http2 = route.downstream.http2;
                          http3 = route.downstream.http3;
                          quic = route.downstream.http3;
                          locations."/" = {
                            recommendedProxySettings = true;
                            proxyPass = "https://route-${routeName}";
                          };
                          extraConfig = ''
                            proxy_ssl_certificate ${jail.mtls.certPath};
                            proxy_ssl_certificate_key ${jail.mtls.keyPath};

                            proxy_ssl_trusted_certificate ${alloy.mtls.certPath};
                            proxy_ssl_verify on;
                            proxy_ssl_verify_depth 1;
                            proxy_ssl_name ${endpoint.domain};
                          '';
                        }
                      )
                    ) srv.routes;
                  };
                };
              }
            )
          ) srv.hosts;
        };
    in
    {
      options.services.http-edge = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule serviceSubmodule);
      };

      config =
        let
          services = lib.pipe alloy.services.http-edge [
            (lib.filterAttrs (_: srv: srv.enable))
            (lib.mapAttrsToList mkService)
          ];
        in
        {
          assertions = lib.mkMerge (lib.map (s: s.assertions) services);
          jails = lib.mkMerge (lib.map (s: s.jails) services);
          dns = lib.mkMerge (lib.map (s: s.dns) services);
        };
    };
}
