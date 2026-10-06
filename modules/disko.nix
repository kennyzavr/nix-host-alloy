{ inputs, ... }: {
  flake.alloyModules.disko =
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
          options.disko = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
            settings = lib.mkOption {
              default = { ... }: { };
              type = (lib.types.functionTo lib.types.unspecified);
            };
          };

          config = lib.mkIf config.disko.enable {
            nixosModule = { pkgs, ... }: {
              imports = [
                inputs.disko.nixosModules.default
              ];
              disko = lib.mkMerge [
                (host.disko.settings { inherit pkgs; })
                {
                  # imageBuilder.kernelPackages = pkgs.linuxPackages;
                }
              ];
            };

            qemu.variants."disko-boot".package =
              { pkgs, ... }:
              (lib.nixosSystem {
                inherit (config) system;
                modules = [
                  config.nixosModule
                  ({ config, pkgs, ... }: {
                    virtualisation.vmVariantWithDisko = {
                      imports = [ host.qemu.nixosModule ];
                    };
                  })
                ];
              }).config.system.build.vmWithDisko;
          };
        };
    in
    {
      options.hosts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
      };
    };
}
