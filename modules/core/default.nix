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
    # ./gateways.nix
    ./endpoints.nix
    # ./tls.nix
    # ./acme.nix
    # ./static-ca.nix
    ./state.nix
    ./volumes.nix
  ];

  flake.alloyModules.core = { alib, lib, ... }: {
    options.workspace = {
      root = lib.mkOption {
        type = lib.types.path;
      };
    };

    options.assertions = lib.mkOption {
      type = lib.types.listOf alib.types.assertion;
      default = [ ];
      description = "List of assertions to validate the global configuration.";
    };
  };
}
