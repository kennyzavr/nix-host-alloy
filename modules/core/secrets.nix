{ inputs, ... }: {
  flake.alloyModules.core =
    {
      alib,
      lib,
      config,
      ...
    }:
    let
      alloy = config;

      masterSubmodule = { name, config, ... }: {
        options = {
          file = lib.mkOption {
            type = lib.types.str;
          };
          path = lib.mkOption {
            readOnly = true;
            default = alloy.workspace.root + "/${config.file}";
            type = lib.types.path;
          };
          exists = lib.mkOption {
            readOnly = true;
            default = builtins.pathExists config.path;
            type = lib.types.bool;
          };
          assertions = lib.mkOption {
            type = lib.types.listOf alib.types.assertion;
            default = [ ];
          };
        };
        config = {
          file = lib.mkOptionDefault "${alloy.workspace.secrets.baseDir}/${name}.age";
          assertions = [
            {
              assertion = config.exists;
              message = ''
                [Alloy] Master secret '${name}' not found at ${alloy.workspace.root}/${config.file}.
                To fix this, ensure the file is created (e.g. via 'alloy generators run' or 'alloy secrets set "${name}"').
              '';
            }
          ];
        };
      };

      secretSubmodule =
        contextType: contextName:
        {
          name,
          config,
          options,
          ...
        }:
        {
          options = {
            master = lib.mkOption {
              type = lib.types.str;
              default = name;
            };
            file = lib.mkOption { type = lib.types.str; };
            path = lib.mkOption { type = lib.types.str; };
            permissions = lib.mkOption {
              type = alib.types.permissions;
              default = {
                owner = "root";
                group = "root";
                mode = "0440";
              };
            };
            placeholder = lib.mkOption {
              type = lib.types.str;
              default = "___ALLOY_SECRET_${builtins.hashString "sha256" name}___";
            };
            assertions = lib.mkOption {
              type = lib.types.listOf alib.types.assertion;
              default = [ ];
            };
          };
          config = {
            file = lib.mkOptionDefault (
              if contextType == "host" then
                "${alloy.hosts.${contextName}.workspace.secrets.baseDir}/${name}.age"
              else
                "${alloy.jails.${contextName}.workspace.secrets.baseDir}/${name}.age"
            );
            path = lib.mkOptionDefault (
              if contextType == "host" then
                "${alloy.hosts.${contextName}.workspace.secrets.basePath}/${name}"
              else
                "${alloy.jails.${contextName}.workspace.secrets.basePath}/${name}"
            );

            assertions = [
              {
                assertion = builtins.pathExists (alloy.workspace.root + "/${config.file}");
                message = "[Alloy] Secret '${name}' attached to ${contextType} '${contextName}' not found at ${alloy.workspace.root}/${config.file}. You may need to rekey the secret for this ${contextType}, or add the rekeyed secret to git.";
              }
              {
                assertion = builtins.hasAttr config.master alloy.secrets;
                message = ''
                  [Alloy] Invalid master secret reference

                  Secret '${name}' attached to ${contextType} '${contextName}' references a master secret '${config.master}', 
                  which does not exist in 'secrets'.

                  Location:
                  ${lib.concatStringsSep "\n" (map (f: "  - ${f}") options.master.files)}
                '';
              }
            ];
          };
        };

      secretTemplateSubmodule =
        contextType: contextName:
        {
          name,
          ...
        }:
        {
          options = {
            template = lib.mkOption {
              type = lib.types.str;
              description = "Template to render.";
            };
            path = lib.mkOption {
              type = lib.types.str;
              description = "Path where the rendered file will be placed.";
            };
            permissions = lib.mkOption {
              type = alib.types.permissions;
              default = {
                owner = "root";
                group = "root";
                mode = "0440";
              };
            };
          };
          config = {
            path = lib.mkOptionDefault (
              if contextType == "host" then
                "${alloy.hosts.${contextName}.workspace.secretTemplates.basePath}/${name}"
              else
                "${alloy.jails.${contextName}.workspace.secretTemplates.basePath}/${name}"
            );
          };
        };

      mkJail =
        host: jailName: jail:
        let
          secrets = lib.filter (s: s.jailName == jailName) jailSecretsList;
          templates = lib.filter (s: s.jailName == jailName) jailTemplatesList;
          mkSecret =
            secret:
            { config, ... }:
            let
              agenixPath = config.age.secrets."alloy/secrets/jails/${jailName}/${secret.secretName}".path;
            in
            {
              age.secrets."alloy/secrets/jails/${jailName}/${secret.secretName}" = {
                file = alloy.workspace.root + "/${secret.file}";
                owner = "root";
                group = "root";
                mode = secret.permissions.mode;
              };

              containers."alloy-jail-${jailName}" = {
                bindMounts."secret-${secret.secretName}" = {
                  hostPath = agenixPath;
                  mountPoint = agenixPath;
                  isReadOnly = true;
                };
                config = { pkgs, ... }: {
                  systemd.services."alloy-secrets-and-templates-setup" = {
                    script = ''
                      install -D \
                        -m "${secret.permissions.mode}" \
                        -o "${secret.permissions.owner}" \
                        -g "${secret.permissions.group}" \
                        "${agenixPath}" \
                        "${secret.path}"
                    '';
                  };
                };
              };
            };
          mkTemplate =
            template:
            { config, ... }:
            {
              containers."alloy-jail-${jailName}" = {
                config = { pkgs, ... }: {
                  systemd.services."alloy-secrets-and-templates-setup" = {
                    script = ''
                      mkdir -p "$(dirname "${template.path}")"
                      jq -rRs ${
                        lib.concatImapStringsSep " " (
                          idx: secret: ''--arg secret${toString idx} "$(cat ${secret.path})"''
                        ) secrets
                      } '${
                        if secrets == [ ] then
                          "."
                        else
                          lib.concatImapStringsSep " | " (
                            idx: secret: ''gsub("${secret.placeholder}"; $secret${toString idx})''
                          ) secrets
                      }' "${pkgs.writeText "alloy-jail-${jailName}-secret-template-${template.templateName}" template.template}" > "${template.path}.tmp"
                      install -D -m "${template.permissions.mode}" -o "${template.permissions.owner}" -g "${template.permissions.group}" "${template.path}.tmp" "${template.path}"
                      rm -f "${template.path}.tmp"
                    '';
                  };
                };
              };
            };
        in
        {
          nixosModule = {
            imports = [
              inputs.agenix.nixosModules.default
            ]
            ++ (lib.map mkSecret secrets)
            ++ (lib.map mkTemplate templates);

            age.identityPaths = lib.optionals (secrets != [ ]) (
              lib.map (kp: toString kp.identity) host.workspace.secrets.age.keyPairs
            );

            containers."alloy-jail-${jailName}" = {
              config = { pkgs, ... }: {
                systemd.services."alloy-secrets-and-templates-setup" = {
                  enable = secrets != [ ] || templates != [ ];
                  wantedBy = [ "sysinit.target" ];
                  serviceConfig = {
                    Type = "oneshot";
                    RemainAfterExit = true;
                  };
                  path = [
                    pkgs.jq
                    pkgs.coreutils
                  ];
                  script = "";
                };
              };
            };
          };
        };

      mkHost =
        hostName: host:
        let
          secrets = lib.filter (s: s.hostName == hostName) hostSecretsList;
          templates = lib.filter (s: s.hostName == hostName) hostTemplatesList;
          mkSecret = secret: {

            age.secrets."alloy/secrets/host/${secret.secretName}" = {
              file = alloy.workspace.root + "/${secret.file}";
              path = secret.path;
              inherit (secret.permissions) owner group mode;
            };
          };
          mkTemplate = template: { pkgs, ... }: {
            systemd.services."alloy-secret-templates-setup" = {
              script = ''
                mkdir -p "$(dirname "${template.path}")"
                jq -rRs ${
                  lib.concatImapStringsSep " " (
                    idx: secret: ''--arg secret${toString idx} "$(cat ${secret.path})"''
                  ) secrets
                } '${
                  if secrets == [ ] then
                    "."
                  else
                    lib.concatImapStringsSep " | " (
                      idx: secret: ''gsub("${secret.placeholder}"; $secret${toString idx})''
                    ) secrets
                }' "${pkgs.writeText "alloy-host-${hostName}-secret-template-${template.templateName}" template.template}" > "${template.path}.tmp"
                install -D -m "${template.permissions.mode}" -o "${template.permissions.owner}" -g "${template.permissions.group}" "${template.path}.tmp" "${template.path}"
                rm -f "${template.path}.tmp"
              '';
            };
          };
        in
        {
          nixosModule = { pkgs, ... }: {
            imports = [
              inputs.agenix.nixosModules.default
            ]
            ++ (lib.map mkSecret secrets)
            ++ (lib.map mkTemplate templates);

            age.identityPaths = lib.optionals (secrets != [ ]) (
              lib.map (kp: toString kp.identity) host.workspace.secrets.age.keyPairs
            );

            systemd.services."alloy-secret-templates-setup" = {
              enable = templates != [ ];
              wantedBy = [ "sysinit.target" ];
              after = [ "agenix-install-secrets.service" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              path = [
                pkgs.jq
                pkgs.coreutils
              ];
            };
          };
        };

      hostSubmodule = { name, config, ... }: {
        options = {
          secrets = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (lib.types.submodule (secretSubmodule "host" name));
          };
          secretTemplates = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (lib.types.submodule (secretTemplateSubmodule "host" name));
          };
          workspace.secrets = {
            baseDir = lib.mkOption {
              type = lib.types.str;
              default = "secrets/hosts/${name}";
            };
            basePath = lib.mkOption {
              type = lib.types.str;
              default = "/run/alloy/secrets";
            };
            age.keyPairs = lib.mkOption {
              default = [ ];
              type = lib.types.listOf alib.types.ageKeyPair;
            };
          };
          workspace.secretTemplates = {
            basePath = lib.mkOption {
              type = lib.types.str;
              default = "/run/alloy/secret-templates";
            };
          };
        };
        config =
          let
            configs = lib.flatten (
              [ (mkHost name config) ]
              ++ (lib.pipe alloy.jails [
                (lib.filterAttrs (_: jail: jail.host == name))
                (lib.mapAttrsToList (jailName: jail: mkJail config jailName jail))
              ])
            );
          in
          {
            nixosModule = lib.mkMerge (lib.catAttrs "nixosModule" configs);
          };
      };

      jailSubmodule = { name, ... }: {
        options = {
          secrets = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (lib.types.submodule (secretSubmodule "jail" name));
          };
          secretTemplates = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (lib.types.submodule (secretTemplateSubmodule "jail" name));
          };
          workspace.secrets = {
            baseDir = lib.mkOption {
              type = lib.types.str;
              default = "secrets/jails/${name}";
            };
            basePath = lib.mkOption {
              type = lib.types.str;
              default = "/run/alloy/secrets";
            };
          };
          workspace.secretTemplates = {
            basePath = lib.mkOption {
              type = lib.types.str;
              default = "/run/alloy/secret-templates";
            };
          };
        };
      };

      hostSecretsList = lib.flatten (
        lib.mapAttrsToList (
          hostName: host:
          lib.mapAttrsToList (secretName: secret: secret // { inherit hostName secretName; }) host.secrets
        ) alloy.hosts
      );

      jailSecretsList = lib.flatten (
        lib.mapAttrsToList (
          jailName: jail:
          lib.mapAttrsToList (
            secretName: secret:
            secret
            // {
              inherit jailName secretName;
              hostName = jail.host;
            }
          ) jail.secrets
        ) alloy.jails
      );

      hostTemplatesList = lib.flatten (
        lib.mapAttrsToList (
          hostName: host:
          lib.mapAttrsToList (
            templateName: template: template // { inherit hostName templateName; }
          ) host.secretTemplates
        ) alloy.hosts
      );

      jailTemplatesList = lib.flatten (
        lib.mapAttrsToList (
          jailName: jail:
          lib.mapAttrsToList (
            templateName: template:
            template
            // {
              inherit jailName templateName;
              hostName = jail.host;
            }
          ) jail.secretTemplates
        ) alloy.jails
      );
    in
    {
      options = {
        secrets = lib.mkOption {
          default = { };
          type = lib.types.attrsOf (lib.types.submodule masterSubmodule);
        };

        workspace.secrets = {
          baseDir = lib.mkOption {
            type = lib.types.str;
            default = "secrets/masters";
          };
          age.keyPairs = lib.mkOption {
            default = [ ];
            type = lib.types.listOf alib.types.ageKeyPair;
          };
        };

        hosts = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
        };

        jails = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule jailSubmodule);
        };
      };

      config = {
        assertions =
          (lib.flatten (lib.mapAttrsToList (n: s: s.assertions) alloy.secrets))
          ++ (lib.flatten (lib.map (s: s.assertions) hostSecretsList))
          ++ (lib.flatten (lib.map (s: s.assertions) jailSecretsList));

        _internal.state = { ... }: {
          masterSecrets = lib.mapAttrsToList (secretName: secret: {
            inherit (secret) file;
            name = secretName;
          }) alloy.secrets;

          masterSecretRecipients = lib.map (kp: toString kp.recipient) alloy.workspace.secrets.age.keyPairs;

          masterSecretIdentities = lib.map (kp: toString kp.identity) alloy.workspace.secrets.age.keyPairs;

          hostSecrets = lib.map (secret: {
            host = secret.hostName;
            name = secret.secretName;
            file = secret.file;
            master = secret.master;
          }) hostSecretsList;

          hostSecretRecipients = lib.pipe alloy.hosts [
            (lib.mapAttrsToList (
              hostName: host:
              lib.map (ageKey: {
                host = hostName;
                value = toString ageKey.recipient;
              }) host.workspace.secrets.age.keyPairs
            ))
            lib.flatten
          ];

          jailSecrets = lib.map (secret: {
            jail = secret.jailName;
            name = secret.secretName;
            file = secret.file;
            master = secret.master;
          }) jailSecretsList;

          jailSecretRecipients = lib.pipe alloy.jails [
            (lib.mapAttrsToList (
              jailName: jail:
              let
                host = alloy.hosts.${jail.host};
              in
              lib.map (ageKey: {
                jail = jailName;
                value = toString ageKey.recipient;
              }) host.workspace.secrets.age.keyPairs
            ))
            lib.flatten
          ];
        };
      };
    };
}
