{
  alib,
  lib,
  config,
  alloy-internal-inputs,
  ...
}:
let
  alloy = config;

  identityType = lib.types.submodule {
    options = {
      identity = lib.mkOption {
        type = lib.types.oneOf [
          lib.types.path
          lib.types.str
        ];
      };
      pubkey = lib.mkOption {
        type = lib.types.oneOf [
          lib.types.path
          lib.types.str
        ];
      };
    };
  };

  secretModule = { config, name, ... }: {
    options = {
      id = alib.mkIdOpt name "";
      ageFile = lib.mkOption {
        type = lib.types.str;
        default = "${alloy.workspace.vars.secrets.baseDir}/${config.id}.age";
      };
      tags = lib.mkOption {
        default = [ ];
        type = lib.types.listOf lib.types.str;
      };
    };
  };

  hostSecretModule = host: { config, name, ... }: {
    options = {
      id = alib.mkIdOpt name "";
      source = lib.mkOption {
        type = lib.types.str;
        default = name;
      };
      ageFile = lib.mkOption {
        type = lib.types.str;
        default = "${host.workspace.vars.secrets.baseDir}/${config.id}.age";
      };
      path = lib.mkOption {
        type = lib.types.str;
        default = "/run/alloy/vars/secrets/${config.id}";
      };
      permissions = lib.mkOption {
        type = alib.types.permissions;
        default = {
          mode = "0400";
        };
      };
    };
  };

  jailSecretModule = jail: { config, name, ... }: {
    options = {
      id = alib.mkIdOpt name "";
      source = lib.mkOption {
        type = lib.types.str;
        default = name;
      };
      ageFile = lib.mkOption {
        type = lib.types.str;
        default = "${jail.workspace.vars.secrets.baseDir}/${config.id}.age";
      };
      path = lib.mkOption {
        type = lib.types.str;
        default = "/run/alloy/vars/secrets/${config.id}";
      };
      permissions = lib.mkOption {
        type = alib.types.permissions;
        default = {
          mode = "0400";
        };
      };
    };
  };

  mkHost = host: {
    nixosModule = { config, ... }: {
      imports = [
        alloy-internal-inputs.agenix.nixosModules.default
      ];

      containers = lib.pipe alloy.jails [
        builtins.attrValues
        (lib.filter (jail: jail.host == host.id))
        (lib.map (jail: {
          "alloy-jail-${jail.id}" = {
            bindMounts = lib.mapAttrs' (
              _: secret:
              lib.nameValuePair "secret-${secret.id}" {
                hostPath = config.age.secrets."alloy/vars/secrets/jail/${jail.id}/${secret.id}".path;
                mountPoint = config.age.secrets."alloy/vars/secrets/jail/${jail.id}/${secret.id}".path;
                isReadOnly = true;
              }
            ) jail.vars.secrets;
            config.system.activationScripts.setupSecrets = {
              deps = [
                "users"
                "groups"
              ];
              text = lib.concatMapAttrsStringSep "\n" (_: secret: ''
                install -D \
                  -m "${secret.permissions.mode}" \
                  -o "${secret.permissions.owner}" \
                  -g "${secret.permissions.group}" \
                  "${config.age.secrets."alloy/vars/secrets/jail/${jail.id}/${secret.id}".path}" \
                  "${secret.path}"
              '') jail.vars.secrets;
            };
          };
        }))
        lib.mkMerge
      ];

      age.identityPaths = lib.map (i: toString i.identity) host.workspace.vars.secrets.identities;
      age.secrets = lib.mkMerge [
        (lib.pipe host.vars.secrets [
          builtins.attrValues
          (lib.map (secret: {
            "alloy/vars/secrets/host/${secret.id}" = {
              file = alloy.workspace.root + "/${secret.ageFile}";
              path = secret.path;
              inherit (secret.permissions)
                owner
                group
                mode
                ;
            };
          }))
          lib.flatten
          lib.mkMerge
        ])
        (lib.pipe alloy.jails [
          builtins.attrValues
          (lib.filter (jail: jail.host == host.id))
          (lib.map (
            jail:
            lib.mapAttrsToList (_: secret: {
              "alloy/vars/secrets/jail/${jail.id}/${secret.id}" = {
                file = alloy.workspace.root + "/${secret.ageFile}";
                inherit (secret.permissions)
                  owner
                  group
                  mode
                  ;
              };
            }) jail.vars.secrets
          ))
          lib.flatten
          lib.mkMerge
        ])
      ];
    };
  };
