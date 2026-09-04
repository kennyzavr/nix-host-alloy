{
  lib,
  alib,
  # moduleLocation,
  config,
  ...
}:
let
  alloy = config;
  indexFact = alloy.vars.facts.${alloy.vars.provisioners."host-indexes".facts.index.name};
in
{
  options.hosts = alib.extend (
    { name, config, ... }: {
      options = {
        id = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = name;
          description = "The unique identifier of this entity.";
        };
        idx = lib.mkOption {
          type = lib.types.ints.unsigned;
          readOnly = true;
          default = indexFact.value.items.${config.id};
          description = "The unique numeric index of this host from the state database.";
        };
        system = lib.mkOption {
          type = lib.types.str;
          description = "The target system architecture (e.g., 'x86_64-linux') for the host.";
        };
        nixosModule = lib.mkOption {
          type = lib.types.deferredModule;
          default = { };
          description = "The NixOS configuration module accumulated for this host.";
          apply = module: {
            _class = "nixos";
            # _file = "${toString moduleLocation}#hosts.${lib.strings.escapeNixIdentifier name}.nixosModule";
            _file = "hosts.${lib.strings.escapeNixIdentifier name}.nixosModule";
            imports = [ module ];
          };
        };
        nixosConfiguration = lib.mkOption {
          type = lib.types.raw;
          readOnly = true;
          description = "The evaluated NixOS system configuration for this host.";
        };
      };
      config = {
        nixosConfiguration = lib.nixosSystem {
          inherit (config) system;
          modules = [
            {
              imports = [
                config.nixosModule
              ];

              networking.useNetworkd = true;
              systemd.network.enable = true;
              networking.nftables.enable = true;
            }
          ];
        };
      };
    }
  );

  config.vars.provisioners."host-indexes" = {
    spec.index-allocator = {
      minValue = 1;
      maxValue = 99;
      reuseValues = true;
      keys = lib.mapAttrsToList (_: h: h.id) alloy.hosts;
    };
    facts.index = { };
  };
}
