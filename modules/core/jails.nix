{
  lib,
  alib,
  config,
  ...
}:
let
  alloy = config;

  # TODO: uplink: localIdx & assertions
  indexes = alloy.facts."jail-index-table".value;

  jailSubmodule =
    {
      name,
      config,
      options,
      ...
    }:
    {
      options = {
        idx = lib.mkOption {
          type = lib.types.ints.unsigned;
          readOnly = true;
          default = indexes.${name};
        };
        host = lib.mkOption {
          type = lib.types.str;
        };
        nixosModule = lib.mkOption {
          type = lib.types.deferredModule;
          default = { };
          apply = module: {
            _class = "nixos";
            _file = "jails.${lib.strings.escapeNixIdentifier name}.nixosModule";
            imports = [ module ];
          };
        };
        assertions = lib.mkOption {
          type = lib.types.listOf alib.types.assertion;
          default = [ ];
        };
      };

      config = {
        assertions = [
          {
            assertion = builtins.hasAttr config.host alloy.hosts;
            message = ''
              [Alloy] Invalid host reference in jail '${name}'

              You attempted to assign jail '${name}' to host '${config.host}',
              but this host is not declared in 'hosts'.

              Location:
              ${lib.concatStringsSep "\n" (map (f: "  - ${f}") options.host.files)}
            '';
          }
        ];
      };
    };

  hostSubmodule = { name, ... }: {
    config = {
      nixosModule = { pkgs, ... }: {
        containers = lib.mapAttrs' (
          jailName: jail:
          lib.nameValuePair "alloy-jail-${jailName}" {
            autoStart = true;
            ephemeral = true;
            privateUsers = "no";
            config = {
              imports = [
                jail.nixosModule
              ];

              nixpkgs.pkgs = lib.mkDefault pkgs;

              networking.useNetworkd = true;
              systemd.network.enable = true;
              networking.nftables.enable = true;
              networking.useHostResolvConf = false;
            };
          }
        ) (lib.filterAttrs (_: jail: jail.host == name) alloy.jails);
      };
    };
  };
in
{
  options.jails = lib.mkOption {
    default = { };
    type = lib.types.attrsOf (lib.types.submodule jailSubmodule);
  };

  options.hosts = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
  };

  config = {
    generators.instances."jail-index-table" = {
      imports = [
        alloy.generators.templates."index-table"
      ];

      name = "jail-index-table";
      keys = builtins.attrNames alloy.jails;
      minValue = 1;
      maxValue = 999;
    };

    assertions = lib.flatten (lib.mapAttrsToList (_: jail: jail.assertions) alloy.jails);
  };
}
