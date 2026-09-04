{
  alib,
  lib,
  config,
  ...
}:
let
  alloy = config;
in
{
  options =
    let
      factModule = { config, name, ... }: {
        options = {
          id = alib.mkIdOpt name "";
          file = lib.mkOption {
            type = lib.types.str;
            default = "${alloy.workspace.vars.facts.baseDir}/${config.id}.json";
            apply = v: "${v}";
          };
          type = lib.mkOption {
            type = lib.types.unspecified;
          };
          exists = lib.mkOption {
            type = lib.types.bool;
            readOnly = true;
          };
          value = lib.mkOption {
            type = config.type;
          };
        };
        config = {
          exists = builtins.pathExists (alloy.workspace.root + "/${config.file}");
          value =
            if config.exists then
              builtins.fromJSON (builtins.readFile (alloy.workspace.root + "/${config.file}"))
            else
              throw "alloy: fact '${config.id}' not found, expected file at '${alloy.workspace.root}/${config.file}', maybe you did not add the file to git";
        };
      };
    in
    {
      workspace.vars.facts = {
        baseDir = lib.mkOption {
          default = "vars/facts";
          type = lib.types.str;
        };
      };

      vars.facts = alib.extend factModule;
    };

  config = {
    cli.commands.vars.commands.facts =
      let
        baseCmds = ''
          resolve_fact_file() {
            ${lib.concatMapStringsSep "\n" (fact: ''
              if [ "${fact.id}" = "$1" ]; then
                echo ${lib.escapeShellArg fact.file}
                return 0
              fi
            '') (builtins.attrValues alloy.vars.facts)}
            return 1
          }
        '';
      in
      {
        description = "manage alloy facts";

        commands.edit = { config, ... }: {
          description = "Create or edit a fact value interactively";
          argsUsage = "<FACT_ID>";
          flags = {
            add-to-git = {
              description = "Add edited fact to git via git add";
              short = "a";
            };
          };
          run =
            {
              pkgs,
              ...
            }:
            pkgs.writeShellApplication {
              name = config.name;
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
                  alloy_cli_echo_err "Fact ID is required."
                  alloy_cli_show_help
                  exit 1
                fi
                if [ "$#" -gt 1 ]; then
                  alloy_cli_echo_err "Unexpected argument: $2"
                  alloy_cli_show_help
                  exit 1
                fi

                fact_file=$(resolve_fact_file "$1" || true)

                if [ "$fact_file" = "" ]; then
                  alloy_cli_echo_err "Fact '$1' not found in configuration"
                  exit 1
                fi

                TARGET_FILE="$ALLOY_CLI_ROOT/$fact_file"
                if [ -d "/dev/shm" ]; then
                  export TMPDIR="/dev/shm"
                fi
                TMP_FILE=$(mktemp)
                trap 'rm -f "$TMP_FILE"' EXIT

                if [ -f "$TARGET_FILE" ]; then
                  cat "$TARGET_FILE" > "$TMP_FILE"
                  BEFORE_HASH=$(sha256sum "$TMP_FILE" | cut -d' ' -f1)
                else
                  alloy_cli_echo_step "Creating new fact: ''${ALLOY_CLI_STYLE_BOLD}$1''${ALLOY_CLI_STYLE_NC}"
                  BEFORE_HASH=""
                fi

                ''${EDITOR:-nano} "$TMP_FILE"

                AFTER_HASH=$(sha256sum "$TMP_FILE" | cut -d' ' -f1)

                if [ "$BEFORE_HASH" = "$AFTER_HASH" ]; then
                  alloy_cli_echo_skip "No changes made, exiting."
                  exit 0
                fi

                if [ ! -s "$TMP_FILE" ]; then
                  alloy_cli_echo_err "File is empty, aborting file saving."
                  exit 1
                fi

                alloy_cli_echo_step "Saving to $(alloy_cli_format_path "$TARGET_FILE")..."
                mkdir -p "$(dirname "$TARGET_FILE")"
                cat "$TMP_FILE" > "$TARGET_FILE"

                if [ "$ALLOY_CLI_FLAG_ADD_TO_GIT" -eq 1 ]; then
                  alloy_cli_echo_step "Adding to git index..."
                  git -C "$ALLOY_CLI_ROOT" add "$TARGET_FILE" || true
                fi

                alloy_cli_echo_ok "Fact '$1' saved successfully."
              '';
            };
        };

        commands.set = { config, ... }: {
          description = "Set a fact value from stdin";
          argsUsage = "<FACT_ID>";
          flags = {
            add-to-git = {
              description = "Add edited fact to git via git add";
              short = "a";
            };
            force = {
              description = "Force overwriting even if the fact already exists";
              short = "f";
            };
          };
          run =
            {
              pkgs,
              ...
            }:
            pkgs.writeShellApplication {
              name = config.name;
              checkPhase = "";
              runtimeInputs = [
                pkgs.coreutils
                pkgs.git
              ];
              text = ''
                ${baseCmds}

                if [ -z "$1" ]; then
                  alloy_cli_echo_err "Fact ID is required."
                  alloy_cli_show_help
                  exit 1
                fi
                if [ "$#" -gt 1 ]; then
                  alloy_cli_echo_err "Unexpected argument: $2"
                  alloy_cli_show_help
                  exit 1
                fi

                fact_file=$(resolve_fact_file "$1" || true)

                if [ "$fact_file" = "" ]; then
                  alloy_cli_echo_err "Fact '$1' not found in configuration"
                  exit 1
                fi

                TARGET_FILE="$ALLOY_CLI_ROOT/$fact_file"

                if [ "$ALLOY_CLI_FLAG_FORCE" -eq 0 ] && [ -f "$TARGET_FILE" ]; then
                  alloy_cli_echo_skip "Fact ''${ALLOY_CLI_STYLE_BOLD}$1''${ALLOY_CLI_STYLE_NC} already exists."
                  exit 0
                fi

                alloy_cli_echo_step "Reading from stdin and saving to '$(alloy_cli_format_path "$TARGET_FILE")'..."

                mkdir -p "$(dirname "$TARGET_FILE")"
                if ! cat /dev/stdin > "$TARGET_FILE"; then
                  alloy_cli_echo_err "Failed to write fact"
                  exit 1
                fi

                if [ "$ALLOY_CLI_FLAG_ADD_TO_GIT" -eq 1 ]; then
                  alloy_cli_echo_step "Adding to git index..."
                  git -C "$ALLOY_CLI_ROOT" add "$fact_file" || true
                fi

                alloy_cli_echo_ok "Fact '$1' saved successfully."
              '';
            };
        };

        commands.view = { config, ... }: {
          description = "View a fact value in stdout";
          argsUsage = "<FACT_ID>";
          run =
            {
              pkgs,
              ...
            }:
            pkgs.writeShellApplication {
              name = config.name;
              checkPhase = "";
              runtimeInputs = [
                pkgs.coreutils
              ];
              text = ''
                ${baseCmds}

                if [ -z "$1" ]; then
                  alloy_cli_echo_err "Fact ID is required."
                  alloy_cli_show_help
                  exit 1
                fi
                if [ "$#" -gt 1 ]; then
                  alloy_cli_echo_err "Unexpected argument: $2"
                  alloy_cli_show_help
                  exit 1
                fi

                fact_file=$(resolve_fact_file "$1" || true)

                if [ "$fact_file" = "" ]; then
                  alloy_cli_echo_err "Fact '$1' not found in configuration"
                  exit 1
                fi

                TARGET_FILE="$ALLOY_CLI_ROOT/$fact_file"

                if [ ! -f "$TARGET_FILE" ]; then
                  alloy_cli_echo_err "File $(alloy_cli_format_path "$TARGET_FILE") does not exist"
                  exit 1
                fi

                cat "$TARGET_FILE"
              '';
            };
        };
      };
  };
}
