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
          ({ lib, ... }: {
            flake.lib = import ./lib {
              inherit lib;
              inherit inputs;
            };
          })
        ];

        flake.flakeModules = {
          default = ./parts.nix;
        };

        perSystem =
          {
            pkgs,
            ...
          }:
          {
            devShells.default = pkgs.mkShell {
              packages = [
                pkgs.nil
              ];
            };
            formatter = pkgs.nixfmt-tree;
          };

        systems = [
          "x86_64-linux"
        ];
      };
}
