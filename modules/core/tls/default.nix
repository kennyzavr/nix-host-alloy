{
  imports = [
    ./acme.nix
    ./static.nix
    ./generators.nix
  ];

  flake.alloyModules.core =
    {
      alib,
      lib,
      config,
      ...
    }:
    let
      alloy = config;

      certSubmodule =
        { config, name, ... }:
        {
          options = {
            idx = lib.mkOption {
              type = lib.types.ints.unsigned;
              readOnly = true;
              default = alloy.indexes."tls/certs".get name;
            };
            domains = lib.mkOption {
              default = [ ];
              type = lib.types.listOf alib.types.zoneNode;
            };
            ips = lib.mkOption {
              default = [ ];
              type = lib.types.listOf (
                lib.types.submodule {
                  options.addr = lib.mkOption {
                    type = alib.types.ip.addr;
                  };
                }
              );
            };
            ca = lib.mkOption {
              type = lib.types.str;
            };
            src = lib.mkOption {
              type = lib.types.attrTag { };
            };
            assertions = lib.mkOption {
              type = lib.types.listOf alib.types.unspecified;
            };
          };
          config = lib.mkIf (config.src ? acme) {
            assertions = [
              {
                assertion = config.src.acme.email != "";
                message = "[Alloy] Acme cert '${name}': email cant be an empty string";
              }
              {
                assertion = config.domains != [ ];
                message = "[Alloy] Acme cert '${name}': A certificate using ACME DNS challenge must specify at least one domain.";
              }
              {
                assertion = config.ips == [ ];
                message = "[Alloy] Acme cert '${name}': IP addresses (ips) are not allowed when using ACME DNS challenge.";
              }
              (
                let
                  zones = lib.map (d: alloy.dns.zones.${d.zone}) config.domains;
                  dnsServers = builtins.attrNames (builtins.groupBy (z: toString z.tls.acme.server) zones);
                in
                {
                  assertion = builtins.length dnsServers <= 1;
                  message = "[Alloy] Acme cert '${name}': domains span multiple ACME servers, which is not supported in a single certificate.";
                }
              )
            ];
          };
        };

      nodeCertSubmodule = { config, name, ... }: {
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
            default = "tls-cert-${name}";
          };
          gid = lib.mkOption {
            type = lib.types.int;
            readOnly = true;
            default = 24000 + alloy.tls.certs.${name}.idx;
          };
          certPath = lib.mkOption {
            type = lib.types.str;
          };
          keyPath = lib.mkOption {
            type = lib.types.str;
          };
          fullPath = lib.mkOption {
            type = lib.types.str;
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

      caSubmodule = {
        options = {
          certFact = lib.mkOption {
            default = null;
            type = lib.types.nullOr lib.types.str;
          };
        };
      };

      mkConsumerConfig =
        {
          node,
          certName,
          lCert,
          gCert,
        }:
        {
          nixosModule = {
            systemd.services."alloy-cert-wait-${certName}" = {
              description = "Wait for certificate ${certName} to be issued/generated";
              wantedBy = lCert.reloadServices ++ lCert.restartServices;
              before = lCert.reloadServices ++ lCert.restartServices;
              script = ''
                while [ ! -f ${lCert.certPath} ]; do
                  sleep 1
                done
              '';
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
            };
            systemd.services."alloy-cert-reload-${certName}" = {
              description = "Reload services when certificate ${certName} is updated";
              script = ''
                ${lib.optionalString (
                  lCert.reloadServices != [ ]
                ) "systemctl try-reload-or-restart ${lib.escapeShellArgs lCert.reloadServices}"}
                ${lib.optionalString (
                  lCert.restartServices != [ ]
                ) "systemctl try-restart ${lib.escapeShellArgs lCert.restartServices}"}
              '';
              serviceConfig.Type = "oneshot";
            };
            systemd.paths."alloy-cert-reload-${certName}" = {
              wantedBy = [ "multi-user.target" ];
              pathConfig.PathModified = lCert.certPath;
            };
          };
        };

      hostSubmodule =
        { config, name, ... }:
        let
          selfCerts = lib.mapAttrsToList (certName: lCert: {
            inherit certName lCert;
            node = config;
            gCert = alloy.tls.certs.${certName};
          }) config.tls.certs;
          configs = lib.map mkConsumerConfig selfCerts;
        in
        {
          options.tls = {
            certs = lib.mkOption {
              default = { };
              type = lib.types.attrsOf (lib.types.submodule nodeCertSubmodule);
            };
          };
          config = {
            nixosModule = lib.mkMerge [
              (lib.mkMerge (lib.catAttrs "nixosModule" configs))
              {
                security.pki.certificates = lib.pipe alloy.tls.ca [
                  (lib.filterAttrs (_: ca: ca.certFact != null))
                  (lib.mapAttrsToList (_: ca: alloy.facts.${ca.certFact}.value))
                ];
              }
            ];
          };
        };

      jailSubmodule =
        { config, name, ... }:
        let
          selfCerts = lib.mapAttrsToList (certName: lCert: {
            inherit certName lCert;
            node = config;
            gCert = alloy.tls.certs.${certName};
          }) config.tls.certs;
          configs = lib.map mkConsumerConfig selfCerts;
        in
        {
          options.tls = {
            certs = lib.mkOption {
              default = { };
              type = lib.types.attrsOf (lib.types.submodule nodeCertSubmodule);
            };
          };
          config = {
            nixosModule = lib.mkMerge [
              (lib.mkMerge (lib.catAttrs "nixosModule" configs))
              {
                security.pki.certificates = lib.pipe alloy.tls.ca [
                  (lib.filterAttrs (_: ca: ca.certFact != null))
                  (lib.mapAttrsToList (_: ca: alloy.facts.${ca.certFact}.value))
                ];
              }
            ];
          };
        };
    in
    {
      options = {
        tls.certs = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule certSubmodule);
        };
        tls.ca = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule caSubmodule);
        };
        jails = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule (jailSubmodule));
        };
        hosts = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
        };
      };
      config = {
        indexes."tls/certs" = {
          keys = builtins.attrNames alloy.tls.certs;
          minValue = 1;
          maxValue = 999;
        };
      };
    };
}