in
{
  options = {
    workspace.vars.secrets = {
      baseDir = lib.mkOption {
        default = "vars/secrets/master";
        type = lib.types.str;
      };
      identities = lib.mkOption {
        default = [ ];
        type = lib.types.listOf identityType;
      };
    };

    vars.secrets = alib.extend secretModule;

    jails = alib.extend (
      { config, ... }: {
        options = {
          workspace.vars.secrets = {
            baseDir = lib.mkOption {
              default = "vars/secrets/jails/${config.id}";
            };
          };

          vars.secrets = alib.extend (jailSecretModule config);
        };
      }
    );

    hosts = alib.extend (
      { config, ... }:
      {
        options = {
          workspace.vars.secrets = {
            baseDir = lib.mkOption {
              default = "vars/secrets/hosts/${config.id}";
              type = lib.types.str;
            };
            identities = lib.mkOption {
              default = [ ];
              type = lib.types.listOf identityType;
            };
          };
          vars.secrets = alib.extend (hostSecretModule config);
        };
        config = {
          nixosModule = (mkHost config).nixosModule;
        };
      }
    );
  };

  config = {
    cli.commands.vars.commands.secrets =
      let
        baseCmds =
          let
            identities = alloy.workspace.vars.secrets.identities;
            rageRecipients = lib.concatMapStringsSep " " (
              i:
              "${
                if builtins.isPath i.pubkey || lib.hasPrefix "/" i.pubkey then "-R" else "-r"
              } ${lib.escapeShellArg i.pubkey}"
            ) identities;
            rageIdentities = lib.concatMapStringsSep " " (i: "-i ${lib.escapeShellArg i.identity}") identities;
          in
          ''
            encrypt() {
              local out_path="$1"

              if [ -z "$out_path" ]; then
                alloy_cli_echo_err "Output path required for encryption"
                return 1
              fi

              mkdir -p "$(dirname "$out_path")"
              rage -e ${rageRecipients} -o "$out_path" 
            }

            decrypt() {
              local in_path="$1"

              if [ ! -f "$in_path" ]; then
                alloy_cli_echo_err "Input file does not exist: $(alloy_cli_format_path "$in_path")"
                return 1
              fi

              rage -d ${rageIdentities} "$in_path" 
            }

            resolve_secret_file() {
              ${lib.concatMapStringsSep "\n" (secret: ''
                if [ "${secret.id}" = "$1" ]; then
                  echo ${lib.escapeShellArg secret.ageFile}
                  return 0
                fi
              '') (builtins.attrValues alloy.vars.secrets)}
              return 1
            }
          '';
      in
      {
        description = "manage alloy secrets";

        commands.edit = { config, ... }: {
          description = "Create or edit a secrets interactively";
          argsUsage = "<SECRET_ID>";
          flags = {
            add-to-git = {
              description = "Add edited secret to git via git add";
              short = "a";
            };
          };
          run =
            {
              pkgs,
              ...
            }:
            pkgs.writeShellApplication {
              name = "${config.name}-edit";
              checkPhase = "";
              runtimeInputs = [
                pkgs.rage
                pkgs.age-plugin-yubikey
                pkgs.age-plugin-fido2-hmac
                pkgs.coreutils
                pkgs.git
              ];
              text = ''
                ${baseCmds}

                if [ -z "$1" ]; then
                  alloy_cli_echo_err "Secret ID is required."
                  alloy_cli_show_help
                  exit 1
                fi
                if [ "$#" -gt 1 ]; then
                  alloy_cli_echo_err "Unexpected argument: $2"
                  alloy_cli_show_help
                  exit 1
                fi

                secret_file=$(resolve_secret_file "$1" || true)

                if [ -z "$secret_file" ]; then
                  alloy_cli_echo_err "Secret '$1' not found in configuration"
                  exit 1
                fi

                TARGET_FILE="$ALLOY_CLI_ROOT/$secret_file"
                if [ -d "/dev/shm" ]; then
                  export TMPDIR="/dev/shm"
                fi
                TMP_FILE=$(mktemp)
                trap 'rm -f "$TMP_FILE"' EXIT

                if [ -f "$TARGET_FILE" ]; then
                  alloy_cli_echo_step "Decrypting master secret..."
                  if ! decrypt "$TARGET_FILE" > "$TMP_FILE"; then
                    alloy_cli_echo_err "Failed to decrypt $(alloy_cli_format_path "$TARGET_FILE")"
                    exit 1
                  fi
                  BEFORE_HASH=$(sha256sum "$TMP_FILE" | cut -d' ' -f1)
                else
                  alloy_cli_echo_step "Creating new secret: ''${ALLOY_CLI_STYLE_BOLD}$1''${ALLOY_CLI_STYLE_NC}"
                  BEFORE_HASH=""
                fi

                ''${EDITOR:-nano} "$TMP_FILE"

                AFTER_HASH=$(sha256sum "$TMP_FILE" | cut -d' ' -f1)

                if [ "$BEFORE_HASH" = "$AFTER_HASH" ]; then
                  alloy_cli_echo_skip "No changes made, exiting."
                  exit 0
                fi

                if [ ! -s "$TMP_FILE" ]; then
                  alloy_cli_echo_err "File is empty, aborting encryption."
                  exit 1
                fi

                alloy_cli_echo_step "Encrypting and saving to $(alloy_cli_format_path "$TARGET_FILE")..."
                if ! encrypt "$TARGET_FILE" < "$TMP_FILE"; then
                  alloy_cli_echo_err "Failed to encrypt"
                  exit 1
                fi

                if [ "$ALLOY_CLI_FLAG_ADD_TO_GIT" -eq 1 ]; then
                  alloy_cli_echo_step "Adding to git index..."
                  git -C "$ALLOY_CLI_ROOT" add "$secret_file" || true
                fi

                alloy_cli_echo_ok "Secret '$1' saved successfully."
              '';
            };
        };

        commands.set = { config, ... }: {
          description = "Set a secret value from stdin";
          argsUsage = "<SECRET_ID>";
          flags = {
            add-to-git = {
              description = "Add edited secret to git via git add";
              short = "a";
            };
            force = {
              description = "Force overwriting even if the master secret already exists";
              short = "f";
            };
          };
          run =
            {
              pkgs,
              ...
            }:
            pkgs.writeShellApplication {
              name = "${config.name}-set";
              checkPhase = "";
              runtimeInputs = [
                pkgs.rage
                pkgs.age-plugin-yubikey
                pkgs.age-plugin-fido2-hmac
                pkgs.coreutils
                pkgs.git
              ];
              text = ''
                ${baseCmds}

                if [ -z "$1" ]; then
                  alloy_cli_echo_err "Secret ID is required."
                  alloy_cli_show_help
                  exit 1
                fi
                if [ "$#" -gt 1 ]; then
                  alloy_cli_echo_err "Unexpected argument: $2"
                  alloy_cli_show_help
                  exit 1
                fi

                secret_file=$(resolve_secret_file "$1" || true)

                if [ -z "$secret_file" ]; then
                  alloy_cli_echo_err "Secret '$1' not found in configuration"
                  exit 1
                fi

                TARGET_FILE="$ALLOY_CLI_ROOT/$secret_file"

                if [ "$ALLOY_CLI_FLAG_FORCE" -eq 0 ] && [ -f "$TARGET_FILE" ]; then
                  alloy_cli_echo_skip "Secret ''${ALLOY_CLI_STYLE_BOLD}$1''${ALLOY_CLI_STYLE_NC} already exists."
                  exit 0
                fi

                alloy_cli_echo_step "Reading from stdin and encrypting to '$(alloy_cli_format_path "$TARGET_FILE")'..."

                if ! encrypt "$TARGET_FILE" < /dev/stdin; then
                  alloy_cli_echo_err "Failed to encrypt"
                  exit 1
                fi

                if [ "$ALLOY_CLI_FLAG_ADD_TO_GIT" -eq 1 ]; then
                  alloy_cli_echo_step "Adding to git index..."
                  git -C "$ALLOY_CLI_ROOT" add "$secret_file" || true
                fi

                alloy_cli_echo_ok "Secret '$1' saved successfully."
              '';
            };
        };

        commands.view = { config, ... }: {
          description = "View a secret value in stdout";
          argsUsage = "<SECRET_ID>";
          run =
            {
              pkgs,
              ...
            }:
            pkgs.writeShellApplication {
              checkPhase = "";
              name = "${config.name}-view";
              runtimeInputs = [
                pkgs.rage
                pkgs.age-plugin-yubikey
                pkgs.age-plugin-fido2-hmac
              ];
              text = ''
                ${baseCmds}

                if [ -z "$1" ]; then
                  alloy_cli_echo_err "Secret ID is required."
                  alloy_cli_show_help
                  exit 1
                fi
                if [ "$#" -gt 1 ]; then
                  alloy_cli_echo_err "Unexpected argument: $2"
                  alloy_cli_show_help
                  exit 1
                fi

                secret_file=$(resolve_secret_file "$1" || true)

                if [ -z "$secret_file" ]; then
                  alloy_cli_echo_err "Secret '$1' not found in configuration"
                  exit 1
                fi

                TARGET_FILE="$ALLOY_CLI_ROOT/$secret_file"

                if [ ! -f "$TARGET_FILE" ]; then
                  alloy_cli_echo_err "File $(alloy_cli_format_path "$TARGET_FILE") does not exist"
                  exit 1
                fi

                decrypt "$TARGET_FILE"
              '';
            };
        };

        commands.rekey = { config, ... }: {
          description = "Rekey master secret values for hosts";
          flags = {
            add-to-git = {
              description = "Add rekeyed files to git via git add";
              short = "a";
            };
            force = {
              description = "Force rekeying even if host files already exist";
              short = "f";
            };
            tag = {
              description = "Select secrets matching the given tag (can be used multiple times)";
              type = "array";
              short = "t";
            };
            host = {
              description = "Select secrets matching the given host (can be used multiple times)";
              type = "array";
            };
          };
          run =
            {
              pkgs,
              ...
            }:
            pkgs.writeShellApplication {
              name = "${config.name}-rekey";
              checkPhase = "";
              runtimeInputs = [
                pkgs.rage
                pkgs.age-plugin-yubikey
                pkgs.age-plugin-fido2-hmac
                pkgs.coreutils
                pkgs.git
              ];
              text = ''
                ${baseCmds}

                RESOLVE_SECRETS__SECRETS=()
                for arg in "$@"; do
                  :
                  RESOLVE_SECRETS__SECRETS+=("$arg")
                done
                RESOLVE_SECRETS__TAGS=()
                if [ -n "''${ALLOY_CLI_FLAG_TAG:-}" ]; then
                  # shellcheck disable=SC2034
                  mapfile -d $'\x1f' -t RESOLVE_SECRETS__TAGS < <(printf %s "$ALLOY_CLI_FLAG_TAG")
                fi

                RESOLVE_SECRETS__FILES=()
                RESOLVE_SECRETS__IDS=()

                ${lib.concatMapStringsSep "\n" (secret: ''
                  RESOLVE_SECRETS__IS_SELECTED=0

                  if [ ''${#RESOLVE_SECRETS__SECRETS[@]} -eq 0 ] && [ ''${#RESOLVE_SECRETS__TAGS[@]} -eq 0 ]; then
                    RESOLVE_SECRETS__IS_SELECTED=1
                  else
                    for req_secret in "''${RESOLVE_SECRETS__SECRETS[@]}"; do
                      :
                      if [ "$req_secret" = "${secret.id}" ]; then
                        RESOLVE_SECRETS__IS_SELECTED=1
                        break
                      fi
                    done
                    if [ "$RESOLVE_SECRETS__IS_SELECTED" -eq 0 ]; then
                      for req_tag in "''${RESOLVE_SECRETS__TAGS[@]}"; do
                        : "$req_tag"
                        ${lib.concatMapStringsSep "\n" (t: ''
                          if [ "$req_tag" = ${lib.escapeShellArg t} ]; then
                            RESOLVE_SECRETS__IS_SELECTED=1
                            break
                          fi
                        '') secret.tags}
                        if [ "$RESOLVE_SECRETS__IS_SELECTED" -eq 1 ]; then break; fi
                      done
                    fi
                  fi

                  if [ "$RESOLVE_SECRETS__IS_SELECTED" -eq 1 ]; then
                    RESOLVE_SECRETS__FILES+=(${lib.escapeShellArg secret.ageFile})
                    RESOLVE_SECRETS__IDS+=(${lib.escapeShellArg secret.id})
                  fi
                '') (builtins.attrValues alloy.vars.secrets)}

                if [ ''${#RESOLVE_SECRETS__FILES[@]} -eq 0 ]; then
                  alloy_cli_echo_skip "No secrets matched the given filters."
                  exit 0
                fi

                ${lib.pipe alloy.hosts [
                  builtins.attrValues
                  (lib.map (host: ''
                    rekey_host_${host.id}() {
                      ${lib.optionalString (host.workspace.vars.secrets.identities == [ ]) ''
                        alloy_cli_echo_skip "Host ''${ALLOY_CLI_STYLE_BOLD}${host.id}''${ALLOY_CLI_STYLE_NC} has no identities defined"
                        return 1
                      ''}

                      alloy_cli_echo_step "Rekeying host: ''${ALLOY_CLI_STYLE_BOLD}${host.id}''${ALLOY_CLI_STYLE_NC}"

                      ${lib.concatMapStringsSep "\n" (
                        hostSecret:
                        let
                          masterSecret = alloy.vars.secrets.${hostSecret.source};
                        in
                        ''
                          rekey_host_secret_${hostSecret.id}() {
                            local master_file="$ALLOY_CLI_ROOT/${masterSecret.ageFile}"
                            local host_file="$ALLOY_CLI_ROOT/${hostSecret.ageFile}"

                            if [ "$ALLOY_CLI_FLAG_FORCE" -eq 0 ] && [ -f "$host_file" ]; then
                              alloy_cli_echo_skip "Secret ''${ALLOY_CLI_STYLE_BOLD}${hostSecret.id}''${ALLOY_CLI_STYLE_NC} (already exists)"
                              return 0
                            fi

                            if [ ! -f "$master_file" ]; then
                              alloy_cli_echo_err "Master file for secret '${masterSecret.id}' does not exist: $(alloy_cli_format_path "$master_file")"
                              return 1
                            fi

                            mkdir -p "$(dirname "$host_file")"

                            if ! decrypt "$master_file" | rage -e ${
                              lib.concatMapStringsSep " " (
                                i:
                                "${
                                  if builtins.isPath i.pubkey || lib.hasPrefix "/" i.pubkey then "-R" else "-r"
                                } ${lib.escapeShellArg i.pubkey}"
                              ) host.workspace.vars.secrets.identities
                            } -o "$host_file"; then
                              alloy_cli_echo_err "Failed to rekey '${hostSecret.id}' for host '${host.id}'"
                              return 1
                            fi

                            if [ "$ALLOY_CLI_FLAG_ADD_TO_GIT" -eq 1 ]; then
                              git -C "$ALLOY_CLI_ROOT" add "$host_file" || true
                            fi
                            
                            alloy_cli_echo_ok "Rekeyed ''${ALLOY_CLI_STYLE_BOLD}${hostSecret.id}''${ALLOY_CLI_STYLE_NC} -> $(alloy_cli_format_path "$host_file")"
                          }

                          is_secret_selected=0
                          for resolved_secret in "''${RESOLVE_SECRETS__IDS[@]}"; do
                            :
                            if [ "$resolved_secret" = "${masterSecret.id}" ]; then
                              is_secret_selected=1
                              break;
                            fi
                          done

                          if [ "$is_secret_selected" -eq 1 ]; then
                            rekey_host_secret_${hostSecret.id}
                          fi
                        ''
                      ) (builtins.attrValues host.vars.secrets)}

                      ${lib.pipe alloy.jails [
                        builtins.attrValues
                        (lib.filter (jail: jail.host == host.id))
                        (lib.map (jail: ''
                          alloy_cli_echo_step "Rekeying jail: ''${ALLOY_CLI_STYLE_BOLD}${jail.id}''${ALLOY_CLI_STYLE_NC}"

                          ${lib.concatMapStringsSep "\n" (
                            jailSecret:
                            let
                              masterSecret = alloy.vars.secrets.${jailSecret.source};
                            in
                            ''
                              rekey_jail_${jail.id}_secret_${jailSecret.id}() {
                                local master_file="$ALLOY_CLI_ROOT/${masterSecret.ageFile}"
                                local jail_file="$ALLOY_CLI_ROOT/${jailSecret.ageFile}"

                                if [ "$ALLOY_CLI_FLAG_FORCE" -eq 0 ] && [ -f "$jail_file" ]; then
                                  alloy_cli_echo_skip "Secret ''${ALLOY_CLI_STYLE_BOLD}${jailSecret.id}''${ALLOY_CLI_STYLE_NC} (already exists)"
                                  return 0
                                fi

                                if [ ! -f "$master_file" ]; then
                                  alloy_cli_echo_err "Master file for secret '${masterSecret.id}' does not exist: $(alloy_cli_format_path "$master_file")"
                                  return 1
                                fi

                                mkdir -p "$(dirname "$jail_file")"

                                if ! decrypt "$master_file" | rage -e ${
                                  lib.concatMapStringsSep " " (
                                    i:
                                    "${
                                      if builtins.isPath i.pubkey || lib.hasPrefix "/" i.pubkey then "-R" else "-r"
                                    } ${lib.escapeShellArg i.pubkey}"
                                  ) host.workspace.vars.secrets.identities
                                } -o "$jail_file"; then
                                  alloy_cli_echo_err "Failed to rekey '${jailSecret.id}' for jail '${jail.id}'"
                                  return 1
                                fi

                                if [ "$ALLOY_CLI_FLAG_ADD_TO_GIT" -eq 1 ]; then
                                  git -C "$ALLOY_CLI_ROOT" add "$jail_file" || true
                                fi

                                alloy_cli_echo_ok "Rekeyed ''${ALLOY_CLI_STYLE_BOLD}${jailSecret.id}''${ALLOY_CLI_STYLE_NC} -> $(alloy_cli_format_path "$jail_file")"
                              }

                              is_secret_selected=0
                              for resolved_secret in "''${RESOLVE_SECRETS__IDS[@]}"; do
                                :
                                if [ "$resolved_secret" = "${masterSecret.id}" ]; then
                                  is_secret_selected=1
                                  break;
                                fi
                              done

                              if [ "$is_secret_selected" -eq 1 ]; then
                                rekey_jail_${jail.id}_secret_${jailSecret.id}
                              fi
                            ''
                          ) (builtins.attrValues jail.vars.secrets)}
                        ''))
                        (lib.concatStringsSep "\n")
                      ]}
                    }

                    is_host_selected=0
                    ALLOY_CLI_FLAG_HOST_ARRAY=()
                    if [ -n "''${ALLOY_CLI_FLAG_HOST:-}" ]; then
                      # shellcheck disable=SC2034
                      mapfile -d $'\x1f' -t ALLOY_CLI_FLAG_HOST_ARRAY < <(printf %s "$ALLOY_CLI_FLAG_HOST")
                    fi

                    if [ ''${#ALLOY_CLI_FLAG_HOST_ARRAY[@]} -eq 0 ]; then
                      is_host_selected=1
                    else
                      for req_host in "''${ALLOY_CLI_FLAG_HOST_ARRAY[@]}"; do
                        :
                        if [ "$req_host" = "${host.id}" ]; then
                          is_host_selected=1
                          break
                        fi
                      done
                    fi

                    if [ "$is_host_selected" -eq 1 ]; then
                      rekey_host_${host.id}
                    fi
                  ''))
                  (lib.concatStringsSep "\n")
                ]}
              '';
            };
        };
      };
  };
}
