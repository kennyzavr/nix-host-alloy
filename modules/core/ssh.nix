{
  flake.alloyModules.core =
    {
      config,
      alib,
      lib,
      ...
    }:
    let
      alloy = config;

      listenSubmodule = {
        options = {
          net = lib.mkOption {
            type = lib.types.str;
          };
          port = lib.mkOption {
            type = lib.types.port;
          };
        };
      };

      userSubmodule = { config, name, ... }: {
        options.ssh = {
          allowPasswdAuth = lib.mkOption {
            default = false;
            type = lib.types.bool;
          };
          authKeyFacts = lib.mkOption {
            default = [ ];
            type = lib.types.listOf (lib.types.str);
          };
        };
      };

      hostSubmodule = { config, name, ... }: {
        options.ssh = {
          enable = lib.mkOption {
            default = false;
            type = lib.types.bool;
          };
          listen = lib.mkOption {
            default = [ ];
            type = lib.types.listof (lib.types.submodule listenSubmodule);
          };
        };

        options.users = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule userSubmodule);
        };

        config = lib.mkif config.ssh.enable {
          assertions = [
            {
              assertion = builtins.length config.ssh.listen >= 1;
              message = "[Alloy] Host '${name}': at least one ssh listener must be specified";
            }
          ];
          nixosModule = {
            services.openssh = {
              enable = true;
              listenAddresses = lib.pipe config.ssh.listen [
                (lib.map (
                  listen:
                  let
                    net = config.nets.${listen.net};
                  in
                  [ ]
                  ++ (lib.optional (net.v4 != null) {
                    addr = net.v4.address;
                    inherit (listen) port;
                  })
                  ++ (lib.optional (net.v6 != null) {
                    addr = net.v6.address;
                    inherit (listen) port;
                  })
                ))
                lib.flatten
              ];
              settings = {
                PermitRootLogin = "no";
                PasswordAuthentication = false;
              };
            };
            users.users = lib.mapAttrs (user: {
              openssh.authorizedKeys.keyFiles = lib.map (fact: alloy.facts.${user}.path) user.ssh.authKeyFacts;
            }) config.users;
          };
        };
      };
    in
    {
      options.hosts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
      };
    };
}
