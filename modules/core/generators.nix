{
  alib,
  lib,
  config,
  ...
}:
let
  alloy = config;

  factType = lib.types.submodule {
    options = {
      type = lib.mkOption {
        type = lib.types.unspecified;
        default = lib.types.unspecified;
      };
    };
  };

  secretType = lib.types.submodule { };

  generatorCore = { config, name, ... }: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      description = lib.mkOption {
        default = "";
        type = lib.types.str;
      };
      wants = lib.mkOption {
        default = [ ];
        type = lib.types.listOf lib.types.str;
      };
      wantedBy = lib.mkOption {
        default = [ ];
        type = lib.types.listOf lib.types.str;
      };
      before = lib.mkOption {
        default = [ ];
        type = lib.types.listOf lib.types.str;
      };
      after = lib.mkOption {
        default = [ ];
        type = lib.types.listOf lib.types.str;
      };
      tags = lib.mkOption {
        default = [ ];
        type = lib.types.listOf lib.types.str;
      };
      libraries = lib.mkOption {
        example = { pkgs, ... }: [ pkgs.python3packages.rich ];
        default = { ... }: [ ];
        type = lib.types.functionTo (lib.types.listOf lib.types.package);
      };
      packages = lib.mkOption {
        example = { pkgs, ... }: [ pkgs.wireguard-tools ];
        default = { ... }: [ ];
        type = lib.types.functionTo (lib.types.listOf lib.types.package);
      };
      facts = lib.mkOption {
        default = { };
        type = lib.types.attrsOf factType;
      };
      secrets = lib.mkOption {
        default = { };
        type = lib.types.attrsOf secretType;
      };
      script = lib.mkOption {
        default = "";
        type = lib.types.str;
      };
      assertions = lib.mkOption {
        default = [ ];
        type = lib.types.listOf alib.types.assertion;
      };
    };
  };
in
{
  options.generators = {
    templates = lib.mkOption {
      default = { };
      type = lib.types.lazyAttrsOf lib.types.deferredModule;
    };

    instances = lib.mkOption {
      default = { };
      type = lib.types.attrsOf (
        lib.types.submoduleWith {
          modules = [
            generatorCore
          ];
        }
      );
    };
  };

  config = {
    assertions = lib.flatten (lib.mapAttrsToList (name: g: g.assertions) alloy.generators.instances);

    facts = lib.mkMerge (lib.mapAttrsToList (_: g:
      lib.mapAttrs (name: f: {
        inherit (f) type;
        file = lib.mkDefault "${alloy.workspace.facts.baseDir}/${name}.json";
      }) g.facts
    ) alloy.generators.instances);

    secrets = lib.mkMerge (lib.mapAttrsToList (_: g:
      lib.mapAttrs (name: _: {
        file = lib.mkDefault "${alloy.workspace.secrets.baseDir}/${name}.age";
      }) g.secrets
    ) alloy.generators.instances);

    cli.apis."AlloyGeneratorsAPI" = {
      description = "API and metadata for cluster generators";
      script = ''
        import json
        class AlloyGeneratorsAPI:
            """
            Metadata for all defined generators.
            """
            db = json.loads(r"""${
              builtins.toJSON (
                lib.mapAttrs (name: g: {
                  inherit (g)
                    enable
                    description
                    wants
                    wantedBy
                    before
                    after
                    tags
                    ;
                }) alloy.generators.instances
              )
            }""")
      '';
    };

    cli.commands.generators = {
      description = "Run configuration and secret generators";
      commands.run = {
        description = "Execute specific generators or tags in topological order";

        flags = {
          "add_to_git" = {
            description = "Stage the modified files in the git index";
            longNames = [ "add-to-git" ];
            shortNames = [ "a" ];
          };
          "force" = {
            description = "Overwrite files if they already exist";
            longNames = [ "force" ];
            shortNames = [ "f" ];
          };
          "tag" = {
            longNames = [ "tag" ];
            shortNames = [ "t" ];
            description = "Run all generators with the specified tag";
            action = "append";
          };
          "instance" = {
            longNames = [ "instance" ];
            shortNames = [ "i" ];
            description = "Run a specific generator instance by name";
            action = "append";
          };
        };

        packages =
          { pkgs, ... }:
          lib.flatten (lib.mapAttrsToList (n: g: g.packages { inherit pkgs; }) alloy.generators.instances);

        libraries =
          { pkgs, ... }:
          lib.flatten (lib.mapAttrsToList (n: g: g.libraries { inherit pkgs; }) alloy.generators.instances);

        script = ''
          import sys
          import graphlib

          enabled_instances = {k: v for k, v in AlloyGeneratorsAPI.db.items() if v["enable"]}

          target_instances = set()
          if getattr(args, "instance", None):
              target_instances.update(args.instance)
          if getattr(args, "tag", None):
              for k, v in enabled_instances.items():
                  if any(t in args.tag for t in v["tags"]):
                      target_instances.add(k)
                      
          if not getattr(args, "instance", None) and not getattr(args, "tag", None):
              target_instances = set(enabled_instances.keys())

          for i in target_instances:
              if i not in enabled_instances:
                  if i in AlloyGeneratorsAPI.db:
                      CLI.abort(f"Generator instance '{CLI.id(i)}' is disabled.")
                  else:
                      CLI.abort(f"Generator instance '{CLI.id(i)}' does not exist.")

          graph = {k: set() for k in enabled_instances.keys()}
          activation_graph = {k: set() for k in enabled_instances.keys()}

          for name, info in enabled_instances.items():
              for dep in info["wants"]:
                  if dep in enabled_instances:
                      graph[name].add(dep)
                      activation_graph[name].add(dep)
              
              for dep in info["after"]:
                  if dep in enabled_instances:
                      graph[name].add(dep)
                      
              for dep in info["wantedBy"]:
                  if dep in enabled_instances:
                      graph[dep].add(name)
                      activation_graph[dep].add(name)
                      
              for dep in info["before"]:
                  if dep in enabled_instances:
                      graph[dep].add(name)

          def activate_deps(p):
              for dep in activation_graph[p]:
                  if dep not in target_instances:
                      target_instances.add(dep)
                      activate_deps(dep)

          for p in list(target_instances):
              activate_deps(p)

          ts = graphlib.TopologicalSorter()
          for node, deps in graph.items():
              if node in target_instances:
                  ts.add(node, *[d for d in deps if d in target_instances])

          try:
              run_order = list(ts.static_order())
          except graphlib.CycleError as e:
              CLI.abort(f"Circular dependency detected in generators: {e}")

          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (name: g: ''
              def run_generator_${builtins.hashString "sha256" name}(args):
              ${
                if g.script == "" then
                  "    pass"
                else
                  lib.concatMapStringsSep "\n" (line: "    " + line) (lib.splitString "\n" g.script)
              }
            '') alloy.generators.instances
          )}

          runners = {
          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (name: g: ''
              "${name}": run_generator_${builtins.hashString "sha256" name},
            '') alloy.generators.instances
          )}
          }

          if not run_order:
              CLI.skip("No generator instances to run.")
              sys.exit(0)

          for i in run_order:
              CLI.step(f"Running generator '{CLI.id(i)}'...")
              runners[i](args)
              
          CLI.ok("All targeted generators completed successfully!")
        '';
      };
    };
  };
}
