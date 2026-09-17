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
          hypervisorPort = lib.mkOption {
            default = 22490 + host.idx;
            type = lib.types.nullOr (lib.types.port);
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
          ed25519KeyFact = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
          };
          key.ed25519.fact = lib.mkOption { };
        };

        options.users = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule userSubmodule);
        };

        config = lib.mkMerge [
          {
            nixosModule = { pkgs, ... }: {
              system.activationScripts.prepareSshKeys = {
                text = lib.optionalString (config.ssh.ed25519KeyFact != null) ''
                  SSH_DIR="/etc/ssh"

                  KEY_FILE="$SSH_DIR/ssh_host_ed25519_key"
                  PUB_KEY_FILE="$SSH_DIR/ssh_host_ed25519_key.pub"

                  $DRY_RUN_CMD mkdir -p "$SSH_DIR"
                  $DRY_RUN_CMD chmod 755 "$SSH_DIR"
                  $DRY_RUN_CMD echo "${alloy.facts.${config.ssh.ed25519KeyFact}.path}" > "$KEY_FILE"
                  $DRY_RUN_CMD mkdir -p "$SSH_DIR"
                  $DRY_RUN_CMD chmod 600 "$KEY_FILE"
                  $DRY_RUN_CMD ${pkgs.openssh}/bin/ssh-keygen -y -f "$KEY_FILE" > "$PUB_KEY_FILE"
                  echo "ssh key $KEY_FILE has been wrote"
                '';
                deps = [ "specialfs" ];
              };
            };
          }
          (lib.mkIf config.ssh.enable {
            assertions = [
              {
                assertion = builtins.length config.ssh.listen >= 1;
                message = "[Alloy] Host '${name}': at least one ssh listener must be specified";
              }
            ];

            qemu.forwardPorts = lib.pipe config.ssh.listen [
              (lib.filter (l: l.hypervisorPort != null))
              (lib.map (l: {
                name = "ssh";
                hypervisor = l.hypervisorPort;
                guest = l.port;
                proto = "tcp";
              }))
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
