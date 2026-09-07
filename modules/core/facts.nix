{
  alib,
  lib,
  config,
  ...
}:
let
  alloy = config;

  factSubmodule = { name, config, ... }: {
    options = {
      file = lib.mkOption {
        type = lib.types.str;
      };
      type = lib.mkOption {
        type = lib.types.unspecified;
      };
      value = lib.mkOption {
        description = "The parsed and validated JSON value of the fact";
        readOnly = true;
      };
      assertions = lib.mkOption {
        type = lib.types.listOf alib.types.assertion;
        default = [ ];
      };
    };

    config = {
      file = lib.mkOptionDefault "${alloy.workspace.facts.baseDir}/${name}.json";
      type = lib.mkOptionDefault lib.types.unspecified;

      assertions = [ ];

      value =
        let
          factPath = alloy.workspace.root + "/${config.file}";
        in
        if builtins.pathExists factPath then
          let
            parsed = builtins.fromJSON (builtins.readFile factPath);
          in
          if config.type != lib.types.unspecified && !(config.type.check parsed) then
            throw ''
              Alloy: Fact '${name}' from file ${factPath} has invalid type. 
              Expected: ${config.type.description or "unknown"}.
            ''
          else
            parsed
        else
          throw ''
            Alloy: Fact file for '${name}' not found at ${factPath}. 
            To fix this, ensure the file is created (e.g. via 'alloy generators run' or 'alloy facts set ${name}').
          '';
    };
  };
in
{
  options.facts = lib.mkOption {
    default = { };
    type = lib.types.attrsOf (lib.types.submodule factSubmodule);
  };

  options.workspace.facts = {
    baseDir = lib.mkOption {
      type = lib.types.str;
      default = "facts";
    };
  };

  config = {
    assertions = lib.flatten (lib.mapAttrsToList (name: f: f.assertions) alloy.facts);

    cli.apis."AlloyFactsAPI" = {
      description = "API for managing Alloy facts";
      script = ''
        class AlloyFactsAPI:
            """
            API for managing Alloy configuration facts.
            """
            db = ${
              builtins.toJSON (
                builtins.listToAttrs (
                  lib.mapAttrsToList (name: fact: lib.nameValuePair name { file = fact.file; }) alloy.facts
                )
              )
            }

            @classmethod
            def get_file(cls, name: str) -> Path:
                data = cls.db.get(name)
                if not data:
                    CLI.abort(f"Fact '{CLI.id(name)}' is not defined in the configuration.")
                return CLI.root / data["file"]
                
            @classmethod
            def set(cls, name: str, data: str, force: bool = False, add_to_git: bool = False) -> Path:
                """
                Validates JSON and saves the fact data.
                """
                import json
                fact_file = cls.get_file(name)
                if fact_file.exists() and not force:
                    CLI.skip(f"Fact '{CLI.id(name)}' already exists. Use --force to overwrite.")
                    sys.exit(0)
                    
                try:
                    json.loads(data)
                except json.JSONDecodeError as e:
                    CLI.abort(f"Invalid JSON data: {e}. The fact file was NOT saved.")
                    
                CLI.step(f"Saving fact '{CLI.id(name)}'...")
                fact_file.parent.mkdir(parents=True, exist_ok=True)
                fact_file.write_text(data)
                
                if add_to_git:
                    CLI.step("Adding file to git index...")
                    CLI.run("git", "add", fact_file)
                    
                return fact_file

            @classmethod
            def get_raw(cls, name: str) -> str:
                """
                Returns the raw string data of the fact.
                """
                fact_file = cls.get_file(name)
                if not fact_file.is_file():
                    CLI.abort(f"Fact file {CLI.path(fact_file)} does not exist.")
                return fact_file.read_text()
                
            @classmethod
            def get(cls, name: str) -> dict:
                """
                Returns the parsed JSON data of the fact.
                """
                import json
                return json.loads(cls.get_raw(name))
      '';
    };

    cli.commands =
      let
        commonFlags = {
          addToGit = {
            description = "Stage the modified fact file in the git index";
            longNames = [ "add-to-git" ];
            shortNames = [ "a" ];
          };
          force = {
            description = "Overwrite the fact file if it already exists";
            longNames = [ "force" ];
            shortNames = [ "f" ];
          };
        };
      in
      {
        facts = {
          description = "Manage plaintext configuration facts";

          commands.set = {
            description = "Set the value of a fact from standard input";
            args = [
              {
                name = "fact";
                description = "The name of the fact to set";
              }
            ];
            flags = {
              "add_to_git" = commonFlags.addToGit;
              "force" = commonFlags.force;
            };
            packages = { pkgs, ... }: [ pkgs.git ];
            script = ''
              import sys

              new_data = sys.stdin.read()
              fact_file = AlloyFactsAPI.set(
                  args.fact, 
                  new_data, 
                  force=getattr(args, "force", False),
                  add_to_git=getattr(args, "add_to_git", False)
              )

              CLI.ok(f"Fact '{CLI.id(args.fact)}' successfully written to {CLI.path(fact_file)}")
            '';
          };

          commands.view = {
            description = "View the value of a fact in standard output";
            args = [
              {
                name = "fact";
                description = "The name of the fact to view";
              }
            ];
            script = ''
              import sys

              sys.stdout.write(AlloyFactsAPI.get_raw(args.fact))
              sys.stdout.flush()
            '';
          };

          commands.edit = {
            description = "Create or edit a fact interactively";
            args = [
              {
                name = "fact";
                description = "The name of the fact to edit";
              }
            ];
            flags = {
              "add_to_git" = commonFlags.addToGit;
            };
            packages = { pkgs, ... }: [
              pkgs.git
              pkgs.nano
            ];
            script = ''
              import sys
              import os
              import shlex
              import hashlib
              import tempfile
              import atexit
              from pathlib import Path

              fact_file = AlloyFactsAPI.get_file(args.fact)

              tmp_dir = "/dev/shm" if Path("/dev/shm").is_dir() else None
              fd, tmp_file_path = tempfile.mkstemp(dir=tmp_dir, text=True)
              os.close(fd)
              tmp_file = Path(tmp_file_path)

              atexit.register(lambda: tmp_file.unlink(missing_ok=True))

              def get_hash(p: Path) -> str:
                  return hashlib.sha256(p.read_bytes()).hexdigest() if p.exists() else ""

              if fact_file.exists():
                  tmp_file.write_text(AlloyFactsAPI.get_raw(args.fact))
              else:
                  CLI.step(f"Creating new fact '{CLI.id(args.fact)}'...")

              before_hash = get_hash(tmp_file)

              editor_env = os.environ.get("EDITOR", "nano")
              editor_cmd = shlex.split(editor_env)
              editor_name = Path(editor_cmd[0]).name

              if editor_name in ["vim", "nvim", "vi"]:
                  editor_cmd.extend(["-n", "-c", "set nobackup noundofile"])

              editor_cmd.append(str(tmp_file))

              CLI.run(*editor_cmd)

              after_hash = get_hash(tmp_file)

              if before_hash == after_hash:
                  CLI.skip("No changes made, exiting.")
                  sys.exit(0)

              if not tmp_file.exists() or tmp_file.stat().st_size == 0:
                  CLI.abort("The file is empty. Aborting operation.")

              AlloyFactsAPI.set(
                  args.fact, 
                  tmp_file.read_text(), 
                  force=True,
                  add_to_git=getattr(args, "add_to_git", False)
              )

              CLI.ok(f"Fact '{CLI.id(args.fact)}' saved successfully.")
            '';
          };
        };
      };
  };
}
