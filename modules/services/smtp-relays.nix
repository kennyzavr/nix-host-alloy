{
  flake.alloyModules.services =
    {
      lib,
      alib,
      config,
      ...
    }:
    let
      alloy = config;

      routeSubmodule = { config, name, ... }: {
        options = {
          domains = lib.mkOption {
            type = lib.types.listOf alib.types.zoneNode;
          };
          upstream.endpoint = lib.mkOption {
            type = lib.types.str;
          };
        };
      };

      hostType = lib.types.submodule {
        options = alib.types.netMatchOpts;
      };

      serviceSubmodule = { config, name, ... }: {
        options = {
          enable = lib.mkOption {
            default = true;
            type = lib.types.bool;
          };
          endpoint = lib.mkOption {
            type = lib.types.str;
            readOnly = true;
            default = "smtp-relay-${name}";
          };
          domain = lib.mkOption {
            type = alib.types.zoneNode;
          };
          addDnsRecords = lib.mkOption {
            default = true;
            type = lib.types.bool;
          };
          routes = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (lib.types.submodule routeSubmodule);
          };
          maxMsgSizeMB = lib.mkOption {
            default = 35;
            type = lib.types.ints.positive;
          };
          explicitTLS = {
            mode = lib.mkOption {
              default = "require";
              type = lib.types.enum [
                "none"
                "optional"
                "require"
              ];
            };
            cert = lib.mkOption {
              default = null;
              type = lib.types.nullOr lib.types.str;
            };
          };
          hosts = lib.mkOption {
            default = { };
            type = lib.types.attrsOf hostType;
          };
          allowedOverlays = lib.mkOption {
            default = [ ];
            type = lib.types.nullOr (lib.types.listOf lib.types.str);
          };
        };
      };
    in
    {
      options.services.smtp-relays = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule serviceSubmodule);
      };

      config =
        let
          mkService =
            srvName: srv:
            let
              allOverlays = lib.unique (
                lib.flatten (
                  lib.mapAttrsToList (
                    _: route: lib.map (target: target.overlay) alloy.endpoints.${route.upstream.endpoint}.targets
                  ) srv.routes
                )
              );
            in
            {
              assertions = [
                {
                  assertion = alib.types.dns.label.check srvName;
                  message = "[Alloy] smtp-relay name '${srvName}' must be valid dns label.";
                }
                {
                  assertion =
                    srv.allowedOverlays != [ ]
                    -> lib.all (overlayName: builtins.elem overlayName srv.allowedOverlays) allOverlays;
                  message = "[Alloy] smtp-relay '${srvName}': there are some endpoint targets with addresses outside of the allowed overlays";
                }
                {
                  assertion = srv.hosts != { };
                  message = "[Alloy] smtp-relay '${srvName}': at least one host must be specified";
                }
                {
                  assertion = srv.routes != { };
                  message = "[Alloy] smtp-relay '${srvName}': at least one route must be specified";
                }
                {
                  assertion = srv.explicitTLS.mode != "none" -> srv.explicitTLS.cert != null;
                  message = "[Alloy] smtp-relay '${srvName}' specifies explicitTLS.mode '${srv.explicitTLS.mode}' but explicitTLS.cert is not set. You must specify a valid certificate reference in 'explicitTLS.cert'.";
                }
                {
                  assertion = (srv.explicitTLS.cert != null) -> builtins.hasAttr srv.explicitTLS.cert alloy.tls.certs;
                  message = "[Alloy] smtp-relay '${srvName}' explicitTLS.cert refers to an unknown TLS certificate '${srv.explicitTLS.cert}'. Please ensure it is defined in 'config.tls.certs'.";
                }
                {
                  assertion =
                    srv.explicitTLS.mode != "none"
                    -> (srv.explicitTLS.cert != null)
                    -> builtins.hasAttr srv.explicitTLS.cert alloy.tls.certs
                    -> builtins.elem srv.domain alloy.tls.certs.${srv.explicitTLS.cert}.domains;
                  message = "[Alloy] smtp-relay '${srvName}' explicitTLS.cert does not contain main domain of the smtp-relay";
                }
              ]
              ++ (lib.flatten (
                lib.mapAttrsToList (hostName: hostCfg: [
                  {
                    assertion = builtins.hasAttr hostName alloy.hosts;
                    message = "[Alloy] smtp-relay '${srvName}': host '${hostName}' is unknown";
                  }
                  {
                    assertion = builtins.hasAttr hostName alloy.hosts -> (hostCfg.ipv4 != null || hostCfg.ipv6 != null);
                    message = "[Alloy] smtp-relay '${srvName}': host '${hostName}' must have specified at least one ip address (ipv4 or ipv6)";
                  }
                ]) srv.hosts
              ))
              ++ (lib.flatten (
                lib.mapAttrsToList (routeName: route: [
                  {
                    assertion = alib.types.dns.label.check routeName;
                    message = "[Alloy] smtp-relay '${srvName}': route name '${routeName}' must be valid dns label.";
                  }
                  {
                    assertion = route.domains != [ ];
                    message = "[Alloy] smtp-relay '${srvName}': route '${routeName}' must contains at least one domain.";
                  }
                  {
                    assertion = builtins.hasAttr route.upstream.endpoint alloy.endpoints;
                    message = "[Alloy] smtp-relay '${srvName}': route '${routeName}' refers to an unknown endpoint '${route.upstream.endpoint}'.";
                  }
                ]) srv.routes
              ));

              dns.records = lib.optionals srv.addDnsRecords (
                lib.flatten (
                  [
                    {
                      domain = {
                        zone = srv.domain.zone;
                        name = "@";
                      };
                      data.mx = {
                        preference = 10;
                        exchange = alloy.dns.resolveNode srv.domain;
                      };
                    }
                  ]
                  ++ (lib.mapAttrsToList (
                    _: route:
                    lib.map (domain: [
                      {
                        domain = domain;
                        data.mx = {
                          preference = 10;
                          exchange = alloy.dns.resolveNode srv.domain;
                        };
                      }
                    ]) route.domains
                  ) srv.routes)
                  ++ (lib.mapAttrsToList (
                    _: hostCfg:
                    [ ]
                    ++ (lib.optional (hostCfg.ipv4 != null) {
                      domain = srv.domain;
                      data.a = hostCfg.ipv4;
                    })
                    ++ (lib.optional (hostCfg.ipv6 != null) {
                      domain = srv.domain;
                      data.aaaa = hostCfg.ipv6;
                    })
                  ) srv.hosts)
                )
              );

              endpoints.${srv.endpoint} = {
                port = 25;
                targets = lib.flatten (
                  lib.mapAttrsToList (
                    hostName: _:
                    lib.map (overlayName: {
                      ipv6 = alloy.jails."smtp-relay-${srvName}-${hostName}".overlays.${overlayName}.ipv6;
                      overlay = overlayName;
                    }) allOverlays
                  ) srv.hosts
                );
              };

              jails = lib.mapAttrs' (
                hostName: hostCfg:
                lib.nameValuePair "smtp-relay-${srvName}-${hostName}" (
                  { config, ... }:
                  let
                    jail = config;
                  in
                  {
                    host = hostName;

                    uplink = {
                      allowEgress = true;
                      forwards = lib.optionals (hostCfg.ipv4 != null || hostCfg.ipv6 != null) [
                        {
                          proto = "tcp";
                          port = 25;
                          inherit (hostCfg) iface ipv4 ipv6;
                        }
                      ];
                    };

                    overlays = lib.genAttrs allOverlays (_: _: { });

                    static-ca.domains = [
                      alloy.endpoints.${srv.endpoint}.domain
                    ];

                    acme.certs = lib.optionalAttrs (srv.explicitTLS.mode != "none" && srv.explicitTLS.cert != null) {
                      ${srv.explicitTLS.cert} = {
                        restartServices = [ "opensmtpd.service" ];
                      };
                    };

                    secrets.${jail.static-ca.keySecret} = {
                      permissions = {
                        owner = "root";
                        group = "smtpd";
                        mode = "0640";
                      };
                    };

                    nixosModule =
                      { pkgs, config, ... }:
                      let
                        hasCert = srv.explicitTLS.mode != "none" && srv.explicitTLS.cert != null;
                        certCfg = if hasCert then jail.acme.certs.${srv.explicitTLS.cert} else null;
                        mkDomain = d: lib.removeSuffix "." (alloy.dns.resolveNode d);
                      in
                      {
                        networking.firewall.allowedTCPPorts = [ 25 ];

                        users.users.smtpd.extraGroups = lib.mapAttrsToList (certName: cert: cert.group) jail.acme.certs;

                        systemd.services.opensmtpd.wants = [ "network-online.target" ];
                        systemd.services.opensmtpd.after = [ "network-online.target" ];
                        systemd.services.opensmtpd.serviceConfig.ExecStartPre =
                          pkgs.writeShellScript "prepare-opensmtpd-certs" ''
                            mkdir -p /run/opensmtpd-certs
                            cp -L "${certCfg.certPath}" /run/opensmtpd-certs/cert.pem
                            cp -L "${certCfg.keyPath}" /run/opensmtpd-certs/key.pem
                            chown -R root:smtpd /run/opensmtpd-certs
                            chmod 644 /run/opensmtpd-certs/cert.pem
                            chmod 640 /run/opensmtpd-certs/key.pem
                          '';

                        services.opensmtpd = {
                          enable = true;
                          serverConfiguration = ''
                            smtp max-message-size ${toString srv.maxMsgSizeMB}M

                            ${lib.optionalString hasCert ''
                              pki "relay" cert "/run/opensmtpd-certs/cert.pem"
                              pki "relay" key "/run/opensmtpd-certs/key.pem"
                            ''}

                            pki "static-ca" cert "${alloy.facts.${jail.static-ca.certFact}.path}"
                            pki "static-ca" key "${jail.secrets.${jail.static-ca.keySecret}.path}"
                            ca "static-ca" cert "${alloy.facts.${alloy.static-ca.certFact}.path}"

                            ${lib.concatMapAttrsStringSep "\n" (routeName: route: ''
                              table route_${routeName}_domains { ${lib.concatMapStringsSep ", " mkDomain route.domains} }
                              table route_${routeName}_ips { ${
                                lib.concatMapStringsSep ", " (t: t.ipv6) alloy.endpoints.${route.upstream.endpoint}.targets
                              } }
                            '') srv.routes}

                            listen on ${jail.uplink.ipv4} port 25 ${
                              if hasCert && srv.explicitTLS.mode == "require" then
                                ''tls-require pki "relay"''
                              else if hasCert then
                                ''tls pki "relay"''
                              else
                                ""
                            } hostname "${mkDomain srv.domain}"

                            listen on ${jail.uplink.ipv6} port 25 ${
                              if hasCert && srv.explicitTLS.mode == "require" then
                                ''tls-require verify pki "relay"''
                              else if hasCert then
                                ''tls pki "relay"''
                              else
                                ""
                            } hostname "${mkDomain srv.domain}"

                            ${lib.concatMapAttrsStringSep "\n" (overlayName: overlay: ''
                              listen on ${overlay.ipv6} port 25 tag "OVERLAY_MTLS" tls-require verify pki "static-ca" ca "static-ca" hostname "${mkDomain srv.domain}"
                            '') jail.overlays}

                            action "route_out" relay helo "${mkDomain srv.domain}"
                            ${lib.concatMapAttrsStringSep "\n" (
                              routeName: route:
                              let
                                endpoint = alloy.endpoints.${route.upstream.endpoint};
                              in
                              ''
                                action "route_to_${routeName}" relay \
                                  host "tls://${endpoint.domain}:${toString endpoint.port}" \
                                  helo "${mkDomain srv.domain}" \
                                  pki "static-ca" \
                                  ca "static-ca"
                              ''
                            ) srv.routes}

                            ${lib.concatMapAttrsStringSep "\n" (routeName: route: ''
                              match from any for domain <route_${routeName}_domains> action "route_to_${routeName}"
                            '') srv.routes}

                            ${lib.concatMapAttrsStringSep "\n" (routeName: route: ''
                              match tag "OVERLAY_MTLS" from src <route_${routeName}_ips> for any action "route_out"
                            '') srv.routes}
                          '';
                        };
                      };
                  }
                )
              ) srv.hosts;
            };

          services = lib.pipe alloy.services.smtp-relays [
            (lib.filterAttrs (_: srv: srv.enable))
            (lib.mapAttrsToList mkService)
          ];
        in
        {
          assertions = lib.mkMerge (lib.map (s: s.assertions) services);
          dns = lib.mkMerge (lib.map (s: s.dns) services);
          endpoints = lib.mkMerge (lib.map (s: s.endpoints) services);
          jails = lib.mkMerge (lib.map (s: s.jails) services);
        };
    };
}
