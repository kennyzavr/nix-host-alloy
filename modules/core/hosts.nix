{
  flake.alloyModules.core =
    {
      lib,
      config,
      alib,
      ...
    }:
    let
      alloy = config;

      hostSubmodule = { name, config, ... }: {
        options = {
          idx = lib.mkOption {
            type = lib.types.ints.unsigned;
            readOnly = true;
          };
          system = lib.mkOption {
            type = lib.types.str;
          };
          nixosModule = lib.mkOption {
            type = lib.types.deferredModule;
            default = { };
            apply = module: {
              _class = "nixos";
              _file = "hosts.${lib.strings.escapeNixIdentifier name}.nixosModule";
              imports = [ module ];
            };
          };
          nixosConfiguration = lib.mkOption {
            readOnly = true;
            type = lib.types.unspecified;
          };
          assertions = lib.mkOption {
            type = lib.types.listOf lib.types.unspecified;
            default = [ ];
          };
        };
        config = {
          idx = alloy.indexes."hosts".get name;
          assertions = [
            {
              assertion = alib.types.dns.label.check name;
              message = "[Alloy] Host name '${name}' contains invalid characters or is too long. Use only lowercase letters, numbers, and hyphens (max 63 characters).";
            }
          ];
          nixosConfiguration = lib.nixosSystem {
            inherit (config) system;
            modules = [
              config.nixosModule
              {
                system.stateVersion = "26.05";
                networking.useNetworkd = true;
                systemd.network.enable = true;
                networking.nftables.enable = true;

                boot.kernel.sysctl = {
                  "net.ipv4.ip_forward" = true;
                  "net.ipv6.conf.all.forwarding" = true;
                  "net.ipv4.conf.all.accept_redirects" = false;
                  "net.ipv6.conf.all.accept_redirects" = false;
                };
              }
            ];
          };
        };
      };
    in
    {
      options.hosts = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
      };

      config = {
        assertions = lib.flatten (lib.mapAttrsToList (_: host: host.assertions) alloy.hosts);

        indexes."hosts" = {
          keys = builtins.attrNames alloy.hosts;
          minValue = 1;
          maxValue = 99;
        };

        _internal.state = { ... }: {
          hosts = lib.mapAttrsToList (hostName: host: {
            name = hostName;
          }) alloy.hosts;
        };
      };
    };
}
