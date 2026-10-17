{ alloySelf, ... }:
{
  lib,
  config,
  self,
  ...
}:
{
  options.flake = lib.mkOption {
    type = lib.types.submoduleWith {
      modules = [
        {
          _file = ./parts.nix;
          key = ./parts.nix;
          options.alloyModules = lib.mkOption {
            type = lib.types.lazyAttrsOf lib.types.deferredModule;
            default = { };
            apply = builtins.mapAttrs (
              name: mod: {
                _file = "${self.outPath}#alloyModules.${name}";
                key = "${self.outPath}#alloyModules.${name}";
                imports = [ mod ];
              }
            );
          };

          options.alloyCli.instances = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (
              lib.types.submodule (
                { name, config, ... }: {
                  options = {
                    module = lib.mkOption {
                      type = lib.types.str;
                      default = name;
                    };
                    alloyInputAttr = lib.mkOption {
                      default = "inputs.alloy";
                      type = lib.types.str;
                    };
                    runtimeInputs = lib.mkOption {
                      default = { ... }: [ ];
                      type = lib.types.functionTo (lib.types.listOf lib.types.unspecified);
                    };
                    packageName = lib.mkOption {
                      type = lib.types.str;
                      default = if name == "default" then "alloy-cli" else "${name}-alloy-cli";
                    };
                  };
                }
              )
            );
          };
        }
      ];
    };
  };

  config.perSystem = { system, pkgs, ... }: {
    packages = lib.mapAttrs' (
      _: value:
      lib.nameValuePair value.packageName (
        alloySelf.lib.mkCli {
          flakeUrl = "${self}";
          moduleAttr = "alloyModules.${value.module}";
          alloyInputAttr = value.alloyInputAttr;
          runtimeInputs = value.runtimeInputs { inherit pkgs; };
          inherit system;
        }
      )
    ) config.flake.alloyCli.instances;
  };
}
