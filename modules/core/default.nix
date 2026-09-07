{
  lib,
  alib,
  ...
}:
{
  imports = [
    ./hosts.nix
    ./jails.nix
    ./cli.nix
    ./secrets.nix
    ./facts.nix
    ./generators.nix
    ./index-table.nix
    ./overlays.nix
  ];

  options.workspace = {
    root = lib.mkOption {
      type = lib.types.path;
    };
  };

  options.core.api = lib.mkOption {
    default = { };
    type = lib.types.attrsOf lib.types.unspecified;
  };

  options.assertions = lib.mkOption {
    type = lib.types.listOf alib.types.assertion;
    default = [ ];
    description = "List of assertions to validate the global configuration.";
  };
}
