{
  lib,
  config,
  alloy-internal-inputs,
  ...
}:
let
  alloy = config;

  argType = lib.types.submodule (
    { ... }: {
      options = {
        name = lib.mkOption {
          type = lib.types.str;
        };
        description = lib.mkOption {
          type = lib.types.str;
          default = "";
        };
        metavar = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        type = lib.mkOption {
          default = "str";
          type = lib.types.enum [
            "str"
            "int"
            "float"
          ];
        };
      };
    }
  );

  flagType = lib.types.submodule (
    { name, ... }: {
      options = {
        longNames = lib.mkOption {
          default = [ name ];
          type = lib.types.listOf lib.types.str;
        };
        shortNames = lib.mkOption {
          default = [ ];
          type = lib.types.listOf lib.types.str;
        };
        description = lib.mkOption {
          type = lib.types.str;
          default = "";
        };
        metavar = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        required = lib.mkOption {
          type = lib.types.bool;
          default = false;
        };
        action = lib.mkOption {
          default = "store_true";
          type = lib.types.enum [
            "store_true"
            "store_false"
            "store"
            "append"
            "count"
          ];
        };
      };
    }
  );

  apiSubmodule = { name, ... }: {
    options = {
      description = lib.mkOption {
        type = lib.types.str;
        default = "";
      };
      libraries = lib.mkOption {
        description = "Libraries";
        example = { pkgs, ... }: [ pkgs.python3packages.rich ];
        default = { ... }: [ ];
        type = lib.types.functionTo (lib.types.listOf lib.types.package);
      };
      packages = lib.mkOption {
        description = "Packages available in PATH during script execution";
        example = { pkgs, ... }: [ pkgs.wireguard-tools ];
        default = { ... }: [ ];
        type = lib.types.functionTo (lib.types.listOf lib.types.package);
      };
      script = lib.mkOption {
        default = "";
        type = lib.types.str;
      };
    };
  };

  commandSubmodule = { name, ... }: {
    options = {
      description = lib.mkOption {
        default = "";
        type = lib.types.str;
      };
      flags = lib.mkOption {
        default = { };
        type = lib.types.attrsOf flagType;
      };
      args = lib.mkOption {
        default = [ ];
        type = lib.types.listOf argType;
      };
      libraries = lib.mkOption {
        description = "Libraries";
        example = { pkgs, ... }: [ pkgs.python3packages.rich ];
        default = { ... }: [ ];
        type = lib.types.functionTo (lib.types.listOf lib.types.package);
      };
      packages = lib.mkOption {
        description = "Packages available in PATH during script execution";
        example = { pkgs, ... }: [ pkgs.wireguard-tools ];
        default = { ... }: [ ];
        type = lib.types.functionTo (lib.types.listOf lib.types.package);
      };
      script = lib.mkOption {
        default = "";
        type = lib.types.str;
      };
      commands = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule commandSubmodule);
      };
      assertions = lib.mkOption {
        type = lib.types.listOf lib.types.unspecified;
        default = [ ];
      };
    };
    config = {
      assertions = [
        {
          assertion = builtins.match "^[a-zA-Z0-9-]+$" name != null;
          message = ''
            [Alloy] Invalid CLI command name '${name}'

            Command names must only contain alphanumeric characters and hyphens [a-zA-Z0-9-].
          '';
        }
      ];
    };
  };

