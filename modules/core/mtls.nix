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

      mtlsGlobalCertFact = "mtls/root/cert.pem";
      mtlsGlobalKeySecret = "mtls/root/cert.key";
      mtlsGlobalGenerator = "mtls/root";

      nodeSubmodule =
        type:
        { config, name, ... }:
        let
          nodeName = name;
          certFact = "mtls/${type}s/${nodeName}/cert.pem";
          keySecret = "mtls/${type}s/${nodeName}/key.pem";
        in
        {
          options.mtls = {
            certPath = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
            };
            keyPath = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
            };
            fullPath = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
            };
            permissions = lib.mkOption {
              type = alib.types.permissions;
              default = {
                owner = "root";
                group = "root";
                mode = "0400";
              };
            };
          };
          config = {
            mtls = {
              certPath = config.secretTemplates."mtls/cert.pem".path;
              keyPath = config.secretTemplates."mtls/key.pem".path;
              fullPath = config.secretTemplates."mtls/full.pem".path;
            };

            nixosModule = {
              security.pki.certificates = [
                alloy.facts.${mtlsGlobalCertFact}.value
              ];
            };

            secrets.${keySecret} = { };

            secretTemplates."mtls/cert.pem" = {
              template = alloy.facts.${certFact}.value;
              inherit (config.mtls) permissions;
              path = "/run/alloy/mtls/cert.pem";
            };
            secretTemplates."mtls/key.pem" = {
              template = config.secrets.${keySecret}.placeholder;
              inherit (config.mtls) permissions;
              path = "/run/alloy/mtls/key.pem";
            };
            secretTemplates."mtls/full.pem" = {
              template = ''
                ${alloy.facts.${certFact}.value}
                ${config.secrets.${keySecret}.placeholder}
              '';
              inherit (config.mtls) permissions;
              path = "/run/alloy/mtls/full.pem";
            };
          };
        };
    in
    {
      options.mtls = {
        certPath = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
        };
      };

      options.hosts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule (nodeSubmodule "host"));
      };

      options.jails = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule (nodeSubmodule "jail"));
      };

      config =
        let
          hosts = lib.mapAttrsToList (
            hostName: host:
            let
              certFact = "mtls/hosts/${hostName}/cert.pem";
              keySecret = "mtls/hosts/${hostName}/key.pem";
              generatorName = "mtls/hosts/${hostName}";
            in
            {
              facts.${certFact} = { };

              generators.instances.${generatorName} = {
                imports = [ alloy.generators.templates."tls/x509-cert/leaf" ];
                tags = [ "mtls" ];

                wants = [ mtlsGlobalGenerator ];

                parent = {
                  certFact = mtlsGlobalCertFact;
                  keySecret = mtlsGlobalKeySecret;
                };
                inherit certFact keySecret;
                subject = "Alloy Host ${hostName}";
                san.domains = [
                  host.domain
                ]
                ++ (lib.mapAttrsToList (_: overlay: overlay.domain) host.overlays)
                ++ (lib.flatten (
                  lib.mapAttrsToList (
                    epName: _:
                    [ alloy.endpoints.${epName}.domain ]
                    ++ (lib.mapAttrsToList (_: o: o.domain) alloy.endpoints.${epName}.overlays)
                  ) host.endpoints
                ));
                san.ips = lib.mapAttrsToList (_: overlay: {
                  addr.v6 = overlay.ipv6;
                }) host.overlays;
              };
            }
          ) alloy.hosts;

          jails = lib.mapAttrsToList (
            jailName: jail:
            let
              certFact = "mtls/jails/${jailName}/cert.pem";
              keySecret = "mtls/jails/${jailName}/key.pem";
              generatorName = "mtls/jails/${jailName}";
            in
            {
              facts.${certFact} = { };

              generators.instances.${generatorName} = {
                imports = [ alloy.generators.templates."tls/x509-cert/leaf" ];
                tags = [ "mtls" ];

                wants = [ mtlsGlobalGenerator ];

                parent = {
                  certFact = mtlsGlobalCertFact;
                  keySecret = mtlsGlobalKeySecret;
                };
                inherit certFact keySecret;
                subject = "Alloy Jail ${jailName}";
                san.domains = [
                  jail.domain
                ]
                ++ (lib.mapAttrsToList (_: overlay: overlay.domain) jail.overlays)
                ++ (lib.flatten (
                  lib.mapAttrsToList (
                    epName: _:
                    [ alloy.endpoints.${epName}.domain ]
                    ++ (lib.mapAttrsToList (_: o: o.domain) alloy.endpoints.${epName}.overlays)
                  ) jail.endpoints
                ));
                san.ips = lib.mapAttrsToList (_: overlay: {
                  addr.v6 = overlay.ipv6;
                }) jail.overlays;
              };
            }
          ) alloy.jails;

          configs = lib.flatten (
            [
              {
                mtls.certPath = alloy.facts.${mtlsGlobalCertFact}.path;

                facts.${mtlsGlobalCertFact} = { };
                secrets.${mtlsGlobalKeySecret} = { };

                generators.instances.${mtlsGlobalGenerator} = {
                  imports = [ alloy.generators.templates."tls/x509-cert/ca" ];

                  tags = [ "mtls" ];

                  certFact = mtlsGlobalCertFact;
                  keySecret = mtlsGlobalKeySecret;

                  subject = "Alloy Root CA";

                  notAfter = "8760h";
                  maxPathLen = 0;

                  permitted.domains = [ alloy.dns.internalDomain ];
                  permitted.ips = lib.mapAttrsToList (_: overlay: {
                    addr.v6 = "${overlay.ipv6Prefix}:0000:0000:0000:0000:0000";
                    prefixLength = 48;
                  }) alloy.overlays;
                };
              }
            ]
            ++ hosts
            ++ jails
          );
        in
        {
          facts = lib.mkMerge (lib.catAttrs "facts" configs);
          secrets = lib.mkMerge (lib.catAttrs "secrets" configs);
          tls = lib.mkMerge (lib.catAttrs "tls" configs);
          generators = lib.mkMerge (lib.catAttrs "generators" configs);
          mtls = lib.mkMerge (lib.catAttrs "mtls" configs);
        };
    };
}
