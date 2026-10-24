{ withSystem, ... }: {
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
          domain = lib.mkOption {
            type = alib.types.zoneNode;
            description = "DNS node used as the mail domain for this route.";
          };
          postmaster = lib.mkOption {
            type = lib.types.str;
            default = "postmaster@${alloy.dns.resolveNode config.domain}";
            description = "Postmaster address advertised for this route.";
          };
          upstream.endpoint = lib.mkOption {
            type = lib.types.str;
            description = "Alloy endpoint used as the upstream mail server.";
          };
        };
      };

      hostSubmodule = { config, name, ... }: {
        options.net = lib.mkOption {
          default = alloy.hosts.${name}.primaryNet;
          type = lib.types.str;
          description = "Host network whose advertised address is published for this SMTP edge host.";
        };
      };

      serviceSubmodule = { config, name, ... }: {
        options = {
          enable = lib.mkOption {
            default = true;
            type = lib.types.bool;
            description = "Whether to create this SMTP edge service and its generated mail configuration.";
          };
          endpoint = lib.mkOption {
            type = lib.types.str;
            readOnly = true;
            default = "smtp-edge-${name}";
            description = "Generated endpoint name for this SMTP service.";
          };
          hostname = lib.mkOption {
            type = alib.types.zoneNode;
            description = "DNS name used as the SMTP server's primary hostname.";
          };
          addDnsRecords = lib.mkOption {
            default = true;
            type = lib.types.bool;
            description = "Whether to add DNS records for the service hostname and mail routes.";
          };
          routes = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (lib.types.submodule routeSubmodule);
            description = "Mail domains and upstream endpoints served by this SMTP edge service.";
          };
          maxMsgSizeMB = lib.mkOption {
            default = 35;
            type = lib.types.ints.positive;
            description = "Maximum accepted message size in mebibytes.";
          };
          explicitTLS = {
            mode = lib.mkOption {
              default = "require";
              type = lib.types.enum [
                "none"
                "optional"
                "require"
              ];
              description = "STARTTLS policy: `none` disables it, `optional` permits plaintext delivery, and `require` enforces encryption.";
            };
            cert = lib.mkOption {
              default = null;
              type = lib.types.nullOr lib.types.str;
              description = "Certificate from `tls.certs` used for explicit TLS; required when TLS mode is enabled.";
            };
          };
          hosts = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
            description = "Hosts that run SMTP edge instances for this service.";
          };
          allowedOverlays = lib.mkOption {
            default = null;
            type = lib.types.nullOr (lib.types.listOf lib.types.str);
            description = "Allowed overlays for upstream endpoints; null infers the set from configured routes.";
          };
          dkim = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether to enable DKIM signing and its key generator for this service.";
            };
            dmarcPolicy = lib.mkOption {
              default = "reject";
              type = lib.types.enum [
                "none"
                "quarantine"
                "reject"
              ];
              description = "DMARC policy published for this service's mail domain.";
            };
            privKeySecret = lib.mkOption {
              default = "smtp-edge/${name}/dkim/pub.key";
              readOnly = true;
              type = lib.types.str;
            };
            pubKeyFact = lib.mkOption {
              default = "smtp-edge/${name}/dkim/priv.key";
              readOnly = true;
              type = lib.types.str;
            };
            keyGenerator = lib.mkOption {
              default = "smtp-edge/${name}/dkim";
              readOnly = true;
              type = lib.types.str;
            };
          };
          antivirus = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether to enable antivirus scanning of incoming mail.";
            };
          };
        };
      };
    in
    {
      options.services.smtp-edge = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule serviceSubmodule);
        description = "SMTP relay service instances, including mail routing and optional DKIM/antivirus features.";
      };

      config =
        let
          mkService =
            srvName: srv:
            let
              overlays = lib.defaultTo (lib.pipe srv.routes [
                (lib.mapAttrsToList (
                  _: route: builtins.attrNames alloy.endpoints.${route.upstream.endpoint}.overlays
                ))
                lib.flatten
                lib.unique
              ]) srv.allowedOverlays;
            in
            {
              warnings = lib.pipe srv.routes [
                (lib.mapAttrsToList (
                  routeName: route: [
                    (alloy.mkEndpointOverlaysWarn route.upstream.endpoint srv.allowedOverlays
                      "Service 'smtp-edge.${srvName}', route '${routeName}':"
                    )
                  ]
                ))
                lib.flatten
              ];

              assertions = [
                {
                  assertion = alib.types.dns.label.check srvName;
                  message = "[Alloy] Service 'smtp-edge.${srvName}': The service name must be a valid DNS label.";
                }
                {
                  assertion = srv.hosts != { };
                  message = "[Alloy] Service 'smtp-edge.${srvName}': Declare at least one host in `hosts`.";
                }
                {
                  assertion = srv.routes != { };
                  message = "[Alloy] Service 'smtp-edge.${srvName}': Declare at least one route in `routes`.";
                }
                {
                  assertion = srv.explicitTLS.mode != "none" -> srv.explicitTLS.cert != null;
                  message = "[Alloy] Service 'smtp-edge.${srvName}': `explicitTLS.cert` is required when `explicitTLS.mode` is '${srv.explicitTLS.mode}'. Set it to a certificate defined in `tls.certs`.";
                }
                {
                  assertion = (srv.explicitTLS.cert != null) -> builtins.hasAttr srv.explicitTLS.cert alloy.tls.certs;
                  message = "[Alloy] Service 'smtp-edge.${srvName}': Certificate '${srv.explicitTLS.cert}' from `explicitTLS.cert` is not defined in `tls.certs`.";
                }
                # {
                #   assertion =
                #     srv.explicitTLS.mode != "none"
                #     -> (srv.explicitTLS.cert != null)
                #     -> builtins.hasAttr srv.explicitTLS.cert alloy.tls.certs
                #     -> builtins.elem srv.hostname alloy.tls.certs.${srv.explicitTLS.cert}.domains;
                #   message = "[Alloy] Service 'smtp-edge.${srvName}': Certificate '${srv.explicitTLS.cert}' does not cover hostname '${srv.hostname}'. Add the hostname to the certificate's domains or select another certificate.";
                # }
              ]
              ++ (lib.flatten (
                lib.mapAttrsToList (hostName: hostCfg: [
                  {
                    assertion = builtins.hasAttr hostName alloy.hosts;
                    message = "[Alloy] Service 'smtp-edge.${srvName}': Host '${hostName}' is not defined in `hosts`.";
                  }
                ]) srv.hosts
              ))
              ++ (lib.flatten (
                lib.mapAttrsToList (routeName: route: [
                  {
                    assertion = alib.types.dns.label.check routeName;
                    message = "[Alloy] Service 'smtp-edge.${srvName}', route '${routeName}': The route name must be a valid DNS label.";
                  }
                  {
                    assertion = builtins.hasAttr route.upstream.endpoint alloy.endpoints;
                    message = "[Alloy] Service 'smtp-edge.${srvName}', route '${routeName}': Endpoint '${route.upstream.endpoint}' is not defined in `endpoints`.";
                  }
                ]) srv.routes
              ));

              dns.records = lib.optionals srv.addDnsRecords (
                lib.flatten (
                  [ ]
                  ++ (lib.mapAttrsToList (
                    hostName: hostCfg:
                    let
                      host = alloy.hosts.${hostName};
                      hostNet = host.nets.${hostCfg.net};
                    in
                    [ ]
                    ++ (lib.optional (hostNet.v4 != null) {
                      domain = srv.hostname;
                      data.a = hostNet.v4.advertiseAddress;
                    })
                    ++ (lib.optional (hostNet.v6 != null) {
                      domain = srv.hostname;
                      data.aaaa = hostNet.v6.advertiseAddress;
                    })
                  ) srv.hosts)
                  ++ (lib.mapAttrsToList (
                    _: route:
                    [
                      {
                        domain = route.domain;
                        data.mx = {
                          preference = 10;
                          exchange = alloy.dns.resolveNode srv.hostname;
                        };
                      }
                      {
                        domain = route.domain;
                        data.txt = "v=spf1 mx -all";
                      }
                    ]
                    ++ (lib.optional srv.dkim.enable {
                      domain = alib.extendZoneNode route.domain "relay._domainkey";
                      data.txt = "v=DKIM1; k=rsa; p=${lib.removeSuffix "\n" alloy.facts.${srv.dkim.pubKeyFact}.value}";
                    })
                    ++ (lib.optional srv.dkim.enable {
                      domain = alib.extendZoneNode route.domain "_dmarc";
                      data.txt = "v=DMARC1; p=${srv.dkim.dmarcPolicy}; rua=mailto:${route.postmaster}; ruf=mailto:${route.postmaster}";
                    })
                  ) srv.routes)
                )
              );

              endpoints.${srv.endpoint} = {
                port = 25;
                targets = lib.flatten (
                  lib.mapAttrsToList (
                    hostName: _:
                    lib.map (overlayName: {
                      ip.v6 = alloy.jails."smtp-edge-${srvName}-${hostName}".overlays.${overlayName}.ipv6;
                      overlay = overlayName;
                    }) overlays
                  ) srv.hosts
                );
              };

              generators.instances.${srv.dkim.keyGenerator} = {
                enable = srv.dkim.enable;
                tags = [
                  "smtp-edge"
                  "smtp-edge/${srvName}"
                ];
                facts.${srv.dkim.pubKeyFact} = { };
                secrets.${srv.dkim.privKeySecret} = { };
                package =
                  { system, ... }:
                  let
                    pkgs = withSystem system ({ pkgs, ... }: pkgs);
                  in
                  pkgs.writeShellApplication {
                    name = "smtp-edge-dkim-generator";
                    runtimeInputs = [
                      pkgs.openssl
                      pkgs.coreutils
                      pkgs.gnugrep
                    ];
                    text = ''
                      set -euo pipefail

                      priv=$(openssl genrsa 2048 2>/dev/null)
                      pub=$(printf "%s" "$priv" | openssl rsa -pubout -outform PEM 2>/dev/null | grep -v '^-'  | tr -d '\n' | tr -d '\r')

                      "$ALLOY_BIN" facts set "${srv.dkim.pubKeyFact}" <<< "$pub"
                      "$ALLOY_BIN" secrets set "${srv.dkim.privKeySecret}" <<< "$priv"
                    '';
                  };
              };

              jails = lib.mapAttrs' (
                hostName: hostCfg:
                let
                  host = alloy.hosts.${hostName};
                  hostNet = host.nets.${hostCfg.net};
                in
                lib.nameValuePair "smtp-edge-${srvName}-${hostName}" (
                  { config, ... }:
                  let
                    jail = config;
                  in
                  {
                    host = hostName;

                    tags = [
                      "smtp-edge"
                      "smtp-edge/${srvName}"
                    ];

                    uplink = {
                      allowEgress = true;
                    };

                    uplink.forwards =
                      (lib.optionals (hostNet.v4 != null) [
                        {
                          proto = "tcp";
                          port = 25;
                          inherit (hostNet) iface;
                          ip.v4 = hostNet.v4.mode.static.address;
                        }
                        {
                          proto = "udp";
                          port = 25;
                          inherit (hostNet) iface;
                          ip.v4 = hostNet.v4.advertiseAddress;
                        }
                      ])
                      ++ (lib.optionals (hostNet.v6 != null) [
                        {
                          proto = "tcp";
                          port = 25;
                          inherit (hostNet) iface;
                          ip.v6 = hostNet.v6.mode.static.address;
                        }
                        {
                          proto = "tcp";
                          port = 25;
                          inherit (hostNet) iface;
                          ip.v6 = hostNet.v6.advertiseAddress;
                        }
                      ]);

                    overlays = lib.genAttrs overlays (_: _: { });

                    endpoints.${srv.endpoint} = { };

                    mtls.permissions = {
                      owner = "root";
                      group = "postfix";
                      mode = "0640";
                    };

                    tls.certs = lib.optionalAttrs (srv.explicitTLS.mode != "none" && srv.explicitTLS.cert != null) {
                      ${srv.explicitTLS.cert} = {
                        restartServices = [ "postfix.service" ];
                      };
                    };

                    secrets = lib.optionalAttrs srv.dkim.enable {
                      ${srv.dkim.privKeySecret} = {
                        permissions = {
                          owner = "rspamd";
                          group = "rspamd";
                          mode = "0640";
                        };
                      };
                    };

                    nixosModule =
                      { pkgs, config, ... }:
                      let
                        hasCert = srv.explicitTLS.mode != "none" && srv.explicitTLS.cert != null;
                        certCfg = if hasCert then jail.tls.certs.${srv.explicitTLS.cert} else null;
                        mkDomain = d: lib.removeSuffix "." (alloy.dns.resolveNode d);
                      in
                      {
                        networking.firewall.allowedTCPPorts = [ 25 ];

                        services.clamav = {
                          daemon.enable = srv.antivirus.enable;
                          updater.enable = srv.antivirus.enable;
                        };

                        services.redis.servers.rspamd = {
                          enable = srv.dkim.enable || srv.antivirus.enable;
                          port = 0;
                          unixSocket = "/run/redis-rspamd/redis.sock";
                          unixSocketPerm = 660;
                        };

                        users.users.rspamd = {
                          extraGroups = [
                            "redis-rspamd"
                            "clamav"
                          ];
                        };

                        services.rspamd = {
                          enable = srv.dkim.enable || srv.antivirus.enable;
                          workers.rspamd_proxy = {
                            bindSockets = [
                              {
                                socket = "/run/rspamd/rspamd-milter.sock";
                                mode = "0660";
                              }
                            ];
                            extraConfig = ''
                              milter = yes;
                              timeout = 120s;
                              upstream "local" {
                                default = yes;
                                self_scan = yes;
                              }
                            '';
                          };
                          locals = {
                            "redis.conf".text = ''
                              servers = "/run/redis-rspamd/redis.sock";
                            '';
                            "dkim_signing.conf" = lib.mkIf srv.dkim.enable {
                              text = ''
                                path = "${jail.secrets.${srv.dkim.privKeySecret}.path or ""}";
                                selector = "relay";
                                allow_username_mismatch = true;
                              '';
                            };
                            "arc.conf" = lib.mkIf srv.dkim.enable {
                              text = ''
                                path = "${jail.secrets.${srv.dkim.privKeySecret}.path or ""}";
                                selector = "relay";
                                allow_username_mismatch = true;
                              '';
                            };
                            "antivirus.conf" = lib.mkIf srv.antivirus.enable {
                              text = ''
                                clamav {
                                  action = "reject";
                                  message = "VIRUS FOUND";
                                  symbol = "CLAM_VIRUS";
                                  type = "clamav";
                                  servers = "/run/clamav/clamd.ctl";
                                }
                              '';
                            };
                          };
                        };

                        users.users.postfix = {
                          isSystemUser = true;
                          group = "postfix";
                          extraGroups = [ "rspamd" ] ++ (lib.mapAttrsToList (certName: cert: cert.group) jail.tls.certs);
                        };

                        systemd.services.postfix.wants = [ "network-online.target" ];
                        systemd.services.postfix.after = [ "network-online.target" ];

                        services.postfix = {
                          enable = true;
                          transport = lib.concatMapAttrsStringSep "\n" (
                            routeName: route:
                            let
                              endpoint = alloy.endpoints.${route.upstream.endpoint};
                            in
                            "${mkDomain route.domain} route_${routeName}:[${endpoint.domain}]:${toString endpoint.port}"
                          ) srv.routes;
                          settings.main = {
                            myhostname = mkDomain srv.hostname;
                            mydestination = "";
                            mynetworks = lib.pipe srv.routes [
                              (lib.mapAttrsToList (
                                _: route:
                                lib.map (
                                  t: "${if t.ip ? v6 then "[${t.ip.v6}]" else t.ip.v4}"
                                ) alloy.endpoints.${route.upstream.endpoint}.targets
                              ))
                              lib.flatten
                            ];
                            smtpd_relay_restrictions = "permit_mynetworks, reject_unauth_destination";
                            relay_domains = lib.mapAttrsToList (_: route: mkDomain route.domain) srv.routes;
                          }
                          // (lib.optionalAttrs (srv.dkim.enable || srv.antivirus.enable) {
                            smtpd_milters = "unix:/run/rspamd/rspamd-milter.sock";
                            non_smtpd_milters = "unix:/run/rspamd/rspamd-milter.sock";
                            milter_default_action = "accept";
                          })
                          // (lib.optionalAttrs hasCert {
                            smtpd_tls_cert_file = certCfg.certPath;
                            smtpd_tls_key_file = certCfg.keyPath;
                            smtpd_tls_security_level = if srv.explicitTLS.mode == "optional" then "may" else "encrypt";
                          });

                          settings.master = {
                            "${jail.uplink.ipv4}:25" = {
                              type = "inet";
                              private = false;
                              command = "smtpd";
                            };
                            "[${jail.uplink.ipv6}]:25" = {
                              type = "inet";
                              private = false;
                              command = "smtpd";
                            };
                          }
                          // (lib.mapAttrs' (
                            _: overlay:
                            lib.nameValuePair "[${overlay.ipv6}]:25" {
                              type = "inet";
                              private = false;
                              command = "smtpd";
                              args = [
                                "-o smtpd_tls_cert_file=${jail.mtls.certPath}"
                                "-o smtpd_tls_key_file=${jail.mtls.keyPath}"
                                "-o smtpd_tls_CAfile=${alloy.mtls.certPath}"
                                "-o smtpd_tls_security_level=encrypt"
                                "-o smtpd_tls_req_ccert=yes"
                                "-o smtpd_client_restrictions=permit_mynetworks,reject"
                              ];
                            }
                          ) jail.overlays)
                          // (lib.mapAttrs' (
                            routeName: route:
                            lib.nameValuePair "route_${routeName}" {
                              type = "unix";
                              command = "smtp";
                              args = [
                                "-o smtp_tls_cert_file=${jail.mtls.certPath}"
                                "-o smtp_tls_key_file=${jail.mtls.keyPath}"
                                "-o smtp_tls_CAfile=${alloy.mtls.certPath}"
                                "-o smtp_tls_security_level=encrypt"
                              ];
                            }
                          ) srv.routes);
                        };
                      };
                  }
                )
              ) srv.hosts;
            };

          services = lib.pipe alloy.services.smtp-edge [
            (lib.filterAttrs (_: srv: srv.enable))
            (lib.mapAttrsToList mkService)
          ];
        in
        {
          warnings = lib.mkMerge (lib.map (s: s.warnings) services);
          assertions = lib.mkMerge (lib.map (s: s.assertions) services);
          generators = lib.mkMerge (lib.map (s: s.generators) services);
          secrets = lib.mkMerge (lib.map (s: s.secrets or { }) services);
          facts = lib.mkMerge (lib.map (s: s.facts or { }) services);
          dns = lib.mkMerge (lib.map (s: s.dns) services);
          endpoints = lib.mkMerge (lib.map (s: s.endpoints) services);
          jails = lib.mkMerge (lib.map (s: s.jails) services);
        };
    };
}
