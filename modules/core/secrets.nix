{
  alib,
  lib,
  config,
  alloy-internal-inputs,
  ...
}:
let
  alloy = config;

  masterSubmodule = { name, config, ... }: {
    options = {
      file = lib.mkOption {
        type = lib.types.str;
      };
      assertions = lib.mkOption {
        type = lib.types.listOf alib.types.assertion;
        default = [ ];
      };
    };
    config = {
      file = lib.mkOptionDefault "${alloy.workspace.secrets.baseDir}/${name}.age";
      assertions = [ ];
    };
  };

  secretSubmodule =
    contextType: contextName:
    {
      name,
      config,
      options,
      ...
    }:
    {
      options = {
        master = lib.mkOption {
          type = lib.types.str;
          default = name;
        };
        file = lib.mkOption { type = lib.types.str; };
        path = lib.mkOption { type = lib.types.str; };
        permissions = lib.mkOption {
          type = alib.types.permissions;
          default = {
            owner = "root";
            group = "root";
            mode = "0440";
          };
        };
        placeholder = lib.mkOption {
          type = lib.types.str;
          default = "___ALLOY_SECRET_${builtins.hashString "sha256" name}___";
        };
        assertions = lib.mkOption {
          type = lib.types.listOf alib.types.assertion;
          default = [ ];
        };
      };
      config = {
        file = lib.mkOptionDefault (
          if contextType == "host" then
            "${alloy.hosts.${contextName}.workspace.secrets.baseDir}/${name}.age"
          else
            "${alloy.jails.${contextName}.workspace.secrets.baseDir}/${name}.age"
        );
        path = lib.mkOptionDefault (
          if contextType == "host" then
            "${alloy.hosts.${contextName}.workspace.secrets.basePath}/${name}"
          else
            "${alloy.jails.${contextName}.workspace.secrets.basePath}/${name}"
        );

        assertions = [
          {
            assertion = builtins.hasAttr config.master alloy.secrets;
            message = ''
              [Alloy] Invalid master secret reference

              Secret '${name}' attached to ${contextType} '${contextName}' references a master secret '${config.master}', 
              which does not exist in 'secrets'.

              Location:
              ${lib.concatStringsSep "\n" (map (f: "  - ${f}") options.master.files)}
            '';
          }
        ];
      };
    };

  secretTemplateSubmodule =
    contextType: contextName:
    {
      name,
      ...
    }:
    {
      options = {
        template = lib.mkOption {
          type = lib.types.str;
          description = "Template to render.";
        };
        path = lib.mkOption {
          type = lib.types.str;
          description = "Path where the rendered file will be placed.";
        };
        permissions = lib.mkOption {
          type = alib.types.permissions;
          default = {
            owner = "root";
            group = "root";
            mode = "0440";
          };
        };
      };
      config = {
        path = lib.mkOptionDefault (
          if contextType == "host" then
            "${alloy.hosts.${contextName}.workspace.secretTemplates.basePath}/${name}"
          else
            "${alloy.jails.${contextName}.workspace.secretTemplates.basePath}/${name}"
        );
      };
    };

  mkJail =
    host: jailName: jail:
    let
      secrets = lib.filter (s: s.jailName == jailName) jailSecretsList;
      templates = lib.filter (s: s.jailName == jailName) jailTemplatesList;
      mkSecret =
        secret:
        { config, ... }:
        let
          agenixPath = config.age.secrets."alloy/secrets/jails/${jailName}/${secret.secretName}".path;
        in
        {
          assertions = [
            {
              assertion = builtins.pathExists (alloy.workspace.root + "/${secret.file}");
              message = "[Alloy] Secret '${secret.secretName}' attached to jail '${jailName}' on host '${jail.host}' not found at ${alloy.workspace.root}/${secret.file}. You may need to rekey the secret for this jail, or add the rekeyed secret to git.";
            }
          ];

          age.secrets."alloy/secrets/jails/${jailName}/${secret.secretName}" = {
            file = alloy.workspace.root + "/${secret.file}";
            owner = "root";
            group = "root";
            mode = secret.permissions.mode;
          };

          containers."alloy-jail-${jailName}" = {
            bindMounts."secret-${secret.secretName}" = {
              hostPath = agenixPath;
              mountPoint = agenixPath;
              isReadOnly = true;
            };
            config = { pkgs, ... }: {
              systemd.services."alloy-secrets-and-templates-setup" = {
                script = ''
                  install -D \
                    -m "${secret.permissions.mode}" \
                    -o "${secret.permissions.owner}" \
                    -g "${secret.permissions.group}" \
                    "${agenixPath}" \
                    "${secret.path}"
                '';
              };
            };
          };
        };
      mkTemplate =
        template:
        { config, ... }:
        {
          containers."alloy-jail-${jailName}" = {
            config = { pkgs, ... }: {
              systemd.services."alloy-secrets-and-templates-setup" = {
                script = ''
                  mkdir -p "$(dirname "${template.path}")"
                  jq -rRs ${
                    lib.concatImapStringsSep " " (
                      idx: secret: ''--arg secret${toString idx} "$(cat ${secret.path})"''
                    ) secrets
                  } '${
                    if secrets == [ ] then
                      "."
                    else
                      lib.concatImapStringsSep " | " (
                        idx: secret: ''gsub("${secret.placeholder}"; $secret${toString idx})''
                      ) secrets
                  }' "${pkgs.writeText "alloy-jail-${jailName}-secret-template-${template.templateName}" template.template}" > "${template.path}.tmp"
                  install -D -m "${template.permissions.mode}" -o "${template.permissions.owner}" -g "${template.permissions.group}" "${template.path}.tmp" "${template.path}"
                  rm -f "${template.path}.tmp"
                '';
              };
            };
          };
        };
    in
    {
      nixosModule = {
        imports = [
          alloy-internal-inputs.agenix.nixosModules.default
        ]
        ++ (lib.map mkSecret secrets)
        ++ (lib.map mkTemplate templates);

        age.identityPaths = lib.optionals (secrets != [ ]) (
          lib.map (kp: toString kp.identity) host.workspace.secrets.age.keyPairs
        );

        containers."alloy-jail-${jailName}" = {
          config = { pkgs, ... }: {
            systemd.services."alloy-secrets-and-templates-setup" = {
              enable = secrets != [ ] || templates != [ ];
              wantedBy = [ "sysinit.target" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              path = [
                pkgs.jq
                pkgs.coreutils
              ];
              script = "";
            };
          };
        };
      };
    };

  mkHost =
    hostName: host:
    let
      secrets = lib.filter (s: s.hostName == hostName) hostSecretsList;
      templates = lib.filter (s: s.hostName == hostName) hostTemplatesList;
      mkSecret = secret: {
        assertions = [
          {
            assertion = builtins.pathExists (alloy.workspace.root + "/${secret.file}");
            message = "[Alloy] Secret '${secret.secretName}' attached to host '${hostName}' not found at ${alloy.workspace.root}/${secret.file}. You may need to rekey the secret for this host, or add the rekeyed secret to git.";
          }
        ];

        age.secrets."alloy/secrets/host/${secret.secretName}" = {
          file = alloy.workspace.root + "/${secret.file}";
          path = secret.path;
          inherit (secret.permissions) owner group mode;
        };
      };
      mkTemplate = template: { pkgs, ... }: {
        systemd.services."alloy-secret-templates-setup" = {
          script = ''
            mkdir -p "$(dirname "${template.path}")"
            jq -rRs ${
              lib.concatImapStringsSep " " (
                idx: secret: ''--arg secret${toString idx} "$(cat ${secret.path})"''
              ) secrets
            } '${
              if secrets == [ ] then
                "."
              else
                lib.concatImapStringsSep " | " (
                  idx: secret: ''gsub("${secret.placeholder}"; $secret${toString idx})''
                ) secrets
            }' "${pkgs.writeText "alloy-host-${hostName}-secret-template-${template.templateName}" template.template}" > "${template.path}.tmp"
            install -D -m "${template.permissions.mode}" -o "${template.permissions.owner}" -g "${template.permissions.group}" "${template.path}.tmp" "${template.path}"
            rm -f "${template.path}.tmp"
          '';
        };
      };
    in
    {
      nixosModule = { pkgs, ... }: {
        imports = [
          alloy-internal-inputs.agenix.nixosModules.default
        ]
        ++ (lib.map mkSecret secrets)
        ++ (lib.map mkTemplate templates);

        age.identityPaths = lib.optionals (secrets != [ ]) (
          lib.map (kp: toString kp.identity) host.workspace.secrets.age.keyPairs
        );

        systemd.services."alloy-secret-templates-setup" = {
          enable = templates != [ ];
          wantedBy = [ "sysinit.target" ];
          after = [ "agenix-install-secrets.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          path = [
            pkgs.jq
            pkgs.coreutils
          ];
        };
      };
    };

  hostSubmodule = { name, config, ... }: {
    options = {
      secrets = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule (secretSubmodule "host" name));
      };
      secretTemplates = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule (secretTemplateSubmodule "host" name));
      };
      workspace.secrets = {
        baseDir = lib.mkOption {
          type = lib.types.str;
          default = "secrets/hosts/${name}";
        };
        basePath = lib.mkOption {
          type = lib.types.str;
          default = "/run/alloy/secrets";
        };
        age.keyPairs = lib.mkOption {
          default = [ ];
          type = lib.types.listOf alib.types.ageKeyPair;
        };
      };
      workspace.secretTemplates = {
        basePath = lib.mkOption {
          type = lib.types.str;
          default = "/run/alloy/secret-templates";
        };
      };
    };
    config =
      let
        configs = lib.flatten (
          [ (mkHost name config) ]
          ++ (lib.pipe alloy.jails [
            (lib.filterAttrs (_: jail: jail.host == name))
            (lib.mapAttrsToList (jailName: jail: mkJail config jailName jail))
          ])
        );
      in
      {
        nixosModule = lib.mkMerge (lib.catAttrs "nixosModule" configs);
      };
  };

  jailSubmodule = { name, ... }: {
    options = {
      secrets = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule (secretSubmodule "jail" name));
      };
      secretTemplates = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule (secretTemplateSubmodule "jail" name));
      };
      workspace.secrets = {
        baseDir = lib.mkOption {
          type = lib.types.str;
          default = "secrets/jails/${name}";
        };
        basePath = lib.mkOption {
          type = lib.types.str;
          default = "/run/alloy/secrets";
        };
      };
      workspace.secretTemplates = {
        basePath = lib.mkOption {
          type = lib.types.str;
          default = "/run/alloy/secret-templates";
        };
      };
    };
  };

  hostSecretsList = lib.flatten (
    lib.mapAttrsToList (
      hostName: host:
      lib.mapAttrsToList (secretName: secret: secret // { inherit hostName secretName; }) host.secrets
    ) alloy.hosts
  );

  jailSecretsList = lib.flatten (
    lib.mapAttrsToList (
      jailName: jail:
      lib.mapAttrsToList (
        secretName: secret:
        secret
        // {
          inherit jailName secretName;
          hostName = jail.host;
        }
      ) jail.secrets
    ) alloy.jails
  );

  hostTemplatesList = lib.flatten (
    lib.mapAttrsToList (
      hostName: host:
      lib.mapAttrsToList (
        templateName: template: template // { inherit hostName templateName; }
      ) host.secretTemplates
    ) alloy.hosts
  );

  jailTemplatesList = lib.flatten (
    lib.mapAttrsToList (
      jailName: jail:
      lib.mapAttrsToList (
        templateName: template:
        template
        // {
          inherit jailName templateName;
          hostName = jail.host;
        }
      ) jail.secretTemplates
    ) alloy.jails
  );
