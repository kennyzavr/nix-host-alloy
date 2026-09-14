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

      serviceSubmodule = { config, name, ... }: {
        options = {
          enable = lib.mkOption {
            default = true;
            type = lib.types.bool;
          };
          endpoint = lib.mkOption {
            default = "ca-${name}";
            type = lib.types.str;
          };
          ca = lib.mkOption {
            type = lib.types.str;
            default = name;
          };
          root = {
            subject = lib.mkOption {
              type = lib.types.str;
              default = "Root ${config.subject}";
            };
            certFact = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              default = "ca/${name}/root/cert.pem";
            };
            keySecret = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              default = "ca/${name}/root/key.pem";
            };
            generator = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              default = "ca/${name}/root";
            };
          };
          intermediate = {
            subject = lib.mkOption {
              type = lib.types.str;
              default = "Intermediate ${config.subject}";
            };
            certFact = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              default = "ca/${name}/intermediate/cert.pem";
            };
            keySecret = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              default = "ca/${name}/intermediate/key.pem";
            };
            generator = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              default = "ca/${name}/intermediate";
            };
          };
          overlays = lib.mkOption {
            default = [ ];
            type = lib.types.attrsOf (lib.types.submodule { });
          };
          host = lib.mkOption {
            type = lib.types.str;
          };
          domain = lib.mkOption {
            type = alib.types.zoneNode;
          };
          acme = {
            enable = lib.mkOption {
              default = false;
              type = lib.types.bool;
            };
          };
          subject = lib.mkOption {
            type = lib.types.str;
          };
          permittedDomains = lib.mkOption {
            default = [ ];
            type = lib.types.listOf alib.types.zoneNode;
          };
          permittedIps = lib.mkOption {
            default = [ ];
            type = lib.types.listOf (
              lib.types.submodule {
                options.addr = lib.mkOption { type = alib.types.ip.addr; };
                options.prefixLength = lib.mkOption { type = lib.types.int; };
              }
            );
          };
        };
      };

      mkService = srvName: srv: {
        assertions = [
          {
            assertion = builtins.hasAttr srv.host alloy.hosts;
            message = "[Alloy] ca '${srvName}': host '${srv.host}' is unknown";
          }
          {
            assertion = srv.overlays != { };
            message = "[Alloy] Service 'ca.${srvName}': you must specify at least one network overlay in 'overlays' for the endpoint targets.";
          }
        ];

        endpoints.${srv.endpoint} = {
          port = 443;
          targets = lib.mapAttrsToList (overlayName: _: {
            overlay = overlayName;
            ipv6 = alloy.jails."ca-${srvName}".overlays.${overlayName}.ipv6;
          }) srv.overlays;
        };

        tls.ca.${srv.ca} = {
          certFact = srv.root.certFact;
          acme.url = {
            path = "/acme/acme/directory";
            server.endpoint = srv.endpoint;
          };
        };

        facts.${srv.root.certFact} = { };
        secrets.${srv.root.keySecret} = { };
        generators.instances.${srv.root.generator} = {
          imports = [ alloy.generators.templates."tls/x509-cert/ca" ];

          tags = [
            "ca"
            "ca/${srvName}"
          ];

          certFact = srv.root.certFact;
          keySecret = srv.root.keySecret;

          subject = srv.root.subject;
          permitted = {
            domains = lib.map (
              d: lib.removePrefix "." (lib.removeSuffix "." (alloy.dns.resolveNode d))
            ) srv.permittedDomains;
            ips = srv.permittedIps;
          };
          maxPathLen = 1;
        };

        facts.${srv.intermediate.certFact} = { };
        secrets.${srv.intermediate.keySecret} = { };
        generators.instances.${srv.intermediate.generator} = {
          imports = [ alloy.generators.templates."tls/x509-cert/ca" ];

          tags = [
            "ca"
            "ca/${srvName}"
          ];

          wants = [ srv.root.generator ];

          parent = {
            certFact = srv.root.certFact;
            keySecret = srv.root.keySecret;
          };

          certFact = srv.intermediate.certFact;
          keySecret = srv.intermediate.keySecret;

          subject = srv.intermediate.subject;
          maxPathLen = 0;
        };

        jails."ca-${srvName}" =
          { config, ... }:
          let
            jail = config;
          in
          {
            host = srv.host;

            overlays = lib.mapAttrs (_: _: { }) srv.overlays;

            endpoints.${srv.endpoint} = { };

            volumes."db" = {
              path = "/var/lib/step-ca/db";
              driver.directory = { };
              permissions = {
                owner = "step-ca";
                group = "step-ca";
                mode = "0750";
              };
            };

            secrets.${srv.intermediate.keySecret} = {
              permissions = {
                owner = "step-ca";
                group = "step-ca";
                mode = "0440";
              };
            };

            mtls.permissions = {
              owner = "nginx";
              group = "nginx";
              mode = "0440";
            };

            nixosModule = { pkgs, ... }: {
              networking.firewall.allowedTCPPorts = [ 443 ];

              services.nginx = {
                enable = true;
                virtualHosts."_" = {
                  default = true;
                  onlySSL = true;
                  sslCertificate = jail.mtls.certPath;
                  sslCertificateKey = jail.mtls.keyPath;
                  locations."/" = {
                    proxyPass = "https://127.0.0.1:8443";
                    recommendedProxySettings = true;
                  };
                };
              };

              systemd.services.step-ca = {
                serviceConfig = {
                  PrivateUsers = lib.mkForce false;
                  DynamicUser = lib.mkForce false;
                };
              };
              services.step-ca = {
                enable = true;
                address = "127.0.0.1";
                port = 8443;
                settings = {
                  root = alloy.facts.${srv.root.certFact}.path;
                  crt = alloy.facts.${srv.intermediate.certFact}.path;
                  key = jail.secrets.${srv.intermediate.keySecret}.path;
                  dnsNames = [
                    (lib.removeSuffix "." (alloy.dns.resolveNode srv.domain))
                  ];
                  logger.format = "text";
                  db = {
                    type = "badgerv2";
                    dataSource = "/var/lib/step-ca/db";
                    badgerFileLoadingMode = "";
                  };
                  authority = {
                    claims = {
                      minTLSCertDuration = "5m";
                      maxTLSCertDuration = "24h";
                      defaultTLSCertDuration = "24h";
                      disableRenewal = false;
                      allowedRenewalAfterExpiry = false;
                      minHostSSHCertDuration = "5m";
                      maxHostSSHCertDuration = "1680h";
                      defaultHostSSHCertDuration = "720h";
                      minUserSSHCertDuration = "5m";
                      maxUserSSHCertDuration = "24h";
                      defaultUserSSHCertDuration = "16h";
                    };
                    policy.x509 = {
                      allowWildcardNames = false;
                    };
                    provisioners = lib.optionals (srv.acme.enable) [
                      {
                        type = "ACME";
                        name = "acme";
                      }
                    ];
                  };
                  tls = {
                    cipherSuites = [
                      "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256"
                      "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"
                    ];
                    minVersions = 1.2;
                    maxVersions = 1.3;
                    renegoration = false;
                  };
                };
              };
            };
          };
      };
    in
    {
      options.services.ca = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule serviceSubmodule);
      };

      config =
        let
          services = lib.pipe alloy.services.ca [
            (lib.filterAttrs (_: srv: srv.enable))
            (lib.mapAttrsToList mkService)
          ];
        in
        {
          assertions = lib.mkMerge (lib.map (s: s.assertions) services);
          generators.instances = lib.mkMerge (lib.map (s: s.generators.instances) services);
          endpoints = lib.mkMerge (lib.map (s: s.endpoints) services);
          tls.ca = lib.mkMerge (lib.map (s: s.tls.ca) services);
          facts = lib.mkMerge (lib.map (s: s.facts) services);
          secrets = lib.mkMerge (lib.map (s: s.secrets) services);
          jails = lib.mkMerge (lib.map (s: s.jails) services);
        };
    };
}
