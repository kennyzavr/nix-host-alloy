{
  alib,
  lib,
  config,
  ...
}:
let
  alloy = config;

  provisionerSpecModule = { name, ... }: {
    options = {
      id = alib.mkIdOpt name "";
      facts = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, ... }: {
              options = {
                id = alib.mkIdOpt name "";
                file = lib.mkOption {
                  type = lib.types.str;
                  default = name;
                };
                type = lib.mkOption {
                  type = lib.types.unspecified;
                };
              };
            }
          )
        );
      };
      secrets = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, ... }: {
              options = {
                id = alib.mkIdOpt name "";
                file = lib.mkOption {
                  type = lib.types.str;
                  default = name;
                };
              };
            }
          )
        );
      };
      tags = lib.mkOption {
        default = [ ];
        type = lib.types.listOf lib.types.str;
      };
      run = lib.mkOption {
        type = lib.types.functionTo lib.types.package;
        description = "Function taking { pkgs } and returning a script package.";
      };
      assertions = lib.mkOption {
        default = [ ];
        type = lib.types.listOf alib.types.assertion;
      };
    };
  };

  provisionerModule =
    { config, name, ... }:
    let
      spec = builtins.head (builtins.attrValues config.spec);
    in
    {
      options = {
        id = alib.mkIdOpt name "";
        spec = lib.mkOption {
          type = lib.types.attrTag (
            lib.mapAttrs (
              specId: spec:
              lib.mkOption {
                type = lib.types.submoduleWith {
                  modules = [
                    spec
                  ];
                };
              }
            ) alloy.vars.provisionerSpecs
          );
        };
        wants = lib.mkOption {
          default = [ ];
          type = lib.types.listOf lib.types.str;
        };
        wantedBy = lib.mkOption {
          default = [ ];
          type = lib.types.listOf lib.types.str;
        };
        after = lib.mkOption {
          default = [ ];
          type = lib.types.listOf lib.types.str;
        };
        before = lib.mkOption {
          default = [ ];
          type = lib.types.listOf lib.types.str;
        };
        facts = lib.mkOption {
          default = { };
          type = lib.types.attrsOf (
            lib.types.submodule (
              { name, ... }: {
                options = {
                  id = alib.mkIdOpt name "";
                  name = lib.mkOption {
                    default = "${config.id}/${name}";
                    type = lib.types.str;
                  };
                };
              }
            )
          );
        };
        secrets = lib.mkOption {
          default = { };
          type = lib.types.attrsOf (
            lib.types.submodule (
              { name, ... }: {
                options = {
                  id = alib.mkIdOpt name "";
                  name = lib.mkOption {
                    default = "${config.id}/${name}";
                    type = lib.types.str;
                  };
                };
              }
            )
          );
        };
        tags = lib.mkOption {
          default = [ ];
          type = lib.types.listOf lib.types.str;
        };
        script = lib.mkOption {
          readOnly = true;
          type = lib.types.functionTo lib.types.package;
        };
      };
      config = {
        facts = lib.mapAttrs (_: fact: { }) spec.facts;

        secrets = lib.mapAttrs (_: secret: { }) spec.secrets;

        script =
          { pkgs, ... }:
          pkgs.writeShellApplication {
            name = "alloy-vars-provisioner-${config.id}";
            checkPhase = "";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.git
            ];
            text = ''
              force_add="$1"
              add_to_git="$2"

              if [ -d "/dev/shm" ]; then
                export TMPDIR="/dev/shm"
              fi
              in=$(mktemp -d)
              out=$(mktemp -d)
              trap 'rm -rf "$in" "$out"' EXIT

              export in
              export out

              ${lib.concatMapStringsSep "\n" (
                fact:
                lib.optionalString (builtins.hasAttr fact.name alloy.vars.facts) ''
                  if [ -f "${alloy.vars.facts.${fact.name}.file}" ]; then
                   mkdir -p "$(dirname "$in/${spec.facts.${fact.id}.file}")"
                   ${
                     lib.getExe (alloy.cli.commands.vars.commands.facts.commands.view.script { inherit pkgs; })
                   } "${fact.name}" > "$in/${spec.facts.${fact.id}.file}"
                  fi
                ''
              ) (builtins.attrValues config.facts)}

              ${lib.getExe (spec.run { inherit pkgs; })}

              ${lib.concatMapStringsSep "\n" (fact: ''
                if ! [ -f "$out/${spec.facts.${fact.id}.file}" ]; then
                  alloy_cli_echo_err "Run script (spec '${spec.id}') has not generated expected fact file '${spec.facts.${fact.id}.file}'"
                  exit 1
                fi
              '') (builtins.attrValues config.facts)}

              ${lib.concatMapStringsSep "\n" (secret: ''
                if ! [ -f "$out/${spec.secrets.${secret.id}.file}" ]; then
                  alloy_cli_echo_err "Run script (spec '${spec.id}') has not generated exepcted secret file '${spec.secrets.${secret.id}.file}'"
                  exit 1
                fi
              '') (builtins.attrValues config.secrets)}

              common_flags=()
              if [ "$add_to_git" -eq 1 ]; then
                common_flags+=("-a")
              fi
              if [ "$force_add" -eq 1 ]; then
                common_flags+=("-f")
              fi

              ${lib.concatMapStringsSep "\n" (fact: ''
                cat "$out/${spec.facts.${fact.id}.file}" | ${
                  lib.getExe (alloy.cli.commands.vars.commands.facts.commands.set.script { inherit pkgs; })
                } "''${common_flags[@]}" "${fact.name}"
              '') (builtins.attrValues config.facts)}

              ${lib.concatMapStringsSep "\n" (secret: ''
                cat "$out/${spec.secrets.${secret.id}.file}" | ${
                  lib.getExe (alloy.cli.commands.vars.commands.secrets.commands.set.script { inherit pkgs; })
                } "''${common_flags[@]}" "${secret.name}"
              '') (builtins.attrValues config.secrets)}
            '';
          };
      };
    };

