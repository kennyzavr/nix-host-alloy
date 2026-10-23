{
  flake.alloyModules.core =
    {
      lib,
      config,
      alib,
      ...
    }:
    let
      alloy = config;

      hostSubmodule = { name, config, ... }: {
        options = {
          idx = lib.mkOption {
            type = lib.types.ints.unsigned;
            readOnly = true;
          };
          system = lib.mkOption {
            type = lib.types.str;
            description = "Nix platform identifier used to evaluate and build this host.";
          };
          stateVersion = lib.mkOption {
            type = lib.types.str;
            description = "NixOS state version passed to this host's NixOS configuration.";
          };
          nixosModule = lib.mkOption {
            type = lib.types.deferredModule;
            default = { };
            description = "NixOS module merged into this host's generated NixOS configuration.";
            apply =
              module:
              let
                moduleLocation = "hosts.${lib.strings.escapeNixIdentifier name}.nixosModule";
              in
              {
                _class = "nixos";
                _file = moduleLocation;
                key = moduleLocation;
                imports = [
                  module
                  {
                    system.stateVersion = lib.mkDefault config.stateVersion;
                  }
                ];
              };
          };
          nixosConfiguration = lib.mkOption {
            readOnly = true;
            type = lib.types.unspecified;
          };
          nixosConfig = lib.mkOption {
            type = lib.types.unspecified;
            readOnly = true;
            default = config.nixosConfiguration.config;
          };
          warnings = lib.mkOption {
            type = lib.types.listOf alib.types.warning;
            default = [ ];
          };
          assertions = lib.mkOption {
            type = lib.types.listOf alib.types.assertion;
            default = [ ];
          };
          tags = lib.mkOption {
            default = [ ];
            type = lib.types.listOf lib.types.str;
            description = "Labels used to select or group this host in CLI operations.";
          };
        };
        config = {
          idx = alloy.indexes."hosts".get name;
          assertions = [
            {
              assertion = alib.types.dns.label.check name;
              message = "[Alloy] Host '${name}': The name must be a valid DNS label.";
            }
          ];
          nixosModule = {
            system.stateVersion = "26.05";
          };
          nixosConfiguration = lib.nixosSystem {
            inherit (config) system;
            modules = [
              config.nixosModule
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
        warnings = lib.flatten (lib.mapAttrsToList (_: host: host.warnings) alloy.hosts);
        assertions = lib.flatten (lib.mapAttrsToList (_: host: host.assertions) alloy.hosts);

        indexes."hosts" = {
          keys = builtins.attrNames alloy.hosts;
          minValue = 1;
          maxValue = 99;
        };

        build.state = { ... }: {
          hosts = lib.mapAttrs (_: host: {
            inherit (host) tags system;
          }) alloy.hosts;
        };
      };
    };
}
