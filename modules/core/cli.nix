{ self, ... }: {
  flake.alloyModules.core =
    {
      alib,
      lib,
      config,
      ...
    }:
    {
      options.cli.package = lib.mkOption {
        readOnly = true;
        type = lib.types.functionTo lib.types.package;
        default =
          { pkgs, ... }:
          pkgs.symlinkJoin {
            name = "alloy-cli";
            paths = [ self.packages.${pkgs.stdenv.hostPlatform.system}.alloy-cli ];
            buildInputs = [ pkgs.makeWrapper ];
            postBuild = ''
              wrapProgram "$out/bin/alloy-cli" \
                --set ALLOY_STATE_FILE "${
                  pkgs.writeText "alloy-state" (builtins.toJSON (config._internal.state { inherit pkgs; }))
                }"
            '';
          };
      };
    };
}
