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
      url = "github:nix-community/disko?ref=refs/pull/1277/head";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane = {
      url = "github:ipetkov/crane";
    };
    devshell = {
      url = "github:numtide/devshell";
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
          inputs.devshell.flakeModule
          ./parts.nix
          ./lib
          ./modules
          ./packages/rust.nix
        ];

        flake.flakeModules = {
          default = ./parts.nix;
        };

        perSystem =
          {
            pkgs,
            config,
            self',
            inputs',
            system,
            ...
          }:
          {

            devshells.default = {
              packages = [
                pkgs.nil
                # pkgs.pyright
                # pkgs.ruff
              ];
              commands = [
                {
                  name = "clear-store-paths";
                  help = "Clears stale nixos-disk-image store paths";
                  command = ''
                    shopt -s nullglob
                    disk_paths=(/nix/store/*nixos-disk-image*)
                    if [ ''${#disk_paths[@]} -gt 0 ]; then
                      nix-store --query --referrers-closure "''${disk_paths[@]}" | xargs nix-store --delete
                    else
                      echo "No disk images found."
                    fi
                  '';
                }
              ];
            };
            formatter = pkgs.nixfmt-tree;
          };

        systems = [
          "x86_64-linux"
        ];
      };
}
