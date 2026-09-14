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
          hashedPasswd = {
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
      mkUser = host: userId: user: {
        secrets.${user.hashedPasswd.secret} = { };

        nixosModule = {
          users.users.${userId} = {
            inherit (user) name;
            isNormalUser = true;
            createHome = true;
            home = "/home/${user.name}";
            group = userId;
            extraGroups = lib.optional user.isAdmin "wheel";
            hashedPasswordFile = host.secrets.${user.hashedPasswd.secret}.path;
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
                assertion = config.users != {};
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
        (lib.mapAttrsToList (_: host: lib.mapAttrsToList (_: user: user) host.users))
        lib.flatten
        (lib.map (
          user:
          lib.nameValuePair user.hashedPasswd.generator {
            imports = [ alloy.generators.templates."users/hashed-passwd" ];
            secret = user.hashedPasswd.secret;
          }
        ))
        builtins.listToAttrs
      ];

      config.secrets = lib.pipe alloy.hosts [
        (lib.mapAttrsToList (_: host: lib.mapAttrsToList (_: user: user) host.users))
        lib.flatten
        (lib.map (user: lib.nameValuePair user.hashedPasswd.secret { }))
        builtins.listToAttrs
      ];

      config.generators.templates."users/hashed-passwd" = { config, ... }: {
        options = {
          secret = lib.mkOption {
            type = lib.types.str;
          };
        };
        config = {
          tags = [ "user" ];
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
