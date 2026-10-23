{
  imports = [
    ./hosts.nix
    ./deploy.nix
    ./jails.nix
    ./secrets.nix
    ./facts.nix
    ./generators.nix
    ./indexes.nix
    ./overlays.nix
    ./tls
    ./dns.nix
    ./mtls.nix
    ./endpoints.nix
    ./build.nix
    ./volumes.nix
    ./users.nix
    ./nets.nix
    ./qemu.nix
    ./ssh.nix
    ./boot.nix
  ];

  flake.alloyModules.core =
    {
      alib,
      lib,
      config,
      ...
    }:
    {
      options.name = lib.mkOption {
        type = lib.types.str;
        description = "Name of this Alloy configuration, used in generated state and diagnostics.";
      };

      options.workspace = {
        root = lib.mkOption {
          type = lib.types.path;
          description = "Absolute path to the workspace used to resolve fact and secret files.";
        };
        baseDir = lib.mkOption {
          default = ".";
          type = lib.types.str;
          description = "Workspace-relative base directory for Alloy-managed facts and secrets.";
        };
      };

      options.assertions = lib.mkOption {
        type = lib.types.listOf alib.types.assertion;
        default = [ ];
      };

      options.warnings = lib.mkOption {
        type = lib.types.listOf alib.types.warning;
        default = [ ];
      };

      config.build.state = { ... }: {
        name = config.name;
      };
    };
}
