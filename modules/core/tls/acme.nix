{
  flake.alloyModules.core =
    {
      alib,
      lib,
      config,
      ...
    }:
    let
      alloy = config;

      serverToString =
        server:
        if server ? endpoint then
          let
            endpoint = alloy.endpoints.${server.endpoint};
          in
          "${endpoint.domain}:${toString endpoint.port}"
        else
          server.address;

      mkAssertions =
        req:
        lib.mkIf (req.gCert.src ? acme) (
          let
            opts = req.gCert.src.acme;
            ca = alloy.tls.ca.${req.gCert.ca};
            zones = lib.map (d: alloy.dns.zones.${d.zone}) req.gCert.domains;
            primaryZone = builtins.head zones;
          in
          {
            assertions = (
              lib.optional (ca.acme.url.server ? endpoint) (
                let
                  missing = lib.pipe (alloy.endpoints.${ca.acme.url.server.endpoint}.targets) [
                    (lib.map (t: t.overlay))
                    (lib.filter (o: !(builtins.hasAttr o req.node.overlays)))
                  ];
                in
                {
                  assertion = missing == [ ];
                  message = "[Alloy] ${req.nodeType} '${req.nodeName}' missing acme url overlays for cert '${req.certName}'";
                }
              )
            );
            # ++ (lib.optionals (opts.challenge ? dns && opts.challenge.dns ? dnsupdate) [
            #   {
            #     assertion =
            #       !(primaryZone.acme.server ? endpoint)
            #       || (
            #         let
            #           missing = lib.pipe (alloy.endpoints.${primaryZone.acme.server.endpoint}.targets) [
            #             (lib.map (t: t.overlay))
            #             (lib.filter (o: !(builtins.hasAttr o req.node.overlays)))
            #           ];
            #         in
            #         missing == [ ]
            #       );
            #     message = "[Alloy] ${req.nodeType} '${req.nodeName}' missing dnsupdate overlays for cert '${req.certName}'";
            #   }
            # ]);
          }
        );

      hostSubmodule =
        { config, name, ... }:
        let
          node = config;

          mkHost =
            certName: gCert:
            lib.mkIf (config.tls.certs ? ${certName} && gCert.src ? acme) (mkHostInfrastructure {
              inherit certName gCert;
              nodeName = name;
              nodeType = "Host";
              node = config;
              lCert = config.tls.certs.${certName};
            });

          mkAssertionsHost =
            certName: gCert:
            lib.mkIf (config.tls.certs ? ${certName} && gCert.src ? acme) (mkAssertions {
              inherit certName gCert;
              nodeName = name;
              nodeType = "Host";
              node = config;
              lCert = config.tls.certs.${certName};
            });

          mkJail =
            jailName: jail: certName: gCert:
            lib.mkIf (jail.host == name && jail.tls.certs ? ${certName} && gCert.src ? acme)
              (mkHostInfrastructure {
                inherit certName gCert jailName;
                nodeName = jailName;
                nodeType = "Jail";
                node = jail;
                lCert = jail.tls.certs.${certName};
                host = config;
              });

          mkHostInfrastructure =
            req:
            lib.mkMerge [
              (lib.mkIf (req.gCert.src ? acme) (
                let
                  opts = req.gCert.src.acme;
                  ca = alloy.tls.ca.${req.gCert.ca};
                  domains = lib.map (d: lib.removeSuffix "." (alloy.dns.resolveNode d)) req.gCert.domains;
                  primaryDomain = builtins.head domains;
                  globalExtraDomains = builtins.tail domains;

                  acmeDnsUpdate = lib.mkIf (opts.challenge ? dns && opts.challenge.dns ? dnsupdate) (
                    let
                      dnsOpts = opts.challenge.dns.dnsupdate;
                      zones = lib.map (d: alloy.dns.zones.${d.zone}) req.gCert.domains;
                      primaryZone = builtins.head zones;
                    in
                    {
                      secrets.${dnsOpts.tsigKey.secret} = {
                        permissions = {
                          owner = "acme";
                          group = "acme";
                          mode = "0640";
                        };
                      };
                      secretTemplates."tls/certs/${req.certName}/acme/dnsupdate/creds" = {
                        permissions = {
                          owner = "acme";
                          group = "acme";
                          mode = "0400";
                        };
                        template = ''
                          DNSUPDATE_TSIG_KEY=${dnsOpts.tsigKey.name}
                          DNSUPDATE_TSIG_ALGORITHM=${dnsOpts.tsigKey.alg}
                          DNSUPDATE_TSIG_SECRET=${node.secrets.${dnsOpts.tsigKey.secret}.placeholder}
                          DNSUPDATE_NAMESERVER=${serverToString dnsOpts.server}
                          DNSUPDATE_PROPAGATION_TIMEOUT=5
                          DNSUPDATE_TTL=5
                        '';
                      };
                      nixosModule = {
                        security.acme.certs."tls-acme-${req.certName}" = {
                          dnsProvider = "dnsupdate";
                          environmentFile = node.secretTemplates."tls/certs/${req.certName}/acme/dnsupdate/creds".path;
                        };
                      };
                    }
                  );
                in
                lib.mkMerge [
                  {
                    nixosModule = { pkgs, ... }: {
                      users.groups.${req.lCert.group} = {
                        gid = req.lCert.gid;
                      };
                      systemd.services."acme-order-renew-tls-acme-${req.certName}" = {
                        serviceConfig.ExecStartPre = "+${pkgs.coreutils}/bin/sleep ${toString (req.host.idx * 120)}";
                      };
                      security.acme.acceptTerms = true;
                      security.acme.certs."tls-acme-${req.certName}" = {
                        email = opts.email;
                        server = toString ca.acme.url;
                        domain = primaryDomain;
                        extraDomainNames = globalExtraDomains;
                        group = lib.mkForce req.lCert.group;
                      };
                    };
                  }

                  (lib.mkIf (req ? jailName) {
                    nixosModule.containers."alloy-jail-${req.jailName}" = {
                      bindMounts."cert-${req.certName}" = {
                        hostPath = "/var/lib/acme/tls-acme-${req.certName}";
                        mountPoint = "/var/lib/alloy/certs/${req.certName}";
                        isReadOnly = true;
                      };
                      config = {
                        users.groups.${req.lCert.group} = {
                          gid = req.lCert.gid;
                        };
                      };
                    };
                  })

                  acmeDnsUpdate
                ]
              ))
            ];
        in
        {
          options.tls.certs = lib.mkOption {
            type = lib.types.attrsOf (
              lib.types.submodule (
                { name, ... }: {
                  config = lib.mkIf (alloy.tls.certs.${name}.src ? acme) {
                    certPath = "/var/lib/acme/tls-acme-${name}/fullchain.pem";
                    keyPath = "/var/lib/acme/tls-acme-${name}/key.pem";
                    fullPath = "/var/lib/acme/tls-acme-${name}/full.pem";
                  };
                }
              )
            );
          };

          config = lib.mkMerge (
            (lib.mapAttrsToList mkHost alloy.tls.certs)
            ++ (lib.mapAttrsToList mkAssertionsHost alloy.tls.certs)
            ++ (lib.flatten (
              lib.mapAttrsToList (
                jailName: jail:
                lib.mapAttrsToList (certName: gCert: mkJail jailName jail certName gCert) alloy.tls.certs
              ) alloy.jails
            ))
          );
        };

      jailSubmodule =
        { config, name, ... }:
        let
          mkAssertionsJail =
            certName: gCert:
            lib.mkIf (config.tls.certs ? ${certName} && gCert.src ? acme) (mkAssertions {
              inherit certName gCert;
              nodeName = name;
              nodeType = "Jail";
              node = config;
              lCert = config.tls.certs.${certName};
            });
        in
        {
          options.tls.certs = lib.mkOption {
            type = lib.types.attrsOf (
              lib.types.submodule (
                { name, ... }: {
                  config = lib.mkIf (alloy.tls.certs.${name}.src ? acme) {
                    certPath = "/var/lib/alloy/certs/${name}/fullchain.pem";
                    keyPath = "/var/lib/alloy/certs/${name}/key.pem";
                    fullPath = "/var/lib/alloy/certs/${name}/full.pem";
                  };
                }
              )
            );
          };

          config = lib.mkMerge (lib.mapAttrsToList mkAssertionsJail alloy.tls.certs);
        };

      dnsupdateSubmodule =
        certName:
        lib.types.submodule {
          options = {
            server = lib.mkOption {
              type = alib.types.serverEndpoint;
            };
            tsigKey.alg = lib.mkOption {
              type = alib.types.dns.name;
              default = "hmac-sha256.";
            };
            tsigKey.name = lib.mkOption {
              type = alib.types.dns.name;
              default = "key.dnsupdate.acme.${certName}";
            };
            tsigKey.secret = lib.mkOption {
              type = lib.types.str;
              default = "tls/certs/${certName}/acme/dns-challenge/dnsupdate/tsig-key";
            };
            tsigKey.generator = lib.mkOption {
              type = lib.types.str;
              default = "tls/certs/${certName}/acme/dns-challenge/dnsupdate/tsig-key";
            };
          };
        };

      dnsAcmeChallengeType =
        certName:
        lib.types.attrTag {
          dnsupdate = lib.mkOption {
            type = dnsupdateSubmodule certName;
          };
        };

      acmeChallengeType =
        certName:
        lib.types.attrTag {
          dns = lib.mkOption {
            type = dnsAcmeChallengeType certName;
          };
        };

      acmeSourceSubmodule =
        certName:
        lib.types.submodule {
          options = {
            email = lib.mkOption {
              default = "";
              type = lib.types.str;
            };
            challenge = lib.mkOption {
              type = acmeChallengeType certName;
            };
          };
        };

    in
    {
      options.tls.certs = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, ... }: {
              options.src = lib.mkOption {
                type = lib.types.attrTag {
                  acme = lib.mkOption {
                    type = acmeSourceSubmodule name;
                  };
                };
              };
            }
          )
        );
      };

      options.tls.ca = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options.acme = {
              url = {
                path = lib.mkOption {
                  type = lib.types.str;
                };
                server = lib.mkOption {
                  type = alib.types.serverEndpoint;
                };
                __toString = lib.mkOption {
                  type = lib.types.unspecified;
                  readOnly = true;
                  internal = true;
                  default = url: "https://${serverToString url.server}/${lib.removePrefix "/" url.path}";
                };
              };
            };
          }
        );
      };

      options.jails = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule jailSubmodule);
      };

      options.hosts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
      };
    };
}
