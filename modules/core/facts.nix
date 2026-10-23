{
  flake.alloyModules.core =
    {
      alib,
      lib,
      config,
      ...
    }:
    let
      alloy = config;

      factSubmodule =
        { name, config, ... }:
        {
          options = {
            file = lib.mkOption {
              type = lib.types.str;
              description = "Path to this fact's backing file, relative to the workspace root.";
            };
            path = lib.mkOption {
              readOnly = true;
              type = lib.types.path;
            };
            exists = lib.mkOption {
              description = "Whether the backing file for this fact currently exists on disk.";
              type = lib.types.bool;
              readOnly = true;
            };
            value = lib.mkOption {
              description = "The string value of the fact";
              readOnly = true;
            };
            tags = lib.mkOption {
              default = [ ];
              type = lib.types.listOf lib.types.str;
              description = "Labels used to select or group this fact in CLI operations.";
            };
            assertions = lib.mkOption {
              type = lib.types.listOf alib.types.assertion;
              default = [ ];
            };
          };

          config = {
            path = alloy.workspace.root + "/${config.file}";

            file = lib.mkOptionDefault "${alloy.workspace.facts.baseDir}/${name}";

            exists = builtins.pathExists config.path;

            value =
              if config.exists then
                builtins.readFile config.path
              else
                throw ''
                  [Alloy] Fact '${name}': File not found at ${config.path}.
                  Create it with `alloy-cli gens exec` or edit it with `alloy-cli facts edit "${name}"`.
                '';

            assertions = [
              {
                assertion = config.exists;
                message = ''
                  [Alloy] Fact '${name}': No backing file exists at ${config.path}.
                  Run `alloy-cli gens exec` if a generator produces this fact, or edit it with `alloy-cli facts edit "${name}"`.
                '';
              }
            ];
          };
        };

      nodeFactSubmodule = node: { config, name, ... }: {
        options = {
          path = lib.mkOption {
            type = lib.types.str;
            default = node.factsBasePath + "/${name}";
            description = "Path where this fact is exposed inside the host or jail.";
          };
          permissions = lib.mkOption {
            type = alib.types.permissions;
            description = "Owner, group, and mode used for the exposed fact file.";
          };
        };
        config = {
          permissions = {
            mode = lib.mkDefault "0640";
            owner = lib.mkDefault "root";
            group = lib.mkDefault "root";
          };
        };
      };

      mkNodeFact = factName: fact: {
        nixosModule = {
          environment.etc."alloy-internal/facts/${factName}" = {
            inherit (fact.permissions) mode group;
            user = fact.permissions.owner;
            text = alloy.facts.${factName}.value;
          };

          systemd.tmpfiles.settings."10-alloy-facts".${fact.path}."L+" = {
            user = fact.permissions.owner;
            group = fact.permissions.group;
            mode = fact.permissions.mode;
            argument = "/etc/alloy-internal/facts/${factName}";
          };
        };
      };

      nodeSubmodule = { config, name, ... }: {
        options.facts = lib.mkOption {
          default = { };
          type = lib.types.attrsOf (lib.types.submodule (nodeFactSubmodule config));
        };
        options.factsBasePath = lib.mkOption {
          type = lib.types.str;
          default = "/etc/alloy/facts";
        };

        config.nixosModule = {
          imports = lib.mapAttrsToList (factName: fact: (mkNodeFact factName fact).nixosModule) config.facts;
        };
      };
    in
    {
      options = {
        facts = lib.mkOption {
          default = { };
          type = lib.types.attrsOf (lib.types.submodule factSubmodule);
          description = "Workspace facts available to the Alloy configuration.";
        };

        hosts = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule nodeSubmodule);
        };

        jails = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule nodeSubmodule);
        };

        workspace.facts = {
          baseDir = lib.mkOption {
            type = lib.types.str;
            default = "${alloy.workspace.baseDir}/facts";
            description = "Workspace-relative directory containing fact files.";
          };
        };
      };

      config = {
        assertions = lib.flatten (lib.mapAttrsToList (name: f: f.assertions) alloy.facts);

        build.state = { ... }: {
          facts = lib.mapAttrs (_: fact: {
            inherit (fact) file tags;
          }) alloy.facts;
          hosts = lib.mapAttrs (_: host: {
            facts = lib.mapAttrs (_: fact: { inherit (fact) path; }) host.facts;
          }) alloy.hosts;
        };
      };
    };
}
