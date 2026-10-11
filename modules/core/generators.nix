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

      generatorCore = { config, name, ... }: {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
          description = lib.mkOption {
            default = "";
            type = lib.types.str;
          };
          wants = lib.mkOption {
            default = [ ];
            type = lib.types.listOf lib.types.str;
          };
          after = lib.mkOption {
            default = [ ];
            type = lib.types.listOf lib.types.str;
          };
          tags = lib.mkOption {
            default = [ ];
            type = lib.types.listOf lib.types.str;
          };
          facts = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (lib.types.submodule { });
          };
          secrets = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (lib.types.submodule { });
          };
          package = lib.mkOption {
            type = lib.types.functionTo lib.types.package;
          };
          assertions = lib.mkOption {
            default = [ ];
            type = lib.types.listOf alib.types.assertion;
          };
        };
      };
    in
    {
      options.generators = {
        templates = lib.mkOption {
          default = { };
          type = lib.types.lazyAttrsOf lib.types.deferredModule;
        };

        instances = lib.mkOption {
          default = { };
          type = lib.types.attrsOf (
            lib.types.submoduleWith {
              modules = [
                generatorCore
              ];
            }
          );
        };
      };

      config.assertions = lib.flatten (
        lib.mapAttrsToList (name: g: g.assertions) alloy.generators.instances
      );

      config.facts = lib.pipe alloy.generators.instances [
        (lib.filterAttrs (_: g: g.enable))
        (lib.mapAttrsToList (
          _: g:
          lib.mapAttrs (_: f: {
            inherit (g) tags;
          }) g.facts
        ))
        lib.mkMerge
      ];

      config.secrets = lib.pipe alloy.generators.instances [
        (lib.filterAttrs (_: g: g.enable))
        (lib.mapAttrsToList (
          _: g:
          lib.mapAttrs (_: f: {
            inherit (g) tags;
          }) g.secrets
        ))
        lib.mkMerge
      ];

      options.build.spec = lib.mkOption {
        type = lib.types.submodule {
          options.generators = {
            buildScripts = lib.mkOption {
              default = false;
              type = lib.types.bool;
            };
          };
        };
      };

      config.build.state = { pkgs, ... }: {
        generators = lib.mapAttrs (generatorName: generator: {
          inherit (generator)
            wants
            after
            tags
            ;
          secrets = builtins.attrNames generator.secrets;
          facts = builtins.attrNames generator.facts;
          scriptPath =
            let
              scriptPath =
                let
                  drv = generator.package { inherit pkgs; };
                in
                (builtins.tryEval (builtins.seq drv.outPath "bin/generators/${generatorName}"));
            in
            if alloy.build.spec.generators.buildScripts && scriptPath.success then scriptPath.value else null;
        }) (lib.filterAttrs (_: g: g.enable) alloy.generators.instances);
      };

      config.build.script =
        { pkgs, ... }:
        lib.concatMapAttrsStringSep "\n" (
          genName: gen:
          let
            drv = gen.package { inherit pkgs; };
            scriptPath = (builtins.tryEval (builtins.seq drv.outPath "bin/generators/${genName}"));
          in
          lib.optionalString (alloy.build.spec.generators.buildScripts && scriptPath.success) ''
            mkdir -p "$(dirname "$out/${scriptPath.value}")"
            ln -s ${pkgs.lib.getExe drv} "$out/${scriptPath.value}"
          ''
        ) (lib.filterAttrs (_: g: g.enable) alloy.generators.instances);
    };
}
