{ inputs, ... }: {
  perSystem =
    {
      inputs',
      self',
      pkgs,
      lib,
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
        src = craneLib.cleanCargoSource ./.;
        strictDeps = true;
        CARGO_BUILD_TARGET = target;
      };
      cargoArtifacts = craneLib.buildDepsOnly (
        {
          pname = "alloy-cli-deps";
        }
        // commonArgs
      );
      package = craneLib.buildPackage (
        {
          pname = "alloy-cli";
          inherit version;
          inherit cargoArtifacts;
        }
        // commonArgs
      );
    in
    {
      devShells.cliDevShell = pkgs.mkShell {
        packages = [
          rustToolchain
        ];
        CARGO_BUILD_TARGET = target;
        RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";
      };

      packages.cli = package;
    };
}
