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
          # hypervisorPort = lib.mkOption {
          #   type = lib.types.nullOr lib.types.port;
          # };
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
          # hypervisorPort = lib.mkOption {
          #   type = lib.types.nullOr (lib.types.port);
          # };
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
          {
            # nixosModule = { pkgs, ... }: {
            #   system.activationScripts.prepareSshKeys = {
            #     text = lib.concatMapAttrsStringSep "\n" (keyName: key: ''
            #       $DRY_RUN_CMD mkdir -p "$(dirname "${key.path}")"
            #       $DRY_RUN_CMD ln -sf "${alloy.facts.${key.fact}.path}" "${key.path}"
            #     '') config.ssh.keys;
            #     text = lib.optionalString (config.ssh.ed25519KeyFact != null) ''
            #       SSH_DIR="/etc/ssh"

            #       KEY_FILE="$SSH_DIR/ssh_host_ed25519_key"
            #       PUB_KEY_FILE="$SSH_DIR/ssh_host_ed25519_key.pub"

            #       $DRY_RUN_CMD mkdir -p $(dirname ) "$SSH_DIR"
            #       $DRY_RUN_CMD chmod 755 "$SSH_DIR"
            #       $DRY_RUN_CMD cat "${alloy.facts.${config.ssh.ed25519KeyFact}.path}" > "$KEY_FILE"
            #       $DRY_RUN_CMD mkdir -p "$SSH_DIR"
            #       $DRY_RUN_CMD chmod 600 "$KEY_FILE"
            #       $DRY_RUN_CMD ${pkgs.openssh}/bin/ssh-keygen -y -f "$KEY_FILE" > "$PUB_KEY_FILE"
            #       echo "ssh key $KEY_FILE has been wrote"
            #     '';
            #     deps = [ "specialfs" ];
            #   };
            # };
          }
          (lib.mkIf config.boot.ssh.enable {
            # qemu.forwardPorts = [
            #   {
            #     name = "boot ssh";
            #     hypervisor =
            #       if config.boot.ssh.hypervisorPort != null then config.boot.ssh.hypervisorPort else 21500;
            #     guest = config.boot.ssh.port;
            #     proto = "tcp";
            #   }
            # ];

            nixosModule = { pkgs, ... }: {
              boot.initrd.network.ssh = {
                enable = true;
                port = config.boot.ssh.port;
                authorizedKeyFiles = lib.map (fact: alloy.facts.${fact}.path) config.boot.ssh.authKeyFacts;
                hostKey = config.boot.ssh.keyPaths;
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

            # qemu.forwardPorts = lib.imap0 (idx: l: {
            #   name = "ssh";
            #   hypervisor = if l.hypervisorPort != null then l.hypervisorPort else 21500 + config.idx + idx;
            #   guest = l.port;
            #   proto = "tcp";
            # }) config.ssh.listen;

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
