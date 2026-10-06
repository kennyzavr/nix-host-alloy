{ inputs, ... }: {

  perSystem =
    {
      pkgs,
      ...
    }:
    let
      version = "0.1.0";

      rustPkgs = pkgs.extend inputs.rust-overlay.overlays.default;
      target = pkgs.stdenv.hostPlatform.rust.rustcTarget;
      rustToolchain = rustPkgs.rust-bin.stable."1.98.1".default.override {
        extensions = [
          "rust-src"
          "rust-analyzer"
        ];
        targets = [ target ];
      };

      craneLib = (inputs.crane.mkLib rustPkgs).overrideToolchain rustToolchain;

      commonArgs = {
        src = craneLib.cleanCargoSource ../.;
        strictDeps = true;
        CARGO_BUILD_TARGET = target;
      };

      cargoArtifacts = craneLib.buildDepsOnly (
        {
          pname = "alloy-workspace-deps";
        }
        // commonArgs
      );

      alloy-cli-package = craneLib.buildPackage (
        {
          pname = "alloy-cli";
          inherit version cargoArtifacts;
          cargoExtraArgs = "-p alloy-cli";
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postInstall = ''
            wrapProgram $out/bin/alloy-cli \
              --prefix PATH : ${
                pkgs.lib.makeBinPath [
                  pkgs.git
                  pkgs.rage
                  pkgs.vde2
                ]
              }
          '';
        }
        // commonArgs
      );
    in
    {
      devshells.default = {
        packages = [
          pkgs.rage
          pkgs.git
          pkgs.vde2
          rustToolchain
          pkgs.cargo-edit
          pkgs.stdenv.cc
        ];
        env = [
          {
            name = "CARGO_BUILD_TARGET";
            value = target;
          }
          {
            name = "RUST_SRC_PATH";
            value = "${rustToolchain}/lib/rustlib/src/rust/library";
          }
        ];
      };

      packages.alloy-cli = alloy-cli-package;
    };
}
