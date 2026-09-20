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
          wantedBy = lib.mkOption {
            default = [ ];
            type = lib.types.listOf lib.types.str;
          };
          before = lib.mkOption {
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

      config = {
        assertions = lib.flatten (lib.mapAttrsToList (name: g: g.assertions) alloy.generators.instances);

        facts = lib.pipe alloy.generators.instances [
          (lib.filterAttrs (_: g: g.enable))
          (lib.mapAttrsToList (
            _: g:
            lib.mapAttrs (_: f: {
              inherit (g) tags;
            }) g.facts
          ))
          lib.mkMerge
        ];
        secrets = lib.pipe alloy.generators.instances [
          (lib.filterAttrs (_: g: g.enable))
          (lib.mapAttrsToList (
            _: g:
            lib.mapAttrs (_: f: {
              inherit (g) tags;
            }) g.secrets
          ))
          lib.mkMerge
        ];

        _internal.state = { pkgs, ... }: {
          generators = lib.mapAttrs (_: generator: {
            inherit (generator)
              wants
              wantedBy
              after
              before
              tags
              ;
            secrets = builtins.attrNames generator.secrets;
            facts = builtins.attrNames generator.facts;
            bin =
              let
                b = builtins.tryEval (toString (lib.getExe (generator.package { inherit pkgs; })));
              in
              if b.success then b.value else null;
          }) (lib.filterAttrs (_: g: g.enable) alloy.generators.instances);
        };
      };
    };
}
