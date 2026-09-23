{
  flake.alloyModules.core =
    {
      lib,
      config,
      ...
    }:
    let
      alloy = config;
    in
    {
      options._internal = {
        state = lib.mkOption {
          default = { };
          type = lib.types.functionTo (lib.types.attrsOf lib.types.anything);
          internal = true;
        };
        statePackage = lib.mkOption {
          type = lib.types.functionTo lib.types.package;
          internal = true;
        };
      };

      config._internal.statePackage =
        { pkgs, ... }:
        let
          activeGenerators = lib.filterAttrs (_: g: g.enable) alloy.generators.instances;
        in
        pkgs.runCommand "alloy-state" { } ''
          mkdir -p $out/bin

          cat > $out/state.json <<'EOF'
          ${builtins.toJSON (alloy._internal.state { inherit pkgs; })}
          EOF

          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (
              name: gen:
              let
                drv = gen.package { inherit pkgs; };
                evalResult = builtins.tryEval (builtins.seq drv.outPath drv);
              in
              if evalResult.success then
                ''
                  mkdir -p $(dirname "$out/bin/${name}")
                  ln -s ${pkgs.lib.getExe evalResult.value} "$out/bin/${name}"
                ''
              else
                ""
            ) activeGenerators
          )}
        '';
    };
}
