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

      hostSubmodule =
        { config, name, ... }:
        let
          mkHostLevel =
            certName: gCert:
            lib.mkIf (config.tls.certs ? ${certName} && gCert.src ? static) (
              let
                opts = gCert.src.static;
              in
              {
                secrets.${opts.keySecret} = {
                  permissions = {
                    owner = "root";
                    group = config.tls.certs.${certName}.gid;
                    mode = "0640";
                  };
                };
                secretTemplates."tls/certs/${certName}/static/full" = {
                  template = ''
                    ${alloy.facts.${opts.certFact}.value}
                    ${config.secrets.${opts.keySecret}.placeholder}
                  '';
                  permissions = {
                    owner = "root";
                    group = config.tls.certs.${certName}.gid;
                    mode = "0640";
                  };
                };
              }
            );
        in
        {
          options.tls.certs = lib.mkOption {
            type = lib.types.attrsOf (
              lib.types.submodule (
                { name, ... }: {
                  config = lib.mkIf (alloy.tls.certs.${name}.src ? static) (
                    let
                      opts = alloy.tls.certs.${name}.src.static;
                    in
                    {
                      certPath = alloy.facts.${opts.certFact}.path;
                      keyPath = config.secrets.${opts.keySecret}.path;
                      fullPath = config.secretTemplates."tls/certs/${name}/static/full".path;
                    }
                  );
                }
              )
            );
          };
          config = lib.mkMerge (lib.mapAttrsToList mkHostLevel alloy.tls.certs);
        };

      jailSubmodule =
        { config, name, ... }:
        let
          mkHostLevel =
            certName: gCert:
            lib.mkIf (config.tls.certs ? ${certName} && gCert.src ? static) (
              let
                opts = gCert.src.static;
              in
              {
                secrets.${opts.keySecret} = {
                  permissions = {
                    owner = "root";
                    group = config.tls.certs.${certName}.gid;
                    mode = "0640";
                  };
                };
                secretTemplates."tls/certs/${certName}/static/full" = {
                  template = ''
                    ${alloy.facts.${opts.certFact}.value}
                    ${config.secrets.${opts.keySecret}.placeholder}
                  '';
                  permissions = {
                    owner = "root";
                    group = config.tls.certs.${certName}.gid;
                    mode = "0640";
                  };
                };
              }
            );
        in
        {
          options.tls.certs = lib.mkOption {
            type = lib.types.attrsOf (
              lib.types.submodule (
                { name, ... }: {
                  config = lib.mkIf (alloy.tls.certs.${name}.src ? static) (
                    let
                      opts = alloy.tls.certs.${name}.src.static;
                    in
                    {
                      certPath = alloy.facts.${opts.certFact}.path;
                      keyPath = config.secrets.${opts.keySecret}.path;
                      fullPath = config.secretTemplates."tls/certs/${name}/static/full".path;
                    }
                  );
                }
              )
            );
          };
          config = lib.mkMerge (lib.mapAttrsToList mkHostLevel alloy.tls.certs);
        };

      staticSourceSubmodule = lib.types.submodule {
        options = {
          certFact = lib.mkOption {
            type = lib.types.str;
          };
          keySecret = lib.mkOption {
            type = lib.types.str;
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
                  static = lib.mkOption {
                    type = staticSourceSubmodule;
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
            options.certFact = lib.mkOption {
              default = null;
              type = lib.types.nullOr lib.types.str;
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
