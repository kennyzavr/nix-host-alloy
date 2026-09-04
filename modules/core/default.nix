{
  lib,
  alib,
  ...
}:
{
  imports = [
    ./cli.nix
    ./hosts.nix
    ./jails.nix
    ./vars
  ];

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
}
