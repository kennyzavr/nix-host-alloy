{ withSystem, ... }:
{
  flake.alloyModules.core =
    { config, lib, ... }:
    let
      alloy = config;

      signingKeySubmodule = { name, config, ... }: {
        options = {
          privateKeySecret = lib.mkOption {
            type = lib.types.nonEmptyStr;
            default = "deploy/signing-keys/${name}/private";
            description = "Name of the master secret read only when deploying. Never deployed to a host. Disabling the generator permits an absent private secret.";
          };
          publicKeyFact = lib.mkOption {
            type = lib.types.nonEmptyStr;
            default = "deploy/signing-keys/${name}/public";
            description = "Fact containing the public Nix signing key.";
          };
          generator = lib.mkOption {
            type = lib.types.nonEmptyStr;
            default = "deploy/signing-keys/${name}";
            description = "Generator instance creating this key pair. Disable it through generators.instances.<name>.enable to use an existing public key without a local private secret.";
          };
        };
      };

      connectionSubmodule = { ... }: {
        options = {
          address = lib.mkOption {
            type = lib.types.nonEmptyStr;
            description = "SSH address or alias, resolved on the machine running the deployment CLI.";
          };
          user = lib.mkOption {
            type = lib.types.nullOr lib.types.nonEmptyStr;
            default = null;
            description = "SSH user; null inherits the local OpenSSH configuration.";
          };
          port = lib.mkOption {
            type = lib.types.nullOr lib.types.port;
            default = null;
            description = "SSH port; null inherits the local OpenSSH configuration.";
          };
        };
      };

      hostSubmodule = { name, config, ... }: {
        options.deploy = {
          enable = lib.mkEnableOption "remote deployment configuration for this host";
          connections = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule connectionSubmodule);
            default = { };
            description = "Named SSH connections to this host, not different system configurations.";
          };
          defaultConnection = lib.mkOption {
            type = lib.types.nullOr lib.types.nonEmptyStr;
            default =
              let
                names = builtins.attrNames config.deploy.connections;
              in
              if builtins.length names == 1 then builtins.head names else null;
            description = "Default connection; inferred only when exactly one connection exists. Multiple connections require an explicit default.";
          };
          signingKeys = lib.mkOption {
            type = lib.types.listOf lib.types.nonEmptyStr;
            default = [ ];
            description = "Names in deploy.signingKeys used to sign the complete deployment closure.";
          };
          trustedSigningKeys = lib.mkOption {
            type = lib.types.listOf lib.types.nonEmptyStr;
            default = config.deploy.signingKeys;
            description = "Names in deploy.signingKeys trusted by this host. May include old keys whose generators are disabled during rotation.";
          };
          target = lib.mkOption {
            type = lib.types.attrTag {
              host = lib.mkOption {
                type = lib.types.submodule { };
              };
              qemu = lib.mkOption {
                type = lib.types.submodule {
                  options.variant = lib.mkOption {
                    default = "full-boot";
                    type = lib.types.str;
                  };
                };
              };
            };
            default = {
              host = { };
            };
          };
          targetToplevel = lib.mkOption {
            type = lib.types.unspecified;
            readOnly = true;
            default =
              if config.deploy.target ? host then
                config.nixosConfig.system.build.toplevel
              else
                config.qemu.variants."${config.deploy.target.qemu.variant}".nixosConfig.system.build.toplevel;
          };
          activation = {
            policy = lib.mkOption {
              type = lib.types.enum [
                "strict"
                "warn"
              ];
              default = "strict";
              description = ''
                How to handle a non-zero switch-to-configuration exit. strict
                fails deployment. warn succeeds with a warning only if
                /run/current-system resolves to the requested toplevel.
              '';
            };
            method = lib.mkOption {
              type = lib.types.enum [
                "sudo"
                "direct"
              ];
              default = "sudo";
              description = "Remote privilege escalation; direct requires an already privileged SSH session.";
            };
            askPassword = lib.mkOption {
              type = lib.types.bool;
              default = config.deploy.activation.method == "sudo";
              description = "Request the remote sudo password interactively; false requires non-interactive sudo.";
            };
          };
        };

        config = {
          assertions = lib.optionals config.deploy.enable (
            [
              {
                assertion = config.deploy.connections != { };
                message = "[Alloy] Host '${name}': Configure at least one connection in `deploy.connections`.";
              }
              {
                assertion =
                  config.deploy.defaultConnection != null
                  && builtins.hasAttr config.deploy.defaultConnection config.deploy.connections;
                message = "[Alloy] Host '${name}': `deploy.defaultConnection` must name an entry in `deploy.connections`. Set it explicitly when multiple connections are configured.";
              }
              {
                assertion = config.deploy.signingKeys != [ ];
                message = "[Alloy] Host '${name}': Add at least one key to `deploy.signingKeys`.";
              }
              {
                assertion = config.deploy.activation.method == "sudo" || !config.deploy.activation.askPassword;
                message = "[Alloy] Host '${name}': `deploy.activation.askPassword` is supported only with method `sudo`.";
              }
            ]
            ++ lib.map (keyName: {
              assertion = builtins.hasAttr keyName alloy.deploy.signingKeys;
              message = "[Alloy] Host '${name}': Signing key '${keyName}' is not defined in `deploy.signingKeys`.";
            }) (lib.unique (config.deploy.signingKeys ++ config.deploy.trustedSigningKeys))
            ++ lib.map (keyName: {
              assertion = builtins.elem keyName config.deploy.trustedSigningKeys;
              message = "[Alloy] Host '${name}': Signing key '${keyName}' must also appear in `deploy.trustedSigningKeys`.";
            }) config.deploy.signingKeys
            ++ lib.mapAttrsToList (connectionName: connection: {
              assertion =
                builtins.match "[^[:space:]]+" connection.address != null && !lib.hasPrefix "-" connection.address;
              message = "[Alloy] Host '${name}', deploy connection '${connectionName}': `address` must be an SSH address or alias without whitespace or a leading `-`.";
            }) config.deploy.connections
          );

          nixosModule = {
            nix.settings.extra-trusted-public-keys = lib.mkIf config.deploy.enable (
              lib.map (keyName: lib.trim alloy.facts.${alloy.deploy.signingKeys.${keyName}.publicKeyFact}.value) (
                lib.filter (keyName: builtins.hasAttr keyName alloy.deploy.signingKeys) (
                  lib.unique config.deploy.trustedSigningKeys
                )
              )
            );
          };
        };
      };
    in
    {
      options = {
        deploy.signingKeys = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule signingKeySubmodule);
          default = { };
          description = "Registry of Nix store signing keys and their secret, fact, and generator names.";
        };
        hosts = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
        };
      };

      config.assertions = [
        {
          assertion = lib.allUnique (lib.mapAttrsToList (_: key: key.generator) alloy.deploy.signingKeys);
          message = "[Alloy] Deploy signing keys: Each key must use a distinct generator name.";
        }
        {
          assertion = lib.allUnique (
            lib.mapAttrsToList (_: key: key.privateKeySecret) alloy.deploy.signingKeys
          );
          message = "[Alloy] Deploy signing keys: Each key must use a distinct `privateKeySecret` name.";
        }
        {
          assertion = lib.allUnique (lib.mapAttrsToList (_: key: key.publicKeyFact) alloy.deploy.signingKeys);
          message = "[Alloy] Deploy signing keys: Each key must use a distinct `publicKeyFact` name.";
        }
      ]
      ++ lib.concatLists (
        lib.mapAttrsToList (name: key: [
          {
            assertion = builtins.hasAttr key.publicKeyFact alloy.facts;
            message = "[Alloy] Deploy signing key '${name}': Fact '${key.publicKeyFact}' is not defined in `facts`.";
          }
          {
            assertion = builtins.match "[^[:space:]:]+" name != null;
            message = "[Alloy] Deploy signing key '${name}': The key name cannot contain whitespace or `:`.";
          }
          {
            assertion =
              builtins.hasAttr key.publicKeyFact alloy.facts
              -> alloy.facts.${key.publicKeyFact}.exists
              ->
                builtins.match "[^[:space:]:]+:[A-Za-z0-9+/]{43}=" (lib.trim alloy.facts.${key.publicKeyFact}.value)
                != null;
            message = "[Alloy] Deploy signing key '${name}': `publicKeyFact` must contain one Nix Ed25519 public key in `name:base64` format.";
          }
        ]) alloy.deploy.signingKeys
      );

      config.facts = lib.mkMerge (
        lib.mapAttrsToList (_: key: {
          ${key.publicKeyFact} = { };
        }) alloy.deploy.signingKeys
      );

      config.generators.instances = lib.mapAttrs' (
        name: key:
        lib.nameValuePair key.generator {
          imports = [ alloy.generators.templates."deploy/signing-key" ];
          keyName = name;
          inherit (key) privateKeySecret publicKeyFact;
        }
      ) alloy.deploy.signingKeys;

      config.generators.templates."deploy/signing-key" = { config, ... }: {
        options = {
          keyName = lib.mkOption { type = lib.types.nonEmptyStr; };
          privateKeySecret = lib.mkOption { type = lib.types.nonEmptyStr; };
          publicKeyFact = lib.mkOption { type = lib.types.nonEmptyStr; };
        };
        config = {
          description = "Generate a Nix store signing key pair";
          tags = [
            "nix"
            "deploy/signing-keys"
            "deploy"
          ];
          secrets.${config.privateKeySecret} = { };
          facts.${config.publicKeyFact} = { };
          package =
            { system, ... }:
            withSystem system (
              { pkgs, ... }:
              pkgs.writeShellApplication {
                name = "generate-nix-signing-key";
                runtimeInputs = [ pkgs.nix ];
                text = ''
                  set +x
                  umask 077
                  trap 'unset private_key' EXIT

                  private_key="$(
                    nix --extra-experimental-features nix-command \
                      key generate-secret --key-name ${lib.escapeShellArg config.keyName}
                  )"
                  public_key="$(
                    printf '%s\n' "$private_key" |
                      nix --extra-experimental-features nix-command key convert-secret-to-public
                  )"

                  "$ALLOY_BIN" secrets set ${lib.escapeShellArg config.privateKeySecret} <<< "$private_key"
                  unset private_key
                  "$ALLOY_BIN" facts set ${lib.escapeShellArg config.publicKeyFact} <<< "$public_key"
                '';
              }
            );
        };
      };

      config.build.state = { ... }: {
        deploy.signingKeys = lib.mapAttrs (_: key: {
          inherit (key) privateKeySecret publicKeyFact generator;
        }) alloy.deploy.signingKeys;
        hosts = lib.mapAttrs (_: host: {
          deploy = {
            inherit (host.deploy)
              enable
              connections
              defaultConnection
              signingKeys
              trustedSigningKeys
              activation
              ;
          };
        }) alloy.hosts;
      };
    };
}
