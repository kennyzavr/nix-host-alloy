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
          domain = lib.mkOption {
            type = alib.types.zoneNode;
          };
          postmaster = lib.mkOption {
            type = lib.types.str;
            default = "postmaster@${alloy.dns.resolveNode config.domain}";
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
            default = "smtp-edge-${name}";
          };
          hostname = lib.mkOption {
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
          dkim = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
            dmarcPolicy = lib.mkOption {
              default = "reject";
              type = lib.types.enum [
                "none"
                "quarantine"
                "reject"
              ];
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
            };
          };
        };
      };
    in
    {
      options.services.smtp-edge = lib.mkOption {
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
                  message = "[Alloy] smtp-edge name '${srvName}' must be valid dns label.";
                }
                {
                  assertion =
                    srv.allowedOverlays != [ ]
                    -> lib.all (overlayName: builtins.elem overlayName srv.allowedOverlays) allOverlays;
                  message = "[Alloy] smtp-edge '${srvName}': there are some endpoint targets with addresses outside of the allowed overlays";
                }
                {
                  assertion = srv.hosts != { };
                  message = "[Alloy] smtp-edge '${srvName}': at least one host must be specified";
                }
                {
                  assertion = srv.routes != { };
                  message = "[Alloy] smtp-edge '${srvName}': at least one route must be specified";
                }
                {
                  assertion = srv.explicitTLS.mode != "none" -> srv.explicitTLS.cert != null;
                  message = "[Alloy] smtp-edge '${srvName}' specifies explicitTLS.mode '${srv.explicitTLS.mode}' but explicitTLS.cert is not set. You must specify a valid certificate reference in 'explicitTLS.cert'.";
                }
                {
                  assertion = (srv.explicitTLS.cert != null) -> builtins.hasAttr srv.explicitTLS.cert alloy.tls.certs;
                  message = "[Alloy] smtp-edge '${srvName}' explicitTLS.cert refers to an unknown TLS certificate '${srv.explicitTLS.cert}'. Please ensure it is defined in 'config.tls.certs'.";
                }
                {
                  assertion =
                    srv.explicitTLS.mode != "none"
                    -> (srv.explicitTLS.cert != null)
                    -> builtins.hasAttr srv.explicitTLS.cert alloy.tls.certs
                    -> builtins.elem srv.hostname alloy.tls.certs.${srv.explicitTLS.cert}.domains;
                  message = "[Alloy] smtp-edge '${srvName}' explicitTLS.cert does not contain hostname of the smtp-edge";
                }
              ]
              ++ (lib.flatten (
                lib.mapAttrsToList (hostName: hostCfg: [
                  {
                    assertion = builtins.hasAttr hostName alloy.hosts;
                    message = "[Alloy] smtp-edge '${srvName}': host '${hostName}' is unknown";
                  }
                  {
                    assertion = builtins.hasAttr hostName alloy.hosts -> (hostCfg.ipv4 != null || hostCfg.ipv6 != null);
                    message = "[Alloy] smtp-edge '${srvName}': host '${hostName}' must have specified at least one ip address (ipv4 or ipv6)";
                  }
                ]) srv.hosts
              ))
              ++ (lib.flatten (
                lib.mapAttrsToList (routeName: route: [
                  {
                    assertion = alib.types.dns.label.check routeName;
                    message = "[Alloy] smtp-edge '${srvName}': route name '${routeName}' must be valid dns label.";
                  }
                  {
                    assertion = builtins.hasAttr route.upstream.endpoint alloy.endpoints;
                    message = "[Alloy] smtp-edge '${srvName}': route '${routeName}' refers to an unknown endpoint '${route.upstream.endpoint}'.";
                  }
                ]) srv.routes
              ));

              dns.records = lib.optionals srv.addDnsRecords (
                lib.flatten (
                  [ ]
                  ++ (lib.mapAttrsToList (
                    _: hostCfg:
                    [ ]
                    ++ (lib.optional (hostCfg.ipv4 != null) {
                      domain = srv.hostname;
                      data.a = hostCfg.ipv4;
                    })
                    ++ (lib.optional (hostCfg.ipv6 != null) {
                      domain = srv.hostname;
                      data.aaaa = hostCfg.ipv6;
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
                      ipv6 = alloy.jails."smtp-edge-${srvName}-${hostName}".overlays.${overlayName}.ipv6;
                      overlay = overlayName;
                    }) allOverlays
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
                  { pkgs, ... }:
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
                lib.nameValuePair "smtp-edge-${srvName}-${hostName}" (
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
                                _: route: lib.map (t: "[${t.ipv6}]") alloy.endpoints.${route.upstream.endpoint}.targets
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
          assertions = lib.mkMerge (lib.map (s: s.assertions) services);
          generators = lib.mkMerge (lib.map (s: s.generators) services);
          secrets = lib.mkMerge (lib.map (s: s.secrets or {}) services);
          facts = lib.mkMerge (lib.map (s: s.facts or {}) services);
          dns = lib.mkMerge (lib.map (s: s.dns) services);
          endpoints = lib.mkMerge (lib.map (s: s.endpoints) services);
          jails = lib.mkMerge (lib.map (s: s.jails) services);
        };
    };
}
