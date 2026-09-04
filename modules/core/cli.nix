# TODO: forbid declaration of flags with name help or h
{
  lib,
  alib,
  ...
}:
let
  flagSubmodule = { name, ... }: {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        default = name;
      };
      description = lib.mkOption {
        type = lib.types.str;
        default = "No description provided";
      };
      short = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "^[a-zA-Z0-9]$");
        default = null;
      };
      type = lib.mkOption {
        type = lib.types.enum [
          "boolean"
          "string"
          "array"
        ];
        default = "boolean";
      };
      default = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
    };
  };
  commandSubmodule =
    topCommand:
    { config, ... }:
    {
      options = {
        description = lib.mkOption {
          default = "No description provided";
          type = lib.types.str;
        };
        flags = lib.mkOption {
          default = { };
          description = "Flags for this command";
          type = lib.types.attrsOf (lib.types.submodule flagSubmodule);
        };
        path = lib.mkOption {
          readOnly = true;
          type = lib.types.listOf lib.types.str;
        };
        name = lib.mkOption {
          readOnly = true;
          type = lib.types.str;
        };
        commands = lib.mkOption {
          default = { };
          type = lib.types.attrsOf (lib.types.submodule (commandSubmodule config));
        };
        argsUsage = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "Description of positional arguments (e.g. '[SECRETS...]') to append to the Usage line.";
        };
        run = lib.mkOption {
          type = lib.types.functionTo lib.types.package;
          default = { pkgs, ... }: "";
          description = "Function taking { pkgs } and returning a script derivation. Only used if `commands` is empty.";
        };
        script = lib.mkOption {
          readOnly = true;
          type = lib.types.functionTo lib.types.package;
          description = "Function taking { pkgs } and returning a script derivation.";
        };
      };
      config = {
        path = lib.optionals (topCommand != null) (
          topCommand.path ++ [ config._module.args.name ]
        );

        name = "alloy-cli-${lib.concatStringsSep "-" config.path}";

        script =
          {
            pkgs,
          }:
          let
            hasCommands = config.commands != { };

            flagsList = lib.attrValues config.flags;

            shortOpts = lib.concatStringsSep "" (
              [ "h" ]
              ++ (lib.map (f: f.short + (if f.type != "boolean" then ":" else "")) (
                lib.filter (f: f.short != null) flagsList
              ))
            );

            longOpts = lib.concatStringsSep "," (
              [ "help" ] ++ (lib.map (f: f.name + (if f.type != "boolean" then ":" else "")) flagsList)
            );

            bashVarName = n: "ALLOY_CLI_FLAG_" + lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] n);

            defaults = lib.concatStringsSep "\n" (
              lib.map (f: ''
                export ${bashVarName f.name}=${
                  if f.type == "array" then
                    "\"\""
                  else if f.default == null then
                    (if f.type == "boolean" then "0" else "''")
                  else
                    lib.escapeShellArg f.default
                }
              '') flagsList
            );

            parseCases = lib.concatStringsSep "\n" (
              lib.map (f: ''
                ${if f.short != null then "-${f.short}|" else ""}--${f.name})
                  ${
                    if f.type == "boolean" then
                      "${bashVarName f.name}=1\nshift"
                    else if f.type == "array" then
                      ''
                        if [ -z "''$${bashVarName f.name}" ]; then
                          ${bashVarName f.name}="$2"
                        else
                          ${bashVarName f.name}="''$${bashVarName f.name}"$'\x1f'"$2"
                        fi
                        shift 2''
                    else
                      "${bashVarName f.name}=\"$2\"\nshift 2"
                  }
                  ;;
              '') flagsList
            );

            helpTextFlags = lib.concatStringsSep "\n" (
              lib.map (f: ''
                printf "  ''${ALLOY_CLI_STYLE_BOLD}%s''${ALLOY_CLI_STYLE_NC}\t%s\n" "${
                  if f.short != null then "-${f.short}, " else "    "
                }--${f.name}${if f.type != "boolean" then " <val>" else ""}" "${f.description}"
              '') flagsList
            );

            helpTextCommands = lib.mapAttrsToList (name: cmd: ''
              printf "  ''${ALLOY_CLI_STYLE_BOLD}%-15s''${ALLOY_CLI_STYLE_NC} - %s\n" "${name}" "${cmd.description}"
            '') config.commands;

            caseBranches = lib.mapAttrsToList (name: cmd: ''
              ${name})
                ${
                  lib.getExe (
                    cmd.script {
                      inherit pkgs;
                    }
                  )
                } "$@"
                ;;
            '') config.commands;
          in
          pkgs.writeShellApplication {
            name = "${config.name}-script";
            checkPhase = "";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.git
            ];
            text = ''
              export ALLOY_CLI_STYLE_RED='\033[0;31m'
              export ALLOY_CLI_STYLE_GREEN='\033[0;32m'
              export ALLOY_CLI_STYLE_BLUE='\033[0;34m'
              export ALLOY_CLI_STYLE_DIM='\033[2m'
              export ALLOY_CLI_STYLE_BOLD='\033[1m'
              export ALLOY_CLI_STYLE_NC='\033[0m'

              alloy_cli_echo_err() { echo -e "''${ALLOY_CLI_STYLE_RED}error:''${ALLOY_CLI_STYLE_NC} $1" >&2; }
              export -f alloy_cli_echo_err
              alloy_cli_echo_ok() { echo -e "''${ALLOY_CLI_STYLE_GREEN}success:''${ALLOY_CLI_STYLE_NC} $1"; }
              export -f alloy_cli_echo_ok
              alloy_cli_echo_skip() { echo -e "''${ALLOY_CLI_STYLE_DIM}skip:''${ALLOY_CLI_STYLE_NC} $1"; }
              export -f alloy_cli_echo_skip
              alloy_cli_echo_step() { echo -e "''${ALLOY_CLI_STYLE_BOLD}==>''${ALLOY_CLI_STYLE_NC} $1"; }
              export -f alloy_cli_echo_step
              alloy_cli_format_path() { echo -e "''${ALLOY_CLI_STYLE_BLUE}$1''${ALLOY_CLI_STYLE_NC}"; }
              export -f alloy_cli_format_path

              if [ -z "''${ALLOY_CLI_ROOT:-}" ]; then
                ALLOY_CLI_GIT_TOPLEVEL=$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || echo "")

                ALLOY_CLI_ROOT=$(${pkgs.coreutils}/bin/realpath -e "$(pwd)") \
                  || { alloy_cli_echo_err "Could not determine current working directory. Something went very wrong."; exit 1; }
                export ALLOY_CLI_ROOT

                while [[ ! -e "$ALLOY_CLI_ROOT/flake.nix" ]] && [[ "$ALLOY_CLI_ROOT" != "$ALLOY_CLI_GIT_TOPLEVEL" ]] && [[ "$ALLOY_CLI_ROOT" != "/" ]]; do
                  ALLOY_CLI_ROOT="$(dirname "$ALLOY_CLI_ROOT")"
                done

                if [[ ! -e "$ALLOY_CLI_ROOT/flake.nix" ]]; then
                  if [[ -n "$ALLOY_CLI_GIT_TOPLEVEL" ]]; then
                    ALLOY_CLI_ROOT="$ALLOY_CLI_GIT_TOPLEVEL"
                  else
                    alloy_cli_echo_err "Could not determine workspace root. No flake.nix or git repository found."
                    exit 1
                  fi
                fi
              fi

              cd "$ALLOY_CLI_ROOT"

              alloy_cli_show_help() {
                echo -e "''${ALLOY_CLI_STYLE_BOLD}Usage:''${ALLOY_CLI_STYLE_NC} alloy ${lib.concatStringsSep " " config.path} [options] ${
                  if hasCommands then "<subcommand>" else ""
                }${if config.argsUsage != "" then " ${config.argsUsage}" else ""}"
                echo ""
                echo "  ${config.description}"
                echo ""
                echo -e "''${ALLOY_CLI_STYLE_BOLD}Options:''${ALLOY_CLI_STYLE_NC}"
                printf "  ''${ALLOY_CLI_STYLE_BOLD}%s''${ALLOY_CLI_STYLE_NC}\t%s\n" "-h, --help" "Show help"
                ${helpTextFlags}
                echo ""
                echo -e "''${ALLOY_CLI_STYLE_BOLD}Environment:''${ALLOY_CLI_STYLE_NC}"
                printf "  ''${ALLOY_CLI_STYLE_BOLD}%s''${ALLOY_CLI_STYLE_NC}\t%s\n" "ALLOY_CLI_ROOT" "Path to the root directory of the alloy workspace (defaults to auto-discovery)"
                echo ""
                ${lib.optionalString hasCommands ''
                  echo -e "''${ALLOY_CLI_STYLE_BOLD}Available subcommands:''${ALLOY_CLI_STYLE_NC}"
                  ${lib.concatStringsSep "\n" helpTextCommands}
                ''}
              }

              ${defaults}

              # Parse options using getopt

              # PARSED=$(${pkgs.util-linux}/bin/getopt -n "alloy ${lib.escapeShellArg (lib.concatStringsSep " " config.path)}" -o "+${shortOpts}" --long "${longOpts}" -- "$@")
              # if [ $? -ne 0 ]; then
              if ! PARSED=$(${pkgs.util-linux}/bin/getopt -n "alloy ${lib.escapeShellArg (lib.concatStringsSep " " config.path)}" -o "+${shortOpts}" --long "${longOpts}" -- "$@"); then
                alloy_cli_show_help
                exit 1
              fi
              eval set -- "$PARSED"

              while true; do
                case "$1" in
                  -h|--help)
                    alloy_cli_show_help
                    exit 0
                    ;;
                  ${parseCases}
                  --)
                    shift
                    break
                    ;;
                  *)
                    echo "Programming error in option parsing"
                    exit 3
                    ;;
                esac
              done

              ${
                if hasCommands then
                  ''
                    if [ $# -eq 0 ]; then
                      alloy_cli_show_help
                      exit 1
                    fi

                    SUBCOMMAND=$1
                    shift || true

                    case "$SUBCOMMAND" in
                      ${lib.concatStringsSep "\n" caseBranches}
                      *)
                        alloy_cli_echo_err "Unknown command: $SUBCOMMAND"
                        alloy_cli_show_help
                        exit 1
                        ;;
                    esac
                  ''
                else
                  ''
                    ${lib.getExe (config.run { inherit pkgs; })} "$@"
                  ''
              }
            '';
          };
      };
    };
in
{
  options.cli = lib.mkOption {
    description = "Root CLI command for alloy";
    type = lib.types.submodule (commandSubmodule null);
    default = { };
  };

  config.cli.description = "manage alloy";
}