in
{
  options = {
    secrets = lib.mkOption {
      default = { };
      type = lib.types.attrsOf (lib.types.submodule masterSubmodule);
    };

    workspace.secrets = {
      baseDir = lib.mkOption {
        type = lib.types.str;
        default = "secrets/masters";
      };
      age.keyPairs = lib.mkOption {
        default = [ ];
        type = lib.types.listOf alib.types.ageKeyPair;
      };
    };

    hosts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
    };

    jails = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule jailSubmodule);
    };
  };

  config = {
    assertions =
      (lib.flatten (lib.mapAttrsToList (n: s: s.assertions) alloy.secrets))
      ++ (lib.flatten (lib.map (s: s.assertions) hostSecretsList))
      ++ (lib.flatten (lib.map (s: s.assertions) jailSecretsList));

    cli.apis."AlloySecretsAPI" =
      let
        toRageRecipientArgs =
          keyPairs:
          lib.flatten (
            lib.map (kp: [
              (if builtins.isPath kp.recipient || lib.hasPrefix "/" (toString kp.recipient) then "-R" else "-r")
              (toString kp.recipient)
            ]) keyPairs
          );
        toRageIdentityArgs =
          keyPairs:
          lib.flatten (
            lib.map (kp: [
              "-i"
              (toString kp.identity)
            ]) keyPairs
          );
      in
      {
        description = "API for managing Alloy secrets";
        script = ''
          class AlloySecretsAPI:
              """
              API for managing Alloy secrets.
              """
              db = ${
                builtins.toJSON (
                  builtins.listToAttrs (
                    lib.mapAttrsToList (name: secret: lib.nameValuePair name { file = secret.file; }) alloy.secrets
                  )
                )
              }
              host_db = ${
                builtins.toJSON (
                  lib.map (s: {
                    name = s.secretName;
                    host = s.hostName;
                    inherit (s)
                      master
                      file
                      path
                      permissions
                      ;
                  }) hostSecretsList
                )
              }
              unit_db = ${
                builtins.toJSON (
                  lib.map (s: {
                    name = s.secretName;
                    jail = s.jailName;
                    inherit (s)
                      master
                      file
                      path
                      permissions
                      ;
                  }) jailSecretsList
                )
              }

              valid_hosts = ${builtins.toJSON (builtins.attrNames alloy.hosts)}
              valid_units = ${builtins.toJSON (builtins.attrNames alloy.jails)}

              master_identities = ${builtins.toJSON (toRageIdentityArgs alloy.workspace.secrets.age.keyPairs)}
              master_recipients = ${builtins.toJSON (toRageRecipientArgs alloy.workspace.secrets.age.keyPairs)}

              host_recipients = ${
                builtins.toJSON (
                  lib.mapAttrs (hostName: host: toRageRecipientArgs host.workspace.secrets.age.keyPairs) alloy.hosts
                )
              }
              unit_recipients = ${
                builtins.toJSON (
                  lib.mapAttrs (
                    jailName: jail: toRageRecipientArgs alloy.hosts.${jail.host}.workspace.secrets.age.keyPairs
                  ) alloy.jails
                )
              }

              @classmethod
              def get_file(cls, name: str) -> Path:
                  data = cls.db.get(name)
                  if not data:
                      CLI.abort(f"Master secret '{CLI.id(name)}' is not defined in the configuration.")
                  return CLI.root / data["file"]

              @classmethod
              def exists(cls, name: str) -> bool:
                  data = cls.db.get(name)
                  if not data:
                      return False
                  return (CLI.root / data["file"]).exists()

              @classmethod
              def check_recipients(cls):
                  if not cls.master_recipients:
                      CLI.abort("No master recipients defined in workspace.secrets.age.keyPairs")
                      
              @classmethod
              def check_identities(cls):
                  if not cls.master_identities:
                      CLI.abort("No master identities defined in workspace.secrets.age.keyPairs")

              @classmethod
              def set(cls, name: str, data: bytes, force: bool = False, add_to_git: bool = False) -> Path:
                  cls.check_recipients()
                  secret_file = cls.get_file(name)
                  if secret_file.exists() and not force:
                      CLI.skip(f"Secret '{CLI.id(name)}' already exists. Use --force to overwrite.")
                      sys.exit(0)
                      
                  CLI.step(f"Encrypting and saving secret '{CLI.id(name)}'...")
                  secret_file.parent.mkdir(parents=True, exist_ok=True)
                  res = subprocess.run(["rage", "-e"] + cls.master_recipients + ["-o", str(secret_file)], input=data, capture_output=True)
                  if res.returncode != 0:
                      CLI.abort(f"Failed to encrypt: {res.stderr.decode().strip()}")
                      
                  if add_to_git:
                      CLI.step("Adding file to git index...")
                      CLI.run("git", "add", secret_file)
                      
                  return secret_file

              @classmethod
              def get(cls, name: str) -> bytes:
                  cls.check_identities()
                  secret_file = cls.get_file(name)
                  if not secret_file.is_file():
                      CLI.abort(f"Secret file {CLI.path(secret_file)} does not exist.")
                      
                  res = subprocess.run(["rage", "-d"] + cls.master_identities + [str(secret_file)], capture_output=True)
                  if res.returncode != 0:
                      CLI.abort(f"Failed to decrypt '{name}': {res.stderr.decode().strip()}")
                  return res.stdout
                  
              @classmethod
              def _rekey_single(cls, master_name: str, target_file_rel: str, recipients: list, target_label: str, force: bool = False, add_to_git: bool = False):
                  target_file = CLI.root / target_file_rel
                  master_data = cls.db.get(master_name)
                  
                  if not master_data:
                      CLI.abort(f"Master secret '{master_name}' not found for {target_label}")
                      
                  master_file = CLI.root / master_data["file"]
                  
                  if not master_file.exists():
                      CLI.abort(f"Master secret file missing: {master_file}")

                  if target_file.exists() and not force:
                      CLI.skip(f"{target_label} already exists. (Use -f to force)")
                      return
                      
                  if not recipients:
                      CLI.abort(f"No recipients defined for {target_label}!")

                  target_file.parent.mkdir(parents=True, exist_ok=True)
                  
                  dec_proc = subprocess.Popen(["rage", "-d"] + cls.master_identities + [str(master_file)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                  enc_proc = subprocess.Popen(["rage", "-e"] + recipients + ["-o", str(target_file)], stdin=dec_proc.stdout, stderr=subprocess.PIPE)
                  
                  dec_proc.stdout.close()
                  enc_stderr = enc_proc.communicate()[1]
                  dec_stderr = dec_proc.communicate()[1]
                  
                  if dec_proc.returncode != 0:
                      CLI.abort(f"Decryption failed for '{master_name}': {dec_stderr.decode().strip()}")
                  if enc_proc.returncode != 0:
                      CLI.abort(f"Encryption failed for {target_label}: {enc_stderr.decode().strip()}")
                      
                  if add_to_git:
                      CLI.run("git", "add", target_file)
                      
                  CLI.ok(f"Rekeyed {target_label}")

              @classmethod
              def rekey_host(cls, host_name: str, secret_name: str, force: bool = False, add_to_git: bool = False):
                  h_sec = next((s for s in cls.host_db if s["host"] == host_name and s["name"] == secret_name), None)
                  if not h_sec:
                      CLI.abort(f"Secret '{secret_name}' is not defined for host '{host_name}'")
                      
                  cls._rekey_single(
                      h_sec["master"], 
                      h_sec["file"], 
                      cls.host_recipients[h_sec["host"]], 
                      f"host '{CLI.id(h_sec['host'])}' secret '{CLI.id(h_sec['name'])}'",
                      force=force,
                      add_to_git=add_to_git
                  )

              @classmethod
              def rekey_jail(cls, jail_name: str, secret_name: str, force: bool = False, add_to_git: bool = False):
                  j_sec = next((s for s in cls.unit_db if s["jail"] == jail_name and s["name"] == secret_name), None)
                  if not j_sec:
                      CLI.abort(f"Secret '{secret_name}' is not defined for jail '{jail_name}'")
                      
                  cls._rekey_single(
                      j_sec["master"], 
                      j_sec["file"], 
                      cls.unit_recipients[j_sec["jail"]], 
                      f"jail '{CLI.id(j_sec['jail'])}' secret '{CLI.id(j_sec['name'])}'",
                      force=force,
                      add_to_git=add_to_git
                  )
        '';
      };

    cli.commands =
      let
        commonFlags = {
          addToGit = {
            description = "Stage the modified secret file in the git index";
            longNames = [ "add-to-git" ];
            shortNames = [ "a" ];
          };
          force = {
            description = "Overwrite the secret file if it already exists";
            longNames = [ "force" ];
            shortNames = [ "f" ];
          };
        };

        ragePackages = { pkgs, ... }: [
          pkgs.rage
          pkgs.age-plugin-yubikey
          pkgs.age-plugin-fido2-hmac
          pkgs.git
          pkgs.coreutils
        ];
      in
      {
        secrets = {
          description = "Manage encrypted age secrets";

          commands.set = {
            description = "Set the value of a master secret from standard input";
            args = [
              {
                name = "secret";
                description = "The name of the master secret to set";
              }
            ];
            flags = {
              "add_to_git" = commonFlags.addToGit;
              "force" = commonFlags.force;
            };
            packages = ragePackages;
            script = ''
              import sys

              new_data = sys.stdin.buffer.read()
              secret_file = AlloySecretsAPI.set(
                  args.secret, 
                  new_data, 
                  force=getattr(args, "force", False),
                  add_to_git=getattr(args, "add_to_git", False)
              )
                  
              CLI.ok(f"Secret '{CLI.id(args.secret)}' successfully encrypted to {CLI.path(secret_file)}")
            '';
          };

          commands.view = {
            description = "View the decrypted value of a master secret in standard output";
            args = [
              {
                name = "secret";
                description = "The name of the master secret to view";
              }
            ];
            packages = ragePackages;
            script = ''
              import sys

              decrypted = AlloySecretsAPI.get(args.secret)
              sys.stdout.buffer.write(decrypted)
              sys.stdout.buffer.flush()
            '';
          };

          commands.edit = {
            description = "Create or edit a master secret interactively";
            args = [
              {
                name = "secret";
                description = "The name of the master secret to edit";
              }
            ];
            flags = {
              "add_to_git" = commonFlags.addToGit;
            };
            packages = { pkgs, ... }: (ragePackages { inherit pkgs; }) ++ [ pkgs.nano ];
            script = ''
              import sys
              import os
              import shlex
              import hashlib
              import tempfile
              import atexit
              from pathlib import Path

              AlloySecretsAPI.check_recipients()
              AlloySecretsAPI.check_identities()

              secret_file = AlloySecretsAPI.get_file(args.secret)

              tmp_dir = "/dev/shm" if Path("/dev/shm").is_dir() else None
              fd, tmp_file_path = tempfile.mkstemp(dir=tmp_dir, text=False)
              os.close(fd)
              tmp_file = Path(tmp_file_path)
              atexit.register(lambda: tmp_file.unlink(missing_ok=True))

              def get_hash(p: Path) -> str:
                  return hashlib.sha256(p.read_bytes()).hexdigest() if p.exists() else ""

              if secret_file.exists():
                  tmp_file.write_bytes(AlloySecretsAPI.get(args.secret))
              else:
                  CLI.step(f"Creating new master secret '{CLI.id(args.secret)}'...")

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

              AlloySecretsAPI.set(
                  args.secret, 
                  tmp_file.read_bytes(), 
                  force=True,
                  add_to_git=getattr(args, "add_to_git", False)
              )

              CLI.ok(f"Secret '{CLI.id(args.secret)}' saved successfully.")
            '';
          };

          commands.rekey = {
            description = "Rekey master secrets into host and jail specific secrets";
            flags = {
              "add_to_git" = commonFlags.addToGit;
              "force" = commonFlags.force;
              "secret" = {
                description = "Filter by master secret name (can be used multiple times)";
                action = "append";
              };
              "host" = {
                description = "Filter by host name (can be used multiple times)";
                action = "append";
              };
              "jail" = {
                description = "Filter by jail name (can be used multiple times)";
                action = "append";
              };
            };
            packages = ragePackages;
            script = ''
              import sys

              AlloySecretsAPI.check_identities()

              if getattr(args, "host", None):
                  for h in args.host:
                      if h not in AlloySecretsAPI.valid_hosts:
                          CLI.abort(f"Host '{CLI.id(h)}' does not exist in the cluster configuration.")

              if getattr(args, "jail", None):
                  for j in args.jail:
                      if j not in AlloySecretsAPI.valid_units:
                          CLI.abort(f"Jail '{CLI.id(j)}' does not exist in the cluster configuration.")

              for h_sec in AlloySecretsAPI.host_db:
                  if getattr(args, "secret", None) and h_sec["master"] not in args.secret: continue
                  if getattr(args, "host", None) and h_sec["host"] not in args.host: continue

                  AlloySecretsAPI.rekey_host(
                      h_sec["host"], 
                      h_sec["name"], 
                      force=getattr(args, "force", False),
                      add_to_git=getattr(args, "add_to_git", False)
                  )

              for j_sec in AlloySecretsAPI.unit_db:
                  if getattr(args, "secret", None) and j_sec["master"] not in args.secret: continue
                  if getattr(args, "jail", None) and j_sec["jail"] not in args.jail: continue

                  AlloySecretsAPI.rekey_jail(
                      j_sec["jail"], 
                      j_sec["name"], 
                      force=getattr(args, "force", False),
                      add_to_git=getattr(args, "add_to_git", False)
                  )
            '';
          };
        };
      };
  };
}
