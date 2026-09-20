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

      listenSubmodule = host: {
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
            type = lib.types.listOf (lib.types.submodule (listenSubmodule config));
          };
          keyPaths = lib.mkOption {
            type = lib.types.listOf lib.types.str;
          };
        };

        options.boot.ssh = {
          enable = lib.mkOption {
            default = false;
            type = lib.types.bool;
          };
          port = lib.mkOption {
            type = lib.types.port;
          };
          authKeyFacts = lib.mkOption {
            default = [ ];
            type = lib.types.listOf lib.types.str;
          };
          keyPaths = lib.mkOption {
            type = lib.types.listOf lib.types.str;
          };
        };

        options.users = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule userSubmodule);
        };

        config = lib.mkMerge [
          (lib.mkIf config.boot.ssh.enable {
            nixosModule = { pkgs, ... }: {
              boot.initrd.network.ssh = {
                enable = true;
                port = config.boot.ssh.port;
                authorizedKeyFiles = lib.map (fact: alloy.facts.${fact}.path) config.boot.ssh.authKeyFacts;
                ignoreEmptyHostKeys = true;
                extraConfig = ''
                  ${lib.concatMapStringsSep "\n" (keyPath: ''
                    HostKey ${keyPath}
                  '') config.boot.ssh.keyPaths}
                '';
              };
              boot.initrd.systemd.services.sshd = {
                preStart = ''
                  ${lib.concatMapStringsSep "\n" (keyPath: ''
                    /bin/chmod 0600 "${keyPath}"
                  '') config.boot.ssh.keyPaths}
                '';
              };
            };
          })
          (lib.mkIf config.ssh.enable {
            assertions = [
              {
                assertion = builtins.length config.ssh.listen >= 1;
                message = "[Alloy] Host '${name}': at least one ssh listener must be specified";
              }
            ];

            nixosModule = { pkgs, ... }: {
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
                hostKeys = [];
                # TODO: disable default keys
                extraConfig = ''
                  ${lib.concatMapStringsSep "\n" (keyPath: ''
                    HostKey ${keyPath}
                  '') config.ssh.keyPaths}
                '';
              };
              users.users = lib.mapAttrs (_: user: {
                openssh.authorizedKeys.keyFiles = lib.map (fact: alloy.facts.${fact}.path) user.ssh.authKeyFacts;
              }) config.users;
            };
          })
        ];
      };
    in
    {
      options.hosts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
      };
    };
}
