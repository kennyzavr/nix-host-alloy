{
  lib,
  config,
  ...
}:
let
  alloy = config;

  indexes = alloy.facts."host-index-table".value;

  hostSubmodule = { name, config, ... }: {
    options = {
      idx = lib.mkOption {
        type = lib.types.ints.unsigned;
        readOnly = true;
      };
      system = lib.mkOption {
        type = lib.types.str;
      };
      nixosModule = lib.mkOption {
        type = lib.types.deferredModule;
        default = { };
        apply = module: {
          _class = "nixos";
          _file = "hosts.${lib.strings.escapeNixIdentifier name}.nixosModule";
          imports = [ module ];
        };
      };
      nixosConfiguration = lib.mkOption {
        readOnly = true;
        type = lib.types.unspecified;
      };
      assertions = lib.mkOption {
        type = lib.types.listOf lib.types.unspecified;
        default = [ ];
      };
    };
    config = {
      idx = indexes.${name};
      nixosConfiguration = lib.nixosSystem {
        inherit (config) system;
        modules = [
          config.nixosModule
          {
            networking.useNetworkd = true;
            systemd.network.enable = true;
            networking.nftables.enable = true;
          }
        ];
      };
    };
  };
in
{
  options.hosts = lib.mkOption {
    default = { };
    type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
  };

  config = {
    generators.instances."host-index-table" = {
      imports = [
        alloy.generators.templates."index-table"
      ];

      name = "host-index-table";
      keys = builtins.attrNames alloy.hosts;
      minValue = 1;
      maxValue = 99;
    };

    assertions = lib.flatten (lib.mapAttrsToList (_: host: host.assertions) alloy.hosts);
  };
}
