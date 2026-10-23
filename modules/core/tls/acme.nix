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
            acceptTerms = lib.mkOption {
              default = false;
              type = lib.types.bool;
            };
            email = lib.mkOption {
              default = "";
              type = lib.types.str;
            };
            challenge = lib.mkOption {
              type = acmeChallengeType certName;
            };
          };
        };

      certSubmodule = { name, ... }: {
        options.src = lib.mkOption {
          type = lib.types.attrTag {
            acme = lib.mkOption {
              type = acmeSourceSubmodule name;
            };
          };
        };
      };

      hostSubmodule = { config, name, ... }: {
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
        config =
          let
            certConfigs =
              [ ]
              ++ (lib.pipe config.tls.certs [
                builtins.attrNames
                (lib.map (certName: {
                  inherit certName;
                  cert = alloy.tls.certs.${certName};
                }))
                (lib.filter (
                  { cert, ... }:
                  cert.src ? acme && cert.src.acme.challenge ? dns && cert.src.acme.challenge.dns ? dnsupdate
                ))
                (lib.map ({ certName, cert }: mkHostDnsupdate name config certName cert))
              ])
              ++ (lib.pipe alloy.jails [
                (lib.mapAttrsToList (
                  jailName: jail: {
                    inherit jailName jail;
                  }
                ))
                (lib.filter ({ jail, ... }: jail.host == name))
                (lib.map (
                  args:
                  lib.mapAttrsToList (
                    certName: _:
                    args
                    // {
                      inherit certName;
                      cert = alloy.tls.certs.${certName};
                    }
                  ) args.jail.tls.certs
                ))
                lib.flatten
                (lib.map (
                  {
                    jail,
                    jailName,
                    certName,
                    cert,
                  }:
                  mkJailDnsupdate jailName jail certName cert
                ))
                (lib.map (cfg: cfg.hostConfig))
              ]);
          in
          {
            warnings = lib.mkMerge (lib.map (c: c.jailConfig.warnings or [ ]) certConfigs);
            secrets = lib.mkMerge (lib.map (c: c.secrets or { }) certConfigs);
            secretTemplates = lib.mkMerge (lib.map (c: c.secretTemplates or { }) certConfigs);
            nixosModule = {
              imports = lib.map (c: c.nixosModule) certConfigs;
            };
          };
      };

      jailSubmodule = { config, name, ... }: {
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
        config =
          let
            certConfigs = lib.pipe config.tls.certs [
              builtins.attrNames
              (lib.map (certName: {
                inherit certName;
                cert = alloy.tls.certs.${certName};
              }))
              (lib.filter (
                { cert, ... }:
                cert.src ? acme && cert.src.acme.challenge ? dns && cert.src.acme.challenge.dns ? dnsupdate
              ))
              (lib.map ({ certName, cert }: mkJailDnsupdate name config certName cert))
            ];
          in
          {
            warnings = lib.mkMerge (lib.map (c: c.warnings or [ ]) certConfigs);
          };
      };

      mkHostDnsupdate =
        hostName: host: certName: cert:
        let
          ca = alloy.tls.ca.${cert.ca};
          acmeOpts = cert.src.acme;
          challengeOpts = acmeOpts.challenge.dns.dnsupdate;
          hostCert = host.tls.certs.${certName};
          domains = lib.map (d: lib.removeSuffix "." (alloy.dns.resolveNode d)) cert.domains;
          primaryDomain = builtins.head domains;
          globalExtraDomains = builtins.tail domains;
        in
        {
          warnings = lib.optional (ca.acme.url.server ? endpoint) (
            alloy.mkEndpointOverlaysWarn ca.acme.url.server.endpoint (builtins.attrNames host.overlays)
              "host '${hostName}': acme dnsupdate cert '${certName}':"
          );

          secrets.${challengeOpts.tsigKey.secret} = {
            permissions = {
              owner = "acme";
              group = "acme";
              mode = "0640";
            };
          };

          secretTemplates."tls/certs/${certName}/acme/dnsupdate/creds" = {
            permissions = {
              owner = "acme";
              group = "acme";
              mode = "0400";
            };
            template = ''
              DNSUPDATE_TSIG_KEY=${challengeOpts.tsigKey.name}
              DNSUPDATE_TSIG_ALGORITHM=${challengeOpts.tsigKey.alg}
              DNSUPDATE_TSIG_SECRET=${host.secrets.${challengeOpts.tsigKey.secret}.placeholder}
              DNSUPDATE_NAMESERVER=${serverToString challengeOpts.server}
              DNSUPDATE_PROPAGATION_TIMEOUT=5
              DNSUPDATE_TTL=5
            '';
          };

          nixosModule = { pkgs, ... }: {
            users.groups.${hostCert.group} = {
              gid = hostCert.gid;
            };
            systemd.services."acme-order-renew-tls-acme-${certName}" = {
              serviceConfig.ExecStartPre = "+${pkgs.coreutils}/bin/sleep ${toString ((host.idx) * 20)}";
            };
            security.acme.acceptTerms = acmeOpts.acceptTerms;
            security.acme.certs."tls-acme-${certName}" = {
              email = acmeOpts.email;
              server = toString ca.acme.url;
              domain = primaryDomain;
              extraDomainNames = globalExtraDomains;
              group = lib.mkForce hostCert.group;
              dnsProvider = "dnsupdate";
              environmentFile = host.secretTemplates."tls/certs/${certName}/acme/dnsupdate/creds".path;
            };
          };
        };

      mkJailDnsupdate =
        jailName: jail: certName: cert:
        let
          host = alloy.hosts.${jail.host};
          ca = alloy.tls.ca.${cert.ca};
          acmeOpts = cert.src.acme;
          challengeOpts = acmeOpts.challenge.dns.dnsupdate;
          jailCert = jail.tls.certs.${certName};
          domains = lib.map (d: lib.removeSuffix "." (alloy.dns.resolveNode d)) cert.domains;
          primaryDomain = builtins.head domains;
          globalExtraDomains = builtins.tail domains;
        in
        {
          hostConfig = {
            secrets.${challengeOpts.tsigKey.secret} = {
              permissions = {
                owner = "acme";
                group = "acme";
                mode = "0640";
              };
            };

            secretTemplates."tls/certs/${certName}/acme/dnsupdate/creds" = {
              permissions = {
                owner = "acme";
                group = "acme";
                mode = "0400";
              };
              template = ''
                DNSUPDATE_TSIG_KEY=${challengeOpts.tsigKey.name}
                DNSUPDATE_TSIG_ALGORITHM=${challengeOpts.tsigKey.alg}
                DNSUPDATE_TSIG_SECRET=${host.secrets.${challengeOpts.tsigKey.secret}.placeholder}
                DNSUPDATE_NAMESERVER=${serverToString challengeOpts.server}
                DNSUPDATE_PROPAGATION_TIMEOUT=5
                DNSUPDATE_TTL=5
              '';
            };

            nixosModule = { pkgs, ... }: {
              users.groups.${jailCert.group} = {
                gid = jailCert.gid;
              };
              systemd.services."acme-order-renew-tls-acme-${certName}" = {
                serviceConfig.ExecStartPre = "+${pkgs.coreutils}/bin/sleep ${toString ((host.idx) * 20)}";
              };
              security.acme.acceptTerms = acmeOpts.acceptTerms;
              security.acme.certs."tls-acme-${certName}" = {
                email = acmeOpts.email;
                server = toString ca.acme.url;
                domain = primaryDomain;
                extraDomainNames = globalExtraDomains;
                group = lib.mkDefault jailCert.group;
                dnsProvider = "dnsupdate";
                environmentFile = host.secretTemplates."tls/certs/${certName}/acme/dnsupdate/creds".path;
              };

              containers."alloy-jail-${jailName}" = {
                bindMounts."cert-${certName}" = {
                  hostPath = "/var/lib/acme/tls-acme-${certName}";
                  mountPoint = "/var/lib/alloy/certs/${certName}";
                  isReadOnly = true;
                };
                config = {
                  users.groups.${jailCert.group} = {
                    gid = jailCert.gid;
                  };
                };
              };
            };
          };

          jailConfig = {
            warnings = lib.optional (ca.acme.url.server ? endpoint) (
              alloy.mkEndpointOverlaysWarn ca.acme.url.server.endpoint (builtins.attrNames jail.overlays)
                "jail '${jailName}': acme dnsupdate cert '${certName}':"
            );
          };
        };
    in
    {
      options.hosts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
      };

      options.jails = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule jailSubmodule);
      };

      options.tls.certs = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule certSubmodule);
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
    };
}
