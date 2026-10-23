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
            type = lib.types.nullOr lib.types.str;
            description = "Host network whose address this SSH listener binds to; null creates a listener without a named network address.";
          };
          port = lib.mkOption {
            type = lib.types.port;
            description = "TCP port used by this SSH listener.";
          };
        };
      };

      userSubmodule = { config, name, ... }: {
        options.ssh = {
          authKeyFacts = lib.mkOption {
            default = [ ];
            type = lib.types.listOf (lib.types.str);
            description = "Facts containing authorized public keys for this user.";
          };
        };
      };

      keySubmodule = { config, name, ... }: {
        options = {
          type = lib.mkOption {
            type = lib.types.enum [
              "ed25519"
              "rsa"
            ];
            default = "ed25519";
          };
          bits = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.positive;
            default = if config.type == "rsa" then 4096 else null;
            description = "RSA size; null for Ed25519. Existing keys are never rotated automatically.";
          };
          path = lib.mkOption {
            type = lib.types.strMatching "/[a-zA-Z0-9_./-]+";
            default = "/var/lib/alloy/ssh/keys/${name}";
            description = "Persistent private key path on the host, generated at runtime.";
          };
          publicKeyPath = lib.mkOption {
            type = lib.types.str;
            readOnly = true;
            default = "${config.path}.pub";
            description = "Public key path derived from `path`.";
          };
        };
      };

      hostSubmodule = { config, name, ... }: {
        options.ssh = {
          keys = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule keySubmodule);
            default = { };
            description = "Root-owned keys generated independently of ssh.enable. Select their consumers explicitly with keyPaths or boot.files.";
          };
          enable = lib.mkOption {
            default = false;
            type = lib.types.bool;
            description = "Whether to enable the SSH server on this host.";
          };
          listen = lib.mkOption {
            default = [ ];
            type = lib.types.listOf (lib.types.submodule (listenSubmodule config));
            description = "SSH listener addresses and ports configured for this host.";
          };
          keyPaths = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "Generated private key paths installed as SSH host keys.";
          };
        };

        options.boot.ssh = {
          enable = lib.mkOption {
            default = false;
            type = lib.types.bool;
            description = "Whether to start the SSH server from the initrd.";
          };
          port = lib.mkOption {
            type = lib.types.port;
            description = "TCP port used by the initrd SSH server.";
          };
          authKeyFacts = lib.mkOption {
            default = [ ];
            type = lib.types.listOf lib.types.str;
            description = "Facts containing public keys authorized to access the initrd SSH server.";
          };
          keyPaths = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "Generated private key paths included as initrd SSH host keys.";
          };
        };

        options.users = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule userSubmodule);
        };

        config = lib.mkMerge [
          {
            assertions = [
              {
                assertion =
                  let
                    paths = lib.concatMap (key: [
                      key.path
                      key.publicKeyPath
                    ]) (builtins.attrValues config.ssh.keys);
                  in
                  builtins.length paths == builtins.length (lib.unique paths);
                message = "[Alloy] Host '${name}': Generated SSH private and public key paths must be unique. Set distinct `path` values in `ssh.keys`.";
              }
            ]
            ++ lib.concatLists (
              lib.mapAttrsToList (keyName: key: [
                {
                  assertion = builtins.match "[a-zA-Z0-9_-]+" keyName != null;
                  message = "[Alloy] Host '${name}', SSH key '${keyName}': The name may contain only letters, numbers, underscores, and hyphens.";
                }
                {
                  assertion =
                    (key.type == "ed25519" && key.bits == null)
                    || (key.type == "rsa" && key.bits != null && key.bits >= 2048);
                  message = "[Alloy] Host '${name}', SSH key '${keyName}': Set `bits = null` for Ed25519 or at least 2048 bits for RSA.";
                }
                {
                  assertion =
                    !(lib.hasPrefix "/nix/store/" key.path)
                    && lib.all (part: part != "" && part != "." && part != "..") (
                      lib.tail (lib.splitString "/" key.path)
                    );
                  message = "[Alloy] Host '${name}', SSH key '${keyName}': `path` must be a normalized persistent path outside `/nix/store`.";
                }
              ]) config.ssh.keys
            );
          }
          (lib.mkIf (config.ssh.keys != { }) {
            nixosModule = { pkgs, ... }: {
              systemd.services.alloy-ssh-keygen = {
                description = "Generate Alloy SSH host keys";
                wantedBy = [ "multi-user.target" ];
                unitConfig.RequiresMountsFor = lib.map (key: builtins.dirOf key.path) (
                  builtins.attrValues config.ssh.keys
                );
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  UMask = "0077";
                  RuntimeDirectory = "alloy-ssh-keygen";
                  RuntimeDirectoryMode = "0700";
                  StateDirectory = "alloy/ssh/keys";
                  StateDirectoryMode = "0700";
                };
                path = [
                  pkgs.openssh
                  pkgs.coreutils
                  pkgs.util-linux
                ];
                script = ''
                  set -euo pipefail
                  exec 9>/run/alloy-ssh-keygen/lock
                  flock -x 9
                  ${builtins.readFile ./ssh-keygen.sh}
                  ${lib.concatMapStringsSep "\n" (
                    key:
                    "generate_key ${
                      lib.escapeShellArgs [
                        key.path
                        key.type
                        (if key.bits == null then "" else toString key.bits)
                      ]
                    }"
                  ) (builtins.attrValues config.ssh.keys)}
                '';
              };
              systemd.services.sshd = lib.mkIf config.ssh.enable {
                requires = [ "alloy-ssh-keygen.service" ];
                after = [ "alloy-ssh-keygen.service" ];
              };
            };
          })
          (lib.mkIf config.boot.ssh.enable {
            assertions = [
              {
                assertion = config.boot.ssh.keyPaths != [ ];
                message = "[Alloy] Host '${name}': Configure at least one host key path in `boot.ssh.keyPaths`.";
              }
            ];
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
                    /bin/chmod 0600 ${lib.escapeShellArg keyPath}
                  '') config.boot.ssh.keyPaths}
                '';
              };
            };
          })
          (lib.mkIf config.ssh.enable {
            assertions = [
              {
                assertion = builtins.length config.ssh.listen >= 1;
                message = "[Alloy] Host '${name}': Configure at least one listener in `ssh.listen`.";
              }
            ];

            nixosModule = { pkgs, ... }: {
              services.openssh = {
                enable = true;
                listenAddresses = lib.pipe config.ssh.listen [
                  (lib.map (
                    listen:
                    let
                      net = if listen.net != null then config.nets.${listen.net} else null;
                    in
                    [ ]
                    ++ (lib.optional (net == null) {
                      inherit (listen) port;
                    })
                    ++ (lib.optional (net != null && net.v4 != null) {
                      addr = net.v4.mode.static.address;
                      inherit (listen) port;
                    })
                    ++ (lib.optional (net != null && net.v6 != null) {
                      addr = net.v6.mode.static.address;
                      inherit (listen) port;
                    })
                  ))
                  lib.flatten
                ];
                settings = {
                  PermitRootLogin = "no";
                  PasswordAuthentication = false;
                };
                hostKeys = [ ];
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
