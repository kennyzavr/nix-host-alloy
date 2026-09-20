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
                  Alloy: Fact file for '${name}' not found at ${config.path}.
                  To fix this, ensure the file is created (e.g. via 'alloy generators run' or 'alloy facts set "${name}"').
                '';

            assertions = [
              {
                assertion = config.exists;
                message = ''
                  [Alloy] Fact '${name}' has no backing file at ${config.path}.

                  To fix this, run one of:
                    alloy generators run    (if this fact is produced by a generator)
                    alloy facts set "${name}" (to set the value manually)
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
          };
          permissions = lib.mkOption {
            type = alib.types.permissions;
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
          };
        };
      };

      config = {
        assertions = lib.flatten (lib.mapAttrsToList (name: f: f.assertions) alloy.facts);

        _internal.state = { ... }: {
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
