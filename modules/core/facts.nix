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
        let
          factPath = alloy.workspace.root + "/${config.file}";
        in
        {
          options = {
            file = lib.mkOption {
              type = lib.types.str;
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
            assertions = lib.mkOption {
              type = lib.types.listOf alib.types.assertion;
              default = [ ];
            };
          };

          config = {
            file = lib.mkOptionDefault "${alloy.workspace.facts.baseDir}/${name}";

            exists = builtins.pathExists factPath;

            value =
              if config.exists then
                builtins.readFile factPath
              else
                throw ''
                  Alloy: Fact file for '${name}' not found at ${factPath}.
                  To fix this, ensure the file is created (e.g. via 'alloy generators run' or 'alloy facts set "${name}"').
                '';

            assertions = [
              {
                assertion = config.exists;
                message = ''
                  [Alloy] Fact '${name}' has no backing file at ${factPath}.

                  To fix this, run one of:
                    alloy generators run    (if this fact is produced by a generator)
                    alloy facts set "${name}" (to set the value manually)
                '';
              }
            ];
          };
        };
    in
    {
      options = {
        facts = lib.mkOption {
          default = { };
          type = lib.types.attrsOf (lib.types.submodule factSubmodule);
        };

        workspace.facts = {
          baseDir = lib.mkOption {
            type = lib.types.str;
            default = "facts";
          };
        };
      };

      config = {
        assertions = lib.flatten (lib.mapAttrsToList (name: f: f.assertions) alloy.facts);

        _internal.state = { ... }: {
          facts = lib.mapAttrsToList (factName: fact: {
            name = factName;
            inherit (fact) file;
          }) alloy.facts;
        };
      };
    };
}
