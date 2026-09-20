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

      indexSubmodule =
        { name, config, ... }:
        {
          options = {
            factName = lib.mkOption {
              type = lib.types.str;
              default = "indexes/${name}.json";
            };

            keys = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "The list of keys that must be allocated a unique integer in this index.";
            };

            minValue = lib.mkOption {
              type = lib.types.int;
              default = 1;
              description = "Minimum allocatable value (inclusive).";
            };

            maxValue = lib.mkOption {
              type = lib.types.int;
              default = 999;
              description = "Maximum allocatable value (inclusive).";
            };

            values = lib.mkOption {
              type = lib.types.attrsOf lib.types.int;
              readOnly = true;
              description = ''
                The full mapping of key → integer for this index, loaded from the
                backing fact file. Returns {} if the file does not yet exist.
              '';
            };

            get = lib.mkOption {
              type = lib.types.functionTo lib.types.int;
              readOnly = true;
              description = ''
                Look up the allocated integer for a given key.

                Throws a descriptive error if the key is not present in the index
                (e.g. the index file was not regenerated after a new key was added).

                Usage:
                  config.indexes."hosts".get "my-host"
              '';
            };

            assertions = lib.mkOption {
              type = lib.types.listOf alib.types.assertion;
              readOnly = true;
              description = "Assertions verifying the integrity of the stored index data.";
            };
          };

          config = {
            values =
              if alloy.facts.${config.factName}.exists then
                builtins.fromJSON alloy.facts.${config.factName}.value
              else
                # { };
                throw ''
                  Alloy: Index '${name}' has no allocated values.
                  The index file at '${alloy.workspace.facts.baseDir}/${config.factName}' is either
                  missing or out of date.
                  Run: alloy indexes generate --instace "${name}"
                  to regenerate it.
                '';
            get = key: config.values.${key};
            # if config.values ? ${key}
            # then
            #   config.values.${key}
            # else
            # throw ''
            #   Alloy: Index '${name}' has no allocation for key '${key}'.
            #   The index file at '${alloy.workspace.facts.baseDir}/${config.factName}' is either
            #   missing or out of date.
            #   Run: alloy indexes generate --instace "${name}"
            #   to regenerate it.
            # '';

            assertions = lib.optionals alloy.facts.${config.factName}.exists (
              [
                {
                  assertion =
                    lib.length (builtins.attrNames config.values)
                    == lib.length (lib.unique (builtins.attrValues config.values));
                  message = ''
                    [Alloy] Index '${name}': duplicate values detected in the index file.

                    Every key must map to a unique integer. Run:
                      alloy indexes generate --force --instance "${name}"
                    to reallocate and fix collisions.
                  '';
                }
                {
                  assertion = builtins.all (v: v >= config.minValue && v <= config.maxValue) (
                    builtins.attrValues config.values
                  );
                  message = ''
                    [Alloy] Index '${name}': one or more values are outside the
                    allowed range [${toString config.minValue}, ${toString config.maxValue}].

                    Run:
                      alloy indexes generate --force --instance "${name}"
                    to reallocate all values within the valid range.
                  '';
                }
              ]
              ++ (lib.map (key: {
                assertion = builtins.hasAttr key config.values;
                message = ''
                  Alloy: Index '${name}' has no allocation for key '${key}'.
                  The index file at '${alloy.workspace.facts.baseDir}/${config.factName}' is either
                  missing or out of date.
                  Run: alloy indexes generate --instace "${name}"
                  to regenerate it.
                '';
              }) config.keys)
            );
          };
        };
    in
    {
      options.indexes = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule indexSubmodule);
      };

      config = {
        assertions = lib.flatten (lib.mapAttrsToList (_: idx: idx.assertions) alloy.indexes);

        facts = lib.mapAttrs' (_: index: lib.nameValuePair index.factName { }) alloy.indexes;

        _internal.state = { ... }: {
          indexes = lib.mapAttrs (_: index: {
            inherit (index)
              keys
              minValue
              maxValue
              factName
              ;
          }) alloy.indexes;
        };
      };
    };
}
