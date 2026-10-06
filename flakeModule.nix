{
  inputs,
  lib,
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
                _file = "${inputs.self.outPath}#alloyModules.${name}";
                key = "${inputs.self.outPath}#alloyModules.${name}";
                imports = [ mod ];
              }
            );
          };
        }
      ];
    };
  };
}
