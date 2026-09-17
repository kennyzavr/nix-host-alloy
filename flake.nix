{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake
      {
        inherit inputs;
      }
      {
        imports = [
          ./parts.nix
          ./lib
          ./modules
        ];

        flake.flakeModules = {
          default = ./parts.nix;
        };

        perSystem =
          {
            pkgs,
            config,
            ...
          }:
          {
            packages.alloy-cli = pkgs.python3Packages.buildPythonApplication {
              pname = "alloy-cli";
              version = "0.1.0";
              src = ./packages/alloy-cli;
              pyproject = true;
              build-system = [ pkgs.python3Packages.setuptools ];
              dependencies = [ pkgs.python3Packages.rich ];

              makeWrapperArgs = [
                "--prefix"
                "PATH"
                ":"
                (pkgs.lib.makeBinPath [
                  pkgs.rage
                  pkgs.git
                  pkgs.nano
                  pkgs.vde2
                ])
              ];
            };

            devShells.default = pkgs.mkShell {
              packages = [
                pkgs.nil
                pkgs.pyright
                pkgs.ruff
              ];
            };
            formatter = pkgs.nixfmt-tree;
          };

        systems = [
          "x86_64-linux"
        ];
      };
}
