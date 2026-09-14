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

      routeSubmodule = { config, name, ... }: {
        options = {
          domain = lib.mkOption {
            type = alib.types.zoneNode;
          };
          addDnsRecords = lib.mkOption {
            default = true;
            type = lib.types.bool;
          };
          downstream = {
            port = lib.mkOption {
              type = lib.types.port;
            };
            tls.enable = lib.mkOption {
              default = false;
              type = lib.types.bool;
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
            type = lib.types.listOf lib.types.str;
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
              assertion = alib.types.dns.label.check srvName;
              message = "[Alloy] tls-edge name '${srvName}' must be valid dns label.";
            }
            {
              assertion =
                srv.allowedOverlays != [ ]
                -> lib.all (overlayName: builtins.elem overlayName srv.allowedOverlays) allOverlays;
              message = "[Alloy] tls-edge '${srvName}': there are some endpoint targets with addresses outside of the allowed overlays";
            }
            {
              assertion = srv.hosts != { };
              message = "[Alloy] tls-edge '${srvName}': at least one host must be specified";
            }
            {
              assertion = srv.routes != { };
              message = "[Alloy] smtp-relay '${srvName}': at least one route must be specified";
            }
          ]
          ++ (lib.flatten (
            lib.mapAttrsToList (hostName: hostCfg: [
              {
                assertion = builtins.hasAttr hostName alloy.hosts;
                message = "[Alloy] tls-edge '${srvName}': host '${hostName}' is unknown";
              }
              {
                assertion = builtins.hasAttr hostName alloy.hosts -> (hostCfg.ipv4 != null || hostCfg.ipv6 != null);
                message = "[Alloy] tls-edge '${srvName}': host '${hostName}' must have specified at least one ip address (ipv4 or ipv6)";
              }
            ]) srv.hosts
          ))
          ++ (lib.flatten (
            lib.mapAttrsToList (routeName: route: [
              {
                assertion = alib.types.dns.label.check routeName;
                message = "[Alloy] tls-edge '${srvName}': route name '${routeName}' must be valid dns label.";
              }
              {
                assertion = builtins.hasAttr route.upstream.endpoint alloy.endpoints;
                message = "[Alloy] tls-edge '${srvName}': route '${routeName}' refers to an unknown endpoint '${route.upstream.endpoint}'.";
              }
              {
                assertion =
                  route.downstream.tls.enable
                  -> route.downstream.tls.cert != null && builtins.hasAttr route.downstream.tls.cert alloy.tls.certs;
                message = "[Alloy] tls-edge '${srvName}': route '${routeName}': downstream.tls.cert must be valid reference to tls.certs entry.";
              }
            ]) srv.routes
          ));

          dns.records = lib.flatten (
            lib.mapAttrsToList (
              _: route:
              (lib.mapAttrsToList (
                _: hostCfg:
                [ ]
                ++ (lib.optional (route.addDnsRecords && hostCfg.ipv4 != null) {
                  inherit (route) domain;
                  data.a = hostCfg.ipv4;
                })
                ++ (lib.optional (route.addDnsRecords && hostCfg.ipv6 != null) {
                  inherit (route) domain;
                  data.aaaa = hostCfg.ipv6;
                })
              ) srv.hosts)
            ) srv.routes
          );

          jails = lib.mapAttrs' (
            hostName: hostCfg:
            lib.nameValuePair "tls-edge-${srvName}-${hostName}" (
              { config, ... }:
              let
                jail = config;
              in
              {
                host = hostName;

                uplink.forwards = lib.mapAttrsToList (_: stream: {
                  proto = "tcp";
                  port = stream.downstream.port;
                  inherit (hostCfg) iface ipv4 ipv6;
                }) srv.routes;

                overlays = lib.genAttrs allOverlays (_: _: { });

                tls.certs = lib.pipe srv.routes [
                  (lib.filterAttrs (_: route: route.downstream.tls.enable && route.downstream.tls.cert != null))
                  (lib.mapAttrsToList (
                    _: route: {
                      ${route.downstream.tls.cert} = {
                        restartServices = [ "haproxy.service" ];
                      };
                    }
                  ))
                  lib.mkMerge
                ];

                mtls.permissions = {
                  owner = "haproxy";
                  group = "haproxy";
                  mode = "0640";
                };

                nixosModule =
                  { pkgs, config, ... }:
                  {
                    networking.firewall.allowedTCPPorts = lib.mapAttrsToList (_: r: r.downstream.port) srv.routes;

                    users.users.haproxy.extraGroups = lib.mapAttrsToList (_: cert: cert.group) jail.tls.certs;

                    services.haproxy = {
                      enable = true;
                      config = ''
                        global
                          log /dev/log local0
                          maxconn 4096
                          tune.ssl.default-dh-param 2048

                        defaults
                          log global
                          mode tcp
                          option tcplog
                          timeout connect 5s
                          timeout client  300s
                          timeout server  300s

                        ${lib.concatMapAttrsStringSep "\n\n" (
                          routeName: route:
                          let
                            endpoint = alloy.endpoints.${route.upstream.endpoint};
                            policy = endpoint.loadBalancing.policy;
                            hasCert = route.downstream.tls.enable && route.downstream.tls.cert != null;
                            certCfg = if hasCert then jail.tls.certs.${route.downstream.tls.cert} else null;
                            bindParams = if hasCert then "ssl crt ${certCfg.fullPath}" else "";
                          in
                          ''
                            frontend stream-${routeName}
                              bind ${jail.uplink.ipv4}:${toString route.downstream.port} ${bindParams}
                              bind [${jail.uplink.ipv6}]:${toString route.downstream.port} ${bindParams}
                              default_backend backend-${routeName}

                            backend backend-${routeName}
                              ${
                                if policy == "round-robin" then
                                  "balance roundrobin"
                                else if policy == "least-connections" then
                                  "balance leastconn"
                                else if policy == "ip-hash" then
                                  "balance source"
                                else if policy == "random" then
                                  "balance random"
                                else
                                  ""
                              }
                              ${lib.concatImapStringsSep "\n  " (idx: target: ''
                                server target${toString idx} [${target.ipv6}]:${toString endpoint.port} weight ${toString target.weight} ssl verify required ca-file "${alloy.mtls.certPath}" crt "${jail.mtls.fullPath}" ${lib.optionalString endpoint.proxyv2 "send-proxy-v2"}
                              '') endpoint.targets}
                          ''
                        ) srv.routes}
                      '';
                    };
                  };
              }
            )
          ) srv.hosts;
        };
    in
    {
      options.services.tls-edge = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule serviceSubmodule);
      };

      config =
        let
          services = lib.pipe alloy.services.tls-edge [
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
