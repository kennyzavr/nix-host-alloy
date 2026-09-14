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
  ];

  flake.alloyModules.core = { alib, lib, ... }: {
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
      description = "List of assertions to validate the global configuration.";
    };
  };
}
