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
      options.build = {
        spec = lib.mkOption {
          type = lib.types.submodule { };
        };
        state = lib.mkOption {
          default = { ... }: { };
          type = lib.types.functionTo (lib.types.attrsOf lib.types.anything);
        };
        script = lib.mkOption {
          default = { ... }: "";
          type = lib.types.functionTo lib.types.lines;
        };
        package = lib.mkOption {
          type = lib.types.functionTo lib.types.package;
          readOnly = true;
        };
      };
      config.build.package =
        { pkgs, ... }@args:
        pkgs.runCommand "alloy-${alloy.name}-state" { } ''
          mkdir -p $out/bin

          cat > $out/state.json <<'EOF'
          ${builtins.toJSON (alloy.build.state args)}
          EOF

          ${alloy.build.script args}
        '';
    };
}
