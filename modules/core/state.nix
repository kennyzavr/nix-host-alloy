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
          default = { ... }: { };
          type = lib.types.functionTo (lib.types.attrsOf lib.types.anything);
          internal = true;
        };
        stateScript = lib.mkOption {
          default = { ... }: "";
          type = lib.types.functionTo (lib.types.lines);
          internal = true;
        };
        statePackage = lib.mkOption {
          type = lib.types.functionTo lib.types.package;
          internal = true;
          readOnly = true;
        };
      };

      config._internal.statePackage =
        { pkgs, ... }@args:
        pkgs.runCommand "alloy-state" { } ''
          mkdir -p $out/bin

          cat > $out/state.json <<'EOF'
          ${builtins.toJSON (alloy._internal.state args)}
          EOF

          ${alloy._internal.stateScript args}
        '';
    };
}
