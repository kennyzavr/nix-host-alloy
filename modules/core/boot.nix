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
        options.boot = {
          grub = {
            enable = lib.mkOption {
              default = true;
              type = lib.types.bool;
            };
          };
          facts = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (
              lib.types.submodule (
                { name, ... }: {
                  options.path = lib.mkOption {
                    default = config.boot.factsBasePath + "/${name}";
                    type = lib.types.str;
                  };
                }
              )
            );
          };
          factsBasePath = lib.mkOption {
            type = lib.types.str;
            default = "/etc/alloy/facts";
          };
        };

        config.nixosModule = { pkgs, ... }: {
          boot.loader.grub.enable = lib.mkIf config.boot.grub.enable true;

          boot.initrd.enable = true;
          boot.initrd.systemd.enable = true;

          # boot.initrd.systemd.emergencyAccess = true;
          # boot.kernelParams = [ "rd.systemd.break=pre-mount" ];

          boot.initrd.secrets = lib.mapAttrs' (
            factName: fact: lib.nameValuePair fact.path alloy.facts.${factName}.path
          ) config.boot.facts;
        };
      };
    in
    {
      options.hosts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
      };
    };
}
