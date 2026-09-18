{
  imports = [
    ./hosts.nix
    ./jails.nix
    ./cli.nix
    ./secrets.nix
    ./facts.nix
    ./generators.nix
    ./indexes.nix
    ./overlays.nix
    ./tls
    ./dns.nix
    ./mtls.nix
    ./endpoints.nix
    ./state.nix
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
      };

      options.workspace = {
        root = lib.mkOption {
          type = lib.types.path;
        };
        baseDir = lib.mkOption {
          default = ".";
          type = lib.types.str;
        };
      };

      options.assertions = lib.mkOption {
        type = lib.types.listOf alib.types.assertion;
        default = [ ];
      };

      config._internal.state = { ... }: {
        name = config.name;
      };
    };
}