in
{
  options.cli = {
    apis = lib.mkOption {
      default = { };
      description = "Dictionary of Python APIs to inject into the CLI script.";
      type = lib.types.attrsOf (lib.types.submodule apiSubmodule);
    };

    commands = lib.mkOption {
      default = { };
      description = "Recursive dictionary of CLI command definitions.";
      type = lib.types.attrsOf (lib.types.submodule commandSubmodule);
    };

    package = lib.mkOption {
      readOnly = true;
      description = "The final compiled CLI package (requires pkgs).";
      type = lib.types.functionTo lib.types.package;
    };
  };

  config =
    let
      collectPackages = pkgs: cmds:
        lib.flatten (
          lib.mapAttrsToList (_: cmd: 
            (cmd.packages { inherit pkgs; }) ++ (collectPackages pkgs cmd.commands)
          ) cmds
        );

      collectLibraries = pkgs: cmds:
        lib.flatten (
          lib.mapAttrsToList (_: cmd: 
            (cmd.libraries { inherit pkgs; }) ++ (collectLibraries pkgs cmd.commands)
          ) cmds
        );

      collectAssertions = cmds:
        lib.flatten (
          lib.mapAttrsToList (_: cmd: 
            cmd.assertions ++ (collectAssertions cmd.commands)
          ) cmds
        );

      allPackages =
        pkgs:
        lib.flatten (
          [ ]
          ++ (collectPackages pkgs alloy.cli.commands)
          ++ (lib.mapAttrsToList (_: api: api.packages { inherit pkgs; }) alloy.cli.apis)
        );

      allLibraries =
        pkgs:
        lib.flatten (
          [ ]
          ++ (collectLibraries pkgs alloy.cli.commands)
          ++ (lib.mapAttrsToList (_: api: api.libraries { inherit pkgs; }) alloy.cli.apis)
        );

      script = pkgs: ''
        import argparse
        import sys
        import os
        import subprocess
        from pathlib import Path
        from typing import Union
        from rich.console import Console

        os.environ["PATH"] = "${lib.makeBinPath (allPackages pkgs)}:" + os.environ.get("PATH", "")

        class CLI:
            root: Path = None

            _console = Console()
            _err_console = Console(stderr=True)

            @classmethod
            def init(cls):
                root_env = os.environ.get("ALLOY_CLI_ROOT")

                if root_env:
                    cls.root = Path(root_env).resolve()
                else:
                    _current = Path.cwd().resolve()
                    while True:
                        if (_current / "flake.nix").exists() or (_current / ".git").exists():
                            cls.root = _current
                            break
                        if _current.parent == _current:
                            break
                        _current = _current.parent

                    if not cls.root:
                        cls.abort("Could not determine workspace root. No flake.nix or .git repository found.")

                os.environ["ALLOY_CLI_ROOT"] = str(cls.root)
                os.chdir(cls.root)

            @classmethod
            def step(cls, msg: str):
                cls._console.print(f"[bold]==>[/bold] {msg}")

            @classmethod
            def ok(cls, msg: str):
                cls._console.print(f"[bold green]success:[/bold green] {msg}")

            @classmethod
            def skip(cls, msg: str):
                cls._console.print(f"[dim]skip:[/dim] {msg}")

            @classmethod
            def info(cls, msg: str):
                cls._console.print(f"[dim cyan]info:[/dim cyan] {msg}")

            @classmethod
            def error(cls, msg: str):
                cls._err_console.print(f"[bold red]error:[/bold red] {msg}")

            @classmethod
            def abort(cls, msg: str, code: int = 1):
                cls.error(msg)
                sys.exit(code)

            @staticmethod
            def id(name: str) -> str:
                return f"[bold cyan]{name}[/bold cyan]"

            @staticmethod
            def path(p: Union[Path, str]) -> str:
                p_obj = Path(p)
                if p_obj.parent.name == "":
                    return f"[bold blue]{p_obj.name}[/bold blue]"
                return f"[dim blue]{p_obj.parent.as_posix()}/[/dim blue][bold blue]{p_obj.name}[/bold blue]"

            @classmethod
            def run(cls, *cmd, capture: bool = False, check: bool = True):
                cmd_args = [str(c) for c in cmd]
                try:
                    return subprocess.run(
                        cmd_args,
                        capture_output=capture,
                        text=True,
                        check=check
                    )
                except subprocess.CalledProcessError as e:
                    if capture and (e.stderr or e.stdout):
                        cls.error(e.stderr.strip() or e.stdout.strip())
                    cls.abort(f"Command failed (code {e.returncode}): {' '.join(cmd_args)}")

        CLI.init()

        ${lib.concatStringsSep "\n\n" (lib.mapAttrsToList (_: api: api.script) alloy.cli.apis)}

        parser_ = argparse.ArgumentParser(
            description="Alloy: The statically-typed compile-time cluster orchestrator for NixOS",
            formatter_class=argparse.RawDescriptionHelpFormatter,
            epilog="""
        Environment variables:
          ALLOY_CLI_ROOT    Path to the root directory of the alloy workspace.
                            If not set, it is auto-discovered by searching upwards
                            for a flake.nix or .git directory.
        """
        )

        ${lib.optionalString (alloy.cli.commands != { }) ''
          subparsers_root = parser_.add_subparsers(dest="cmd_root", title="commands", metavar="<command>")

          ${lib.concatMapAttrsStringSep "\n" (childKey: childCmd:
            let
              childPath = [ childKey ];
              childName = lib.concatStringsSep "_" childPath;
              childDesc = childCmd.description or "";
            in
            ''
              parser_${childName} = subparsers_root.add_parser("${childKey}", help="${childDesc}")
              ${handleCommand childPath childCmd}
            ''
          ) alloy.cli.commands}
        ''}

        if __name__ == "__main__":
            args = parser_.parse_args()
            if hasattr(args, '__cli_command_handler__'):
                args.__cli_command_handler__(args)
            else:
                parser_.print_help()
      '';

      indent = spaces: str: lib.replaceStrings [ "\n" ] [ "\n${spaces}" ] str;

      handleCommand =
        path: command:
        let
          name = lib.concatStringsSep "_" path;

          scriptContent = command.script or "";
          argsList = command.args or [ ];
          flagsAttrs = command.flags or { };
        in
        ''
          def run_${name}(args):
              ${indent "    " (if scriptContent == "" then "parser_${name}.print_help()" else scriptContent)}

          parser_${name}.set_defaults(__cli_command_handler__=run_${name})

          ${lib.concatMapStringsSep "\n" (
            arg:
            "parser_${name}.add_argument(${
              lib.concatStringsSep ", " (
                [
                  ''"${arg.name}"''
                  "type=${arg.type}"
                  ''help="${arg.description}"''
                ]
                ++ (lib.optional (arg.metavar != null) ''metavar="${arg.metavar}"'')
              )
            })"
          ) argsList}

          ${lib.concatMapAttrsStringSep "\n" (
            flagName: flag:
            "parser_${name}.add_argument(${
              lib.concatStringsSep ", " (
                [ ]
                ++ (lib.map (n: ''"--${n}"'') flag.longNames)
                ++ (lib.map (n: ''"-${n}"'') flag.shortNames)
                ++ [
                  ''dest="${flagName}"''
                  ''help="${flag.description}"''
                  ''action="${flag.action}"''
                ]
                ++ (lib.optional (flag.required) "required=True")
                ++ (lib.optional (flag.metavar != null) ''metavar="${flag.metavar}"'')
              )
            })"
          ) flagsAttrs}

          ${lib.optionalString (command.commands != { }) ''
            subparsers_${name} = parser_${name}.add_subparsers(dest="cmd_${name}", title="commands", metavar="<command>")

            ${lib.concatMapAttrsStringSep "\n" (
              childKey: childCmd:
              let
                childPath = path ++ [ childKey ];
                childName = lib.concatStringsSep "_" childPath;
                childDesc = childCmd.description or "";
              in
              ''
                parser_${childName} = subparsers_${name}.add_parser("${childKey}", help="${childDesc}")

                ${handleCommand childPath childCmd}
              ''
            ) command.commands}
          ''}
        '';
    in
    {
      cli.package =
        { pkgs, ... }:
        pkgs.writers.writePython3Bin "alloy" {
          libraries = (allLibraries pkgs) ++ [
            pkgs.python3Packages.rich
          ];
          flakeIgnore = [
            "E"
            "F"
            "W"
          ];
        } (script pkgs);

      assertions = collectAssertions alloy.cli.commands;
    };
}