in
{
  options = {
    vars.provisionerSpecs = lib.mkOption {
      default = { };
      type = lib.types.attrsOf (
        lib.types.deferredModuleWith {
          staticModules = [ provisionerSpecModule ];
        }
      );
    };

    vars.provisioners = alib.extend provisionerModule;
  };

  config = {
    assertions = lib.pipe alloy.vars.provisioners [
      builtins.attrValues
      (lib.map (provisioner: (builtins.head (builtins.attrValues provisioner.spec)).assertions))
      lib.flatten
    ];

    vars.facts = lib.pipe alloy.vars.provisioners [
      builtins.attrValues
      (lib.map (
        provisioner:
        lib.mapAttrsToList (
          _: fact:
          let
            spec = builtins.head (builtins.attrValues provisioner.spec);
          in
          {
            ${fact.name} = {
              type = spec.facts.${fact.id}.type;
            };
          }
        ) provisioner.facts
      ))
      lib.flatten
      lib.mkMerge
    ];

    vars.secrets = lib.pipe alloy.vars.provisioners [
      builtins.attrValues
      (lib.map (
        provisioner:
        lib.mapAttrsToList (_: secret: {
          ${secret.name} = { };
        }) provisioner.secrets
      ))
      lib.flatten
      lib.mkMerge
    ];

    cli.commands.vars.commands.provisioners =
      let
        closures = lib.mapAttrs (
          _: provisioner:
          builtins.genericClosure {
            startSet = [ { key = provisioner.id; } ];
            operator =
              item:
              let
                currentProvisioner = alloy.vars.provisioners.${item.key};
                reverseWants = builtins.filter (
                  otherProvisioner: builtins.elem item.key alloy.vars.provisioners.${otherProvisioner.id}.wantedBy
                ) (builtins.attrValues alloy.vars.provisioners);
              in
              lib.map (dep: { key = dep; }) (currentProvisioner.wants ++ reverseWants);
          }
        ) alloy.vars.provisioners;

        sortedResult = lib.toposort (
          a: b:
          (lib.elem a.id b.after)
          || (lib.elem b.id a.before)
          || (lib.elem a.id b.wants)
          || (lib.elem b.id a.wantedBy)
        ) (builtins.attrValues alloy.vars.provisioners);

        orderedProvisioners =
          if sortedResult ? cycle then
            throw "alloy: cyclic dependency detected in var provisioners: ${
              builtins.toJSON (map (s: s.id) sortedResult.cycle)
            }"
          else
            sortedResult.result;
      in
      {
        description = "Manage provisioners";
        commands.run = { config, ... }: {
          description = "run specified provisioners";
          flags = {
            add-to-git = {
              description = "Add generated files to git";
              short = "a";
            };
            force = {
              description = "Force regeneration of explicitly specified provisioners";
              short = "f";
            };
            spec-tag = {
              description = "Filter by spec tag";
              type = "array";
            };
            spec = {
              description = "Filter by spec ID";
              type = "array";
            };
          };
          run =
            { pkgs, ... }:
            pkgs.writeShellApplication {
              name = "${config.name}-run";
              checkPhase = "";
              text = ''
                # shellcheck disable=SC2034
                provisioners=("$@")
                # shellcheck disable=SC2034
                specs=()
                if [ -n "''${ALLOY_CLI_FLAG_SPEC:-}" ]; then
                  # shellcheck disable=SC2034
                  mapfile -d $'\x1f' -t specs < <(printf %s "$ALLOY_CLI_FLAG_SPEC")
                fi
                # shellcheck disable=SC2034
                spec_tags=()
                if [ -n "''${ALLOY_CLI_FLAG_SPEC_TAG:-}" ]; then
                  # shellcheck disable=SC2034
                  mapfile -d $'\x1f' -t spec_tags < <(printf %s "$ALLOY_CLI_FLAG_SPEC_TAG")
                fi

                # shellcheck disable=SC2034
                declare -A should_run
                # shellcheck disable=SC2034
                declare -A is_explicit

                ${lib.concatMapStringsSep "\n" (
                  provisioner:
                  let
                    spec = builtins.head (builtins.attrValues provisioner.spec);
                  in
                  ''
                    is_selected=0
                    if [ "''${#provisioners[@]}" -eq 0 ] && [ "''${#specs[@]}" -eq 0 ] && [ "''${#spec_tags[@]}" -eq 0 ]; then
                      is_selected=1
                    fi

                    if [ "$is_selected" -eq 0 ]; then
                      for req_provisioner in "''${provisioners[@]}"; do
                        :
                        if [ "$req_provisioner" = "${provisioner.id}" ]; then
                          is_selected=1
                          break
                        fi
                      done
                    fi

                    if [ "$is_selected" -eq 0 ]; then
                      for spec in "''${specs[@]}"; do
                        :
                        if [ "$spec" = "${spec.id}" ]; then
                          is_selected=1
                          break
                        fi
                      done
                    fi

                    if [ "$is_selected" -eq 0 ]; then
                      for spec_tag in "''${spec_tags[@]}"; do
                        :
                        ${lib.concatMapStringsSep "\n" (tag: ''
                          if [ "$spec_tag" = "${tag}" ]; then
                            is_selected=1
                            break
                          fi
                        '') spec.tags}
                      done
                    fi

                    if [ "$is_selected" -eq 1 ]; then
                      is_explicit["${provisioner.id}"]=1
                      ${lib.concatMapStringsSep "\n" (dep: ''
                        should_run["${dep.key}"]=1
                      '') closures.${provisioner.id}}
                    fi
                  ''
                ) (builtins.attrValues alloy.vars.provisioners)}

                ${lib.concatMapStringsSep "\n" (
                  provisioner:
                  let
                    spec = builtins.head (builtins.attrValues provisioner.spec);
                  in
                  ''
                    if [ "''${should_run["${provisioner.id}"]:-0}" = "1" ]; then
                      force_add=0
                      if [ "''${is_explicit["${provisioner.id}"]:-0}" = "1" ] && [ "$ALLOY_CLI_FLAG_FORCE" -eq 1 ]; then
                         force_add=1
                      fi
                      
                      alloy_cli_echo_step "Running provisioner: ''${ALLOY_CLI_STYLE_BOLD}${provisioner.id}''${ALLOY_CLI_STYLE_NC} (spec: ${spec.id})"
                      ${lib.getExe (provisioner.script { inherit pkgs; })} "$force_add" "$ALLOY_CLI_FLAG_ADD_TO_GIT"
                    fi
                  ''
                ) orderedProvisioners}
              '';
            };
        };
      };
  };
}
