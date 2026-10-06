{
  flake.alloyModules.core =
    {
      config,
      alib,
      lib,
      ...
    }:
    let
      alloy = config;
      userSubmodule = { config, name, ... }: {
        options = {
          name = lib.mkOption {
            default = name;
            type = lib.types.str;
          };
          isAdmin = lib.mkOption {
            default = false;
            type = lib.types.bool;
          };
          passwd = {
            source = lib.mkOption {
              default = "secret";
              type = lib.types.enum [ "value" "secret" ];
            };
            value = lib.mkOption {
              type = lib.types.str;
            };
            secret = {
              secret = lib.mkOption {
                type = lib.types.str;
                default = "users/${name}/hashed-passwd";
              };
              generator = lib.mkOption {
                type = lib.types.str;
                default = "users/${name}/hashed-passwd";
              };
            };
          };
        };
      };
      mkUser = host: userId: user: {
        secrets = lib.mkIf (user.passwd.source == "secret") {
          ${user.passwd.secret.secret} = {};
        };

        nixosModule = {
          users.users.${userId} = {
            inherit (user) name;
            isNormalUser = true;
            createHome = true;
            home = "/home/${user.name}";
            group = userId;
            extraGroups = lib.optional user.isAdmin "wheel";
            password = lib.mkIf (user.passwd.source == "value") user.passwd.value;
            hashedPasswordFile = lib.mkIf (user.passwd.source == "secret") host.secrets.${user.passwd.secret.secret}.path;
          };
          users.groups.${userId} = {
            name = user.name;
          };
        };
      };
      hostSubmodule = { config, name, ... }: {
        options.users = lib.mkOption {
          default = { };
          type = lib.types.attrsOf (lib.types.submodule userSubmodule);
        };
        config =
          let
            configs = lib.mapAttrsToList (mkUser config) config.users;
          in
          {
            assertions = [
              {
                assertion = config.users != { };
                message = "[Alloy] Host '${name}': at least one user must be specified";
              }
            ];
            nixosModule = lib.mkMerge [
              (lib.mkMerge ((lib.catAttrs "nixosModule") configs))
              {
                users.mutableUsers = false;
              }
            ];
            secrets = lib.mkMerge ((lib.catAttrs "secrets") configs);
          };
      };
    in
    {
      options.hosts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
      };

      config.generators.instances = lib.pipe alloy.hosts [
        (lib.mapAttrsToList (hostName: host: lib.mapAttrsToList (userName: user: { inherit hostName host userName user; }) host.users))
        lib.flatten
        (lib.filter ({ user, ...}: user.passwd.source == "secret"))
        (lib.map (
          { hostName, host, userName, user }:
          lib.nameValuePair user.passwd.secret.generator {
            imports = [ alloy.generators.templates."users/hashed-passwd" ];
            secret = user.passwd.secret.secret;
            tags = [ "users" "users/${userName}" ] ++ host.tags;
          }
        ))
        builtins.listToAttrs
      ];

      config.secrets = lib.pipe alloy.hosts [
        (lib.mapAttrsToList (_: host: lib.mapAttrsToList (_: user: user) host.users))
        lib.flatten
        (lib.filter (user: user.passwd.source == "secret"))
        (lib.map (user: lib.nameValuePair user.passwd.secret.secret { }))
        builtins.listToAttrs
      ];

      config.generators.templates."users/hashed-passwd" = { config, ... }: {
        options = {
          secret = lib.mkOption {
            type = lib.types.str;
          };
        };
        config = {
          secrets.${config.secret} = { };
          package =
            { pkgs, ... }:
            pkgs.writeShellScriptBin "alloy-user-gen-hashed-passwd" ''
              read -r -s -p "Enter password: " pass
              echo
              hash=$(printf "%s\n" "$pass" | ${pkgs.mkpasswd}/bin/mkpasswd -m sha-512 -s)
              "$ALLOY_BIN" secrets set "${config.secret}" <<< "$hash"
            '';
        };
      };
    };
}
