{
  flake.alloyModules.core =
    { lib, config, ... }:
    let
      alloy = config;

      acmeCertSubmodule =
        { name, config, ... }:
        {
          options = {
            reloadServices = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
            restartServices = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
            group = lib.mkOption {
              type = lib.types.str;
              default = "alloy-acme-${name}";
            };
            gid = lib.mkOption {
              type = lib.types.int;
              readOnly = true;
              default = 24000 + alloy.tls.certs.${name}.idx;
            };
            directory = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              default = "/var/lib/acme/${name}";
            };
            certPath = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              default = "${config.directory}/fullchain.pem";
            };
            keyPath = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              default = "${config.directory}/key.pem";
            };
            fullPath = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              default = "${config.directory}/full.pem";
            };
            waitService = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              default = "alloy-cert-wait-${name}.service";
            };
            reloadService = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              default = "alloy-cert-reload-${name}.service";
            };
          };
        };

      mkAnchorServices = certName: certCfg: {
        "alloy-cert-wait-${certName}" = {
          description = "Wait for ACME certificate ${certName} to be issued";
          wantedBy = certCfg.reloadServices ++ certCfg.restartServices;
          before = certCfg.reloadServices ++ certCfg.restartServices;
          script = ''
            while [ ! -f ${certCfg.certPath} ]; do
              sleep 1
            done
          '';
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
        };
        "alloy-cert-reload-${certName}" = {
          description = "Reload services when certificate ${certName} is updated";
          script = ''
            ${lib.optionalString (
              certCfg.reloadServices != [ ]
            ) "systemctl try-reload-or-restart ${lib.escapeShellArgs certCfg.reloadServices}"}
            ${lib.optionalString (
              certCfg.restartServices != [ ]
            ) "systemctl try-restart ${lib.escapeShellArgs certCfg.restartServices}"}
          '';
          serviceConfig.Type = "oneshot";
        };
      };

      mkAnchorPaths = certName: certCfg: {
        "alloy-cert-reload-${certName}" = {
          wantedBy = [ "multi-user.target" ];
          pathConfig.PathModified = certCfg.certPath;
        };
      };

    in
    {
      options = {
        jails = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule (
              { name, config, ... }: {
                options.acme.certs = lib.mkOption {
                  default = { };
                  type = lib.types.attrsOf (lib.types.submodule acmeCertSubmodule);
                };
                config = {
                  nixosModule = {
                    users.groups = lib.mapAttrs' (
                      certName: certCfg:
                      lib.nameValuePair certCfg.group {
                        gid = certCfg.gid;
                      }
                    ) config.acme.certs;
                    systemd.services = lib.mkMerge (lib.mapAttrsToList mkAnchorServices config.acme.certs);
                    systemd.paths = lib.mkMerge (lib.mapAttrsToList mkAnchorPaths config.acme.certs);
                  };
                };
              }
            )
          );
        };
        hosts = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule (
              hostSubmodule@{ name, config, ... }:
              {
                options.acme.certs = lib.mkOption {
                  default = { };
                  type = lib.types.attrsOf (lib.types.submodule acmeCertSubmodule);
                };
                config =
                  let
                    hostCerts = hostSubmodule.config.acme.certs;
                    jailCerts = lib.foldl' (acc: jail: acc // jail.acme.certs) { } (
                      lib.attrValues (lib.filterAttrs (_: j: j.host == name) alloy.jails)
                    );
                    allCerts = hostCerts // jailCerts;

                    mkDnsCert =
                      certName: certCfg:
                      let
                        cert = alloy.tls.certs.${certName};
                        ca = alloy.tls.ca.${cert.ca};
                        ch = cert.acme.challenge.dns;

                        domains = lib.map (d: lib.removeSuffix "." (alloy.dns.resolveNode d)) cert.domains;
                        primaryDomain = builtins.head domains;
                        globalExtraDomains = builtins.tail domains;

                        serverUrl =
                          if ca.acme.directory != null && ca.acme.directory ? url then
                            ca.acme.directory.url
                          else if ca.acme.directory != null && ca.acme.directory ? endpoint then
                            let
                              endpoint = alloy.endpoints.${ca.acme.directory.endpoint.name};
                              path = ca.acme.directory.endpoint.path;
                            in
                            "https://${endpoint.domain}:${toString endpoint.port}/${lib.removePrefix "/" path}"
                          else
                            "https://acme-v02.api.letsencrypt.org/directory";

                        caOverlays =
                          if (ca.acme.directory != null && ca.acme.directory ? endpoint) then
                            lib.unique (lib.map (t: t.overlay) alloy.endpoints.${ca.acme.directory.endpoint.name}.targets)
                          else
                            [ ];

                        chEndpoint = alloy.endpoints.${ch.endpoint};
                        chOverlays = lib.unique (lib.map (t: t.overlay) chEndpoint.targets);

                        requiredOverlays = lib.unique (caOverlays ++ chOverlays);
                        missingOverlays = lib.filter (
                          o: !(builtins.hasAttr o hostSubmodule.config.overlays)
                        ) requiredOverlays;
                      in
                      {
                        assertions = [
                          {
                            assertion = missingOverlays == [ ];
                            message = "[Alloy] Host '${name}': Uses ACME cert '${certName}', but is missing required overlays: ${lib.concatStringsSep ", " missingOverlays}";
                          }
                        ];

                        secrets.${ch.tsigKeySecret} = { };

                        secretTemplates."tls-acme-${certName}-creds" = {
                          permissions = {
                            owner = "acme";
                            group = "acme";
                            mode = "0400";
                          };
                          template = ''
                            DNSUPDATE_TSIG_KEY=${alloy.dns.mkTsigKeyId ch.tsigKeySecret}
                            DNSUPDATE_TSIG_ALGORITHM=hmac-sha256.
                            DNSUPDATE_TSIG_SECRET=${hostSubmodule.config.secrets.${ch.tsigKeySecret}.placeholder}
                            DNSUPDATE_NAMESERVER=${chEndpoint.domain}:${toString chEndpoint.port}
                            DNSUPDATE_PROPAGATION_TIMEOUT=5
                          '';
                        };

                        nixosModule = {
                          security.acme.acceptTerms = true;
                          security.acme.certs.${certName} = {
                            email = cert.acme.email;
                            server = serverUrl;
                            domain = primaryDomain;
                            extraDomainNames = globalExtraDomains;
                            group = lib.mkForce certCfg.group;
                            dnsProvider = "dnsupdate";
                            extraLegoFlags = [ "--dns.propagation-disable-ans" ];
                            environmentFile = hostSubmodule.config.secretTemplates."tls-acme-${certName}-creds".path;
                          };
                        };
                      };

                    configs = lib.pipe allCerts [
                      (lib.filterAttrs (certName: _: alloy.tls.certs.${certName}.acme.challenge ? dns))
                      (lib.mapAttrsToList mkDnsCert)
                    ];
                  in
                  {
                    secrets = lib.mkMerge (lib.catAttrs "secrets" configs);
                    secretTemplates = lib.mkMerge (lib.catAttrs "secretTemplates" configs);
                    assertions = lib.mkMerge (lib.catAttrs "assertions" configs);
                    nixosModule = {
                      containers = lib.mapAttrs' (
                        jailName: jail:
                        lib.nameValuePair "alloy-jail-${jailName}" {
                          bindMounts = lib.mapAttrs' (
                            certName: certCfg:
                            lib.nameValuePair certCfg.directory {
                              hostPath = certCfg.directory;
                              isReadOnly = true;
                            }
                          ) jail.acme.certs;
                        }
                      ) (lib.filterAttrs (_: j: j.host == name) alloy.jails);

                      users.groups = lib.mapAttrs' (
                        certName: certCfg:
                        lib.nameValuePair certCfg.group {
                          gid = certCfg.gid;
                        }
                      ) allCerts;

                      systemd.services = lib.mkMerge (
                        lib.mapAttrsToList mkAnchorServices hostSubmodule.config.acme.certs
                      );
                      systemd.paths = lib.mkMerge (lib.mapAttrsToList mkAnchorPaths hostSubmodule.config.acme.certs);

                      imports = lib.map (c: c.nixosModule) configs;
                    };
                  };
              }
            )
          );
        };
      };
    };
}
