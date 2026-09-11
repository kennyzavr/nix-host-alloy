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

      hostSubmodule = { config, name, ... }: {
        options.static-ca = {
          certFact = lib.mkOption {
            type = lib.types.str;
            default = "static-ca/hosts/${name}/cert.pem";
          };
          keySecret = lib.mkOption {
            type = lib.types.str;
            default = "static-ca/hosts/${name}/key.pem";
          };
          generator = lib.mkOption {
            type = lib.types.str;
            default = "static-ca/hosts/${name}";
          };
          domains = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
          };
        };
        config = {
          secrets.${config.static-ca.keySecret} = { };
        };
      };

      jailSubmodule = { config, name, ... }: {
        options.static-ca = {
          certFact = lib.mkOption {
            type = lib.types.str;
            default = "static-ca/jails/${name}/cert.pem";
          };
          keySecret = lib.mkOption {
            type = lib.types.str;
            default = "static-ca/jails/${name}/key.pem";
          };
          generator = lib.mkOption {
            type = lib.types.str;
            default = "static-ca/jails/${name}";
          };
          domains = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
          };
        };
        config = {
          secrets.${config.static-ca.keySecret} = { };
        };
      };
    in
    {
      options.static-ca = {
        certFact = lib.mkOption {
          type = lib.types.str;
          default = "static-ca/root.crt";
        };
        keySecret = lib.mkOption {
          type = lib.types.str;
          default = "static-ca/root.pem";
        };
        generator = lib.mkOption {
          type = lib.types.str;
          default = "static-ca/root";
        };
      };

      options.hosts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
      };

      options.jails = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule jailSubmodule);
      };

      config =
        let
          hosts = lib.mapAttrsToList (hostName: host: {
            facts.${host.static-ca.certFact} = { };
            secrets.${host.static-ca.keySecret} = { };

            generators.instances.${host.static-ca.generator} = {
              imports = [ alloy.generators.templates."tls/leaf-cert" ];
              tags = [ "static-ca" ];

              wants = [
                alloy.static-ca.generator
              ];

              parent = {
                inherit (alloy.static-ca) certFact keySecret;
              };
              inherit (host.static-ca) certFact keySecret;
              subject = "Alloy Host ${hostName}";
              san.domains =
                host.static-ca.domains ++ (lib.mapAttrsToList (_: overlay: overlay.domain) host.overlays);
              san.ips = lib.mapAttrsToList (_: overlay: {
                addr.v6 = overlay.ipv6;
              }) host.overlays;
            };
          }) alloy.hosts;

          jails = lib.mapAttrsToList (jailName: jail: {
            facts.${jail.static-ca.certFact} = { };
            secrets.${jail.static-ca.keySecret} = { };

            generators.instances.${jail.static-ca.generator} = {
              imports = [ alloy.generators.templates."tls/leaf-cert" ];

              tags = [ "static-ca" ];

              wants = [
                alloy.static-ca.generator
              ];

              parent = {
                inherit (alloy.static-ca) certFact keySecret;
              };
              inherit (jail.static-ca) certFact keySecret;
              subject = "Alloy Jail ${jailName}";
              san.domains =
                jail.static-ca.domains ++ (lib.mapAttrsToList (_: overlay: overlay.domain) jail.overlays);
              san.ips = lib.mapAttrsToList (_: overlay: {
                addr.v6 = overlay.ipv6;
              }) jail.overlays;
            };
          }) alloy.jails;

          configs = lib.flatten (
            [
              {
                facts.${alloy.static-ca.certFact} = { };
                secrets.${alloy.static-ca.keySecret} = { };

                tls.pki.certFacts = [
                  alloy.static-ca.certFact
                ];

                generators.instances.${alloy.static-ca.generator} = {
                  imports = [ alloy.generators.templates."tls/ca-cert" ];

                  tags = [ "static-ca" ];

                  certFact = alloy.static-ca.certFact;
                  keySecret = alloy.static-ca.keySecret;

                  subject = "Alloy Root CA";

                  notAfter = "8760h";
                  maxPathLen = 0;

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
        };
    };
}
