{ inputs, ... }: {
  flake.alloyModules.home-manager =
    {
      config,
      lib,
      alib,
      ...
    }:
    let
      userSubmodule =
        hostName: host:
        { config, name, ... }:
        let
          user = config;
        in
        {
          options.home = {
            enable = lib.mkOption {
              default = true;
              type = lib.types.bool;
            };
            stateVersion = lib.mkOption {
              default = host.stateVersion;
              type = lib.types.str;
            };
            module = lib.mkOption {
              type = lib.types.deferredModule;
              default = { };
              apply = module: {
                _class = "homeManager";
                _file = "hosts.${lib.strings.escapeNixIdentifier hostName}.users.${lib.strings.escapeNixIdentifier name}.home.module";
                imports = [
                  module
                  {
                    home.stateVersion = lib.mkDefault user.home.stateVersion;
                    home.username = lib.mkDefault user.name;
                    home.homeDirectory = lib.mkDefault user.dir;
                  }
                ];
              };
            };
          };
        };

      hostSubmodule =
        { config, name, ... }:
        let
          host = config;
        in
        {
          options = {
            users = lib.mkOption {
              type = lib.types.attrsOf (lib.types.submodule (userSubmodule name host));
            };
            home = {
              enable = lib.mkOption {
                default = false;
                type = lib.types.bool;
              };
              sharedModule = lib.mkOption {
                type = lib.types.deferredModule;
                default = { };
                apply = module: {
                  _class = "homeManager";
                  _file = "hosts.${lib.strings.escapeNixIdentifier name}.home.sharedModule";
                  imports = [
                    module
                  ];
                };
              };
            };
          };
          config.nixosModule = lib.mkIf host.home.enable {
            imports = [ inputs.home-manager.nixosModules.home-manager ];

            home-manager = {
              useGlobalPkgs = lib.mkDefault true;
              useUserPackages = lib.mkDefault true;

              sharedModules = [ host.home.sharedModule ];

              users = lib.pipe host.users [
                (lib.filterAttrs (_: user: user.home.enable))
                (lib.mapAttrs (_: user: user.home.module))
              ];
            };
          };
        };
    in
    {
      options.hosts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
      };
    };
}
