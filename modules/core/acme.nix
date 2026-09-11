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

      resolveFqdn =
        node:
        if node.name == "@" then
          alloy.dns.zones.${node.zone}.apex
        else
          "${node.name}.${alloy.dns.zones.${node.zone}.apex}";

      acmeCertSubmodule = { name, ... }: {
        options = {
          group = lib.mkOption {
            type = lib.types.str;
            default = "acme";
          };
          domains = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
          };
          certPath = lib.mkOption {
            type = lib.types.str;
            readOnly = true;
          };
          keyPath = lib.mkOption {
            type = lib.types.str;
            readOnly = true;
          };
        };
        config = {
          certPath = "/var/lib/acme/${name}/fullchain.pem";
          keyPath = "/var/lib/acme/${name}/key.pem";
        };
      };

      mkDnsAcmeCert =
        isJail: nodeName: nodeConfig: acmeCertName: acmeCert:
        let
          cert = alloy.tls.certs.${acmeCertName};
          ca = alloy.tls.ca.${cert.ca};
          ch = cert.acme.challenge.dns;

          primaryDomain = resolveFqdn (builtins.head cert.domains);
          globalExtraDomains = lib.map resolveFqdn (builtins.tail cert.domains);

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
          missingOverlays = lib.filter (o: !(builtins.hasAttr o nodeConfig.overlays)) requiredOverlays;
        in
        {
          assertions = [
            {
              assertion = missingOverlays == [ ];
              message = "[Alloy] Node '${nodeName}': Uses ACME cert '${acmeCertName}', but is missing required overlays: ${lib.concatStringsSep ", " missingOverlays}";
            }
          ];

          secrets.${ch.tsigKeySecret} = { };

          secretTemplates."tls-acme-${acmeCertName}-creds" = {
            permissions = {
              owner = "acme";
              group = "acme";
              mode = "0400";
            };
            template = ''
              DNSUPDATE_TSIG_KEY=${alloy.dns.mkTsigKeyId ch.tsigKeySecret}
              DNSUPDATE_TSIG_ALGORITHM=hmac-sha256.
              DNSUPDATE_TSIG_SECRET=${nodeConfig.secrets.${ch.tsigKeySecret}.placeholder}
              DNSUPDATE_NAMESERVER=[${chEndpoint.domain}]:${toString chEndpoint.port}
              DNSUPDATE_PROPAGATION_TIMEOUT=5
            '';
          };

          nixosModule = {
            security.acme.acceptTerms = true;
            security.acme.certs.${primaryDomain} = {
              email = cert.acme.email;
              server = serverUrl;
              domain = primaryDomain;
              extraDomainNames = globalExtraDomains;
              group = acmeCert.group;
              dnsProvider = "dnsupdate";
              # extraLegoFlags = [ "--dns.propagation-disable-ans" "--dns.resolvers" "127.0.0.1:53" "--http-timeout" "15" ];
              environmentFile = nodeConfig.secretTemplates."tls-acme-${acmeCertName}-creds".path;
            };
          };
        };

      mkNode =
        isJail: nodeName: nodeConfig:
        let
          dnsCerts = lib.filterAttrs (n: v: alloy.tls.certs.${n}.acme.challenge ? dns) nodeConfig.acme.certs;
        in
        (lib.optional isJail {
          volumes."acme-certs" = {
            path = "/var/lib/acme";
            driver.directory = { };
            permissions = {
              owner = "acme";
              group = "acme";
              mode = "0750";
            };
          };
        })
        ++ (lib.mapAttrsToList (n: v: mkDnsAcmeCert isJail nodeName nodeConfig n v) dnsCerts);
    in
    {
      options.hosts = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, config, ... }: {
              options.acme = {
                certs = lib.mkOption {
                  default = { };
                  type = lib.types.attrsOf (lib.types.submodule acmeCertSubmodule);
                };
              };
              config =
                let
                  configs = mkNode false name config;
                in
                {
                  secrets = lib.mkMerge (lib.catAttrs "secrets" configs);
                  secretTemplates = lib.mkMerge (lib.catAttrs "secretTemplates" configs);
                  nixosModule = lib.mkMerge (lib.catAttrs "nixosModule" configs);
                  assertions = lib.mkMerge (lib.catAttrs "assertions" configs);
                };
            }
          )
        );
      };

      options.jails = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, config, ... }: {
              options.acme = {
                certs = lib.mkOption {
                  default = { };
                  type = lib.types.attrsOf (lib.types.submodule acmeCertSubmodule);
                };
              };
              config =
                let
                  configs = mkNode true name config;
                in
                {
                  volumes = lib.mkMerge (lib.catAttrs "volumes" configs);
                  secrets = lib.mkMerge (lib.catAttrs "secrets" configs);
                  secretTemplates = lib.mkMerge (lib.catAttrs "secretTemplates" configs);
                  nixosModule = lib.mkMerge (lib.catAttrs "nixosModule" configs);
                  assertions = lib.mkMerge (lib.catAttrs "assertions" configs);
                };
            }
          )
        );
      };
    };
}
