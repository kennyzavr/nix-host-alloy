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

      generatorSubmodule = { config, name, ... }: {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
          description = lib.mkOption {
            default = "";
            type = lib.types.str;
          };
          fingerprintFact = lib.mkOption {
            default = "generators/${name}/fingerprint";
            type = lib.types.str;
            readOnly = true;
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
                generatorSubmodule
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
          {
            ${g.fingerprintFact} = { };
          }
          // (lib.mapAttrs (_: f: {
            inherit (g) tags;
          }) g.facts)
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
            calcFingerprint = lib.mkOption {
              default = false;
              type = lib.types.bool;
            };
          };
        };
      };

      config.build.state = { system, ... }: {
        generators = lib.mapAttrs (
          generatorName: generator:
          let
            packagePath =
              let
                drv = generator.package { inherit system; };
              in
              (builtins.tryEval (builtins.seq drv.outPath drv.outPath));
          in
          {
            inherit (generator)
              wants
              after
              tags
              fingerprintFact
              ;
            secrets = builtins.attrNames generator.secrets;
            facts = builtins.attrNames generator.facts;
            fingerprint =
              if alloy.build.spec.generators.calcFingerprint && packagePath.success then
                packagePath.value
              else
                null;
            scriptPath =
              if alloy.build.spec.generators.buildScripts && packagePath.success then
                "bin/generators/${generatorName}"
              else
                null;
          }
        ) (lib.filterAttrs (_: g: g.enable) alloy.generators.instances);
      };

      config.build.script =
        { system, ... }:
        lib.concatMapAttrsStringSep "\n" (
          genName: gen:
          let
            drv = gen.package { inherit system; };
            scriptPath = (builtins.tryEval (builtins.seq drv.outPath "bin/generators/${genName}"));
          in
          lib.optionalString (alloy.build.spec.generators.buildScripts && scriptPath.success) ''
            mkdir -p "$(dirname "$out/${scriptPath.value}")"
            ln -s ${lib.getExe drv} "$out/${scriptPath.value}"
          ''
        ) (lib.filterAttrs (_: g: g.enable) alloy.generators.instances);
    };
}
