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

      driverType = lib.types.attrTag {
        directory = lib.mkOption {
          type = lib.types.submodule { };
          description = "Create a persistent directory on the host and bind-mount it into the jail.";
        };
      };

      volumeSubmodule = { name, config, ... }: {
        options = {
          path = lib.mkOption {
            type = lib.types.str;
            default = "/var/lib/alloy/volumes/${name}";
            description = "Mount point for this volume inside the jail.";
          };
          driver = lib.mkOption {
            type = driverType;
            description = "Volume provisioning method, such as a host-backed directory.";
          };
          permissions = lib.mkOption {
            default = {
              mode = "0755";
            };
            type = alib.types.permissions;
            description = "Owner, group, and mode used for the volume directory.";
          };
        };
      };

      mkJail =
        host: jailName: jail:
        let
          volumes = lib.mapAttrsToList (volumeName: volume: volume // { inherit volumeName; }) jail.volumes;
          mkDirectoryVolume =
            volume:
            let
              internalPath = "/var/lib/alloy-internal/volumes/jails/${jailName}/${volume.volumeName}";
            in
            { config, ... }:
            {
              systemd.tmpfiles.settings."10-alloy-volume-${volume.volumeName}" = {
                ${internalPath}.d = {
                  user = "root";
                  group = "root";
                  mode = volume.permissions.mode;
                };
              };

              containers."alloy-jail-${jailName}" = {
                bindMounts."volume-${volume.volumeName}" = {
                  hostPath = internalPath;
                  mountPoint = volume.path;
                  isReadOnly = false;
                };
                config = { pkgs, ... }: {
                  systemd.tmpfiles.settings."10-alloy-volume-${volume.volumeName}" = {
                    ${volume.path}."z" = {
                      user = toString volume.permissions.owner;
                      group = toString volume.permissions.group;
                      mode = volume.permissions.mode;
                    };
                  };
                };
              };
            };
        in
        {
          nixosModule = {
            imports = [
            ]
            ++ (lib.pipe volumes [
              (lib.filter (volume: builtins.hasAttr "directory" volume.driver))
              (lib.map mkDirectoryVolume)
            ]);
          };
        };

      hostSubmodule = { name, config, ... }: {
        config =
          let
            configs = lib.flatten (
              [ ]
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
          volumes = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (lib.types.submodule volumeSubmodule);
            description = "Persistent volumes mounted into this jail.";
          };
        };
      };
    in
    {
      options = {
        hosts = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
        };

        jails = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule jailSubmodule);
        };
      };

      config = { };
    };
}
