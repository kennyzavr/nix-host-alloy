{
  generators.templates."index" =
    { config, lib, ... }:
    let
      indexType =
        min: max:
        lib.mkOptionType {
          name = "index";
          description = "a mapping of strings to unique integers between ${toString min} and ${toString max}";
          check =
            val:
            let
              values = builtins.attrValues val;
            in
            builtins.isAttrs val
            && builtins.all (v: builtins.isInt v && v >= min && v <= max) values
            && lib.length (lib.unique values) == lib.length values;
        };
    in
    {
      options.name = lib.mkOption {
        type = lib.types.str;
        description = "Name of the fact where the index will be stored.";
      };
      options.keys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "List of keys that require an index.";
      };
      options.minValue = lib.mkOption {
        type = lib.types.int;
        default = 1;
      };
      options.maxValue = lib.mkOption {
        type = lib.types.int;
        default = 999;
      };

      config = {
        tags = [
          "index"
        ];

        facts.${config.name} = {
          type = indexType config.minValue config.maxValue;
        };

        script = ''
          import json

          fact_name = "${config.name}"
          keys = ${builtins.toJSON (lib.unique (config.keys))}
          min_val = ${toString config.minValue}
          max_val = ${toString config.maxValue}

          force = getattr(args, "force", False)
          add_to_git = getattr(args, "add_to_git", False)

          CLI.step(f"Generating index '{fact_name}'...")

          existing_state = {}
          fact_file = AlloyFactsAPI.get_file(fact_name)
          if fact_file.is_file():
              try:
                  existing_state = AlloyFactsAPI.get(fact_name)
                  if not isinstance(existing_state, dict):
                      existing_state = {}
              except Exception:
                  pass

          current_state = {k: v for k, v in existing_state.items() if k in keys}

          unallocated_keys = sorted([k for k in keys if k not in current_state])
          needed = len(unallocated_keys)

          used_sorted = sorted([v for v in current_state.values() if min_val <= v <= max_val])

          available_values = []
          candidate = min_val

          for used_val in used_sorted:
              if len(available_values) >= needed:
                  break
              while candidate < used_val and len(available_values) < needed and candidate <= max_val:
                  available_values.append(candidate)
                  candidate += 1
              candidate = max(candidate, used_val + 1)

          while len(available_values) < needed and candidate <= max_val:
              available_values.append(candidate)
              candidate += 1

          if len(available_values) < needed:
              CLI.abort(f"Index allocation failed for '{fact_name}'. Need {needed} new slots, but not enough gaps available in range [{min_val}, {max_val}].")

          for k in unallocated_keys:
              current_state[k] = available_values.pop(0)

          if current_state == existing_state and not force:
              CLI.skip(f"No changes in index '{fact_name}'.")
          else:
              AlloyFactsAPI.set(
                  fact_name,
                  json.dumps(current_state, indent=2, sort_keys=True),
                  force=True,
                  add_to_git=add_to_git
              )
        '';
      };
    };
}
