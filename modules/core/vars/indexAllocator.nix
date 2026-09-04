{ lib, ... }: {
  vars.provisionerSpecs."index-allocator" = { config, ... }: {
    options = {
      minValue = lib.mkOption {
        type = lib.types.ints.positive;
      };
      maxValue = lib.mkOption {
        type = lib.types.ints.positive;
      };
      reuseValues = lib.mkOption {
        default = true;
        type = lib.types.bool;
      };
      keys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
      };
    };

    config = {
      facts.index = {
        file = "index.json";
        type = lib.types.submodule {
          options = {
            items = lib.mkOption {
              default = { };
              type = lib.types.attrsOf lib.types.ints.positive;
              apply =
                items:
                let
                  values = builtins.attrValues items;

                  outOfRange = lib.filter (v: v < config.minValue || v > config.maxValue) values;
                  outOfRangeStr = lib.concatStringsSep ", " (map toString outOfRange);

                  groupedByValue = lib.groupBy toString values;
                  collisions = lib.filterAttrs (_: keys: builtins.length keys > 1) groupedByValue;
                  collisionsStr = lib.concatStringsSep ", " (
                    lib.mapAttrsToList (
                      slot: keys: "value ${slot} (keys: ${lib.concatStringsSep ", " keys})"
                    ) collisions
                  );
                in
                if outOfRange != [ ] then
                  throw "alloy: index-allocator: values out of range [${toString config.minValue}..${toString config.maxValue}]: ${outOfRangeStr}"
                else if collisions != { } then
                  throw "alloy: index-allocator: duplicate values detected: ${collisionsStr}"
                else
                  items;
            };
          };
        };
      };

      assertions = [
        {
          assertion = config.minValue <= config.maxValue;
          message = "alloy: vars: provisioner index-allocator: minValue '${toString config.minValue}' must be less than maxValue '${toString config.maxValue}'";
        }
      ];

      run =
        { pkgs, ... }:
        pkgs.writeShellApplication {
          name = "index-allocator";
          checkPhase = "";
          runtimeInputs = [ pkgs.python3 ];
          text = ''
            OLD_FILE="$in/${config.facts.index.file}"
            NEW_FILE="$out/${config.facts.index.file}"
            KEYS_FILE=$(mktemp)
            cat << 'EOF' > "$KEYS_FILE"
            ${builtins.toJSON config.keys}
            EOF

            python3 -c '
              import sys, json, os

              old_file = sys.argv[1]
              keys_file = sys.argv[2]
              new_file = sys.argv[3]
              min_value = int(sys.argv[4])
              max_value = int(sys.argv[5])
              reuse_values = sys.argv[6] == "true"

              with open(keys_file) as f:
                required_keys = set(json.load(f))
              print(f"[debug] required_keys: {sorted(required_keys)}", file=sys.stderr)

              old_data = {}
              if os.path.exists(old_file):
                try:
                  with open(old_file) as f:
                    old_data = json.load(f).get("items", {})
                  print(f"[debug] old_data loaded: {old_data}", file=sys.stderr)
                except Exception as e:
                  print(f"[debug] failed to load old_file: {e}", file=sys.stderr)
              else:
                print(f"[debug] old_file does not exist: {old_file}", file=sys.stderr)

              obsolete_keys = [k for k in old_data if k not in required_keys]
              print(f"[debug] obsolete_keys: {obsolete_keys}", file=sys.stderr)
              for k in obsolete_keys:
                del old_data[k]

              new_keys = sorted([k for k in required_keys if k not in old_data])
              occupied = sorted(old_data.values())
              print(f"[debug] new_keys: {new_keys}", file=sys.stderr)
              print(f"[debug] occupied slots: {occupied}", file=sys.stderr)

              for key in new_keys:
                if reuse_values:
                  slot = min_value
                  for occ in occupied:
                    if occ <= slot:
                      slot += 1
                else:
                  slot = min_value if not occupied else occupied[-1] + 1

                if slot > max_value:
                  print(f"alloy: index_allocator: reached maxValue limit ({max_value}) for key {key}", file=sys.stderr)
                  sys.exit(1)

                print(f"[debug] allocating key={key} slot={slot}", file=sys.stderr)
                old_data[key] = slot
                occupied.append(slot)
                occupied.sort()

              print(f"[debug] final result: {old_data}", file=sys.stderr)
              with open(new_file, "w") as f:
                json.dump({"items": old_data}, f, indent=2)
                f.write("\n")
            ' "$OLD_FILE" "$KEYS_FILE" "$NEW_FILE" "${toString config.minValue}" "${toString config.maxValue}" "${
              if config.reuseValues then "true" else "false"
            }"
          '';
        };
    };
  };
}
