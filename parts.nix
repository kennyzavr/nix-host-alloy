{
  inputs,
  lib,
  ...
}:
{
  options.flake = lib.mkOption {
    type = lib.types.submoduleWith {
      modules = [
        (submod: {
          _file = ./parts.nix;
          key = ./parts.nix;
          options.alloyModules = lib.mkOption {
            type = lib.types.lazyAttrsOf lib.types.deferredModule;
            default = { };
            apply = builtins.mapAttrs (
              name: mod: {
                _file = "${inputs.self.outPath}#alloyModules.${name}";
                key = "${inputs.self.outPath}#alloyModules.${name}";
                imports = [ mod ];
              }
            );
          };
          # options.alloys = lib.mkOption {
          #   type = lib.types.lazyAttrsOf lib.types.deferredModule;
          #   readOnly = true;
          # };
          # config.alloys =
          #   builtins.mapAttrs
          #     (
          #       name: mod:
          #       mod
          #       // {
          #         key = "AlloyModules-${name}";
          #       }
          #     )
          #     (
          #       (lib.types.lazyAttrsOf lib.types.deferredModule).merge submod.options.alloy.loc submod.options.alloy.definitionsWithLocations
          #     );

          # config.nixosConfigurations = lib.pipe submod.config.alloyModules [
          #   (lib.mapAttrs (_: v: builtins.attrValues (alib.evalModule v).config.hosts))
          #   (lib.mapAttrsToList (
          #     alloyName: hosts:
          #     lib.optionals (!(lib.elem alloyName config.alloy.exclude)) (
          #       lib.map (host: {
          #         name = "${if alloyName == "default" then "alloy-" else "alloy-${alloyName}-"}${host.id}";
          #         value = host.nixosConfiguration;
          #       }) hosts
          #     )
          #   ))
          #   lib.flatten
          #   builtins.listToAttrs
          # ];
        })
      ];
    };
  };

  # config.perSystem = { pkgs, ... }: {
  #   apps = lib.mapAttrs' (
  #     alloyName: alloyDef:
  #     let
  #       alib = import ./lib { inherit lib; };
  #       evaled = alib.evalModule alloyDef;
  #       cliPkg = evaled.config.alloy.cli.mkCli {
  #         flake = self;
  #         inherit pkgs;
  #       };
  #       appName = if alloyName == "default" then "alloy" else "alloy-${alloyName}";
  #     in
  #     lib.nameValuePair appName {
  #       type = "app";
  #       program = "${cliPkg}/bin/alloy";
  #     }
  #   ) (config.flake.alloyModules or { });
  # };
}
