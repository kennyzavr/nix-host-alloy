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
          host = config;
        in
        {
          options.boot = {
            files = lib.mkOption {
              default = { };
              description = "Existing host files copied into initrd when installing the boot configuration. Sources must exist before installation or rebuild; this option does not generate them.";
              type = lib.types.attrsOf (
                lib.types.submodule (
                  { name, ... }: {
                    options = {
                      source = lib.mkOption {
                        type = lib.types.strMatching "/[a-zA-Z0-9_./-]+";
                        description = "Absolute source path on the target host, not a build-time Nix path.";
                      };
                      path = lib.mkOption {
                        type = lib.types.str;
                        readOnly = true;
                        default = "/etc/alloy/boot/files/${name}";
                        description = "Destination path inside initrd.";
                      };
                    };
                  }
                )
              );
            };
            facts = lib.mkOption {
              default = { };
              type = lib.types.attrsOf (
                lib.types.submodule (
                  { name, ... }: {
                    options.path = lib.mkOption {
                      default = config.boot.factsBasePath + "/${name}";
                      type = lib.types.str;
                      description = "Destination path for this fact inside the initrd.";
                    };
                  }
                )
              );
            };
            factsBasePath = lib.mkOption {
              type = lib.types.str;
              default = "/etc/alloy/facts";
              description = "Base destination path for facts copied into the initrd.";
            };
          };

          config.assertions = [
            {
              assertion =
                let
                  paths =
                    map (file: file.path) (builtins.attrValues config.boot.files)
                    ++ map (fact: fact.path) (builtins.attrValues config.boot.facts);
                in
                builtins.length paths == builtins.length (lib.unique paths);
              message = "[Alloy] Host '${name}': Boot files and facts must have unique destination paths. Assign each a distinct path.";
            }
          ]
          ++ lib.concatLists (
            lib.mapAttrsToList (fileName: file: [
              {
                assertion = builtins.match "[a-zA-Z0-9_-]+" fileName != null;
                message = "[Alloy] Host '${name}', boot file '${fileName}': The name may contain only letters, numbers, underscores, and hyphens.";
              }
              {
                assertion =
                  !(lib.hasPrefix "/nix/store/" file.source)
                  && lib.all (part: part != "" && part != "." && part != "..") (
                    lib.tail (lib.splitString "/" file.source)
                  );
                message = "[Alloy] Host '${name}', boot file '${fileName}': `source` must be a normalized path outside `/nix/store`.";
              }
            ]) config.boot.files
          );

          config.nixosModule = { config, ... }: {
            assertions = [
              {
                assertion = host.boot.files == { } || config.boot.loader.supportsInitrdSecrets;
                message = "[Alloy] Host '${name}': `boot.files` requires a bootloader that supports initrd secrets. Select a compatible bootloader or remove these files.";
              }
            ];

            boot.initrd.enable = true;
            boot.initrd.systemd.enable = true;

            boot.initrd.secrets = lib.mkMerge [
              (lib.mapAttrs' (
                factName: fact: lib.nameValuePair fact.path alloy.facts.${factName}.path
              ) host.boot.facts)
              (lib.mapAttrs' (_: file: lib.nameValuePair file.path file.source) host.boot.files)
            ];
          };
        };
    in
    {
      options.hosts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
      };
    };
}
