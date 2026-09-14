{
  flake.alloyModules.services =
    {
      alib,
      lib,
      config,
      ...
    }:
    let
      alloy = config;

      serviceSubmodule = { config, name, ... }: {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
          endpoint = lib.mkOption {
            readOnly = true;
            type = lib.types.str;
            default = "dns-auth-${name}";
          };
          zones = lib.mkOption {
            default = [ ];
            type = lib.types.listOf lib.types.str;
          };
          hosts = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (lib.types.submodule { });
          };
          overlays = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (lib.types.submodule { });
          };
        };
      };

      mkService = srvName: srv: {
        assertions = [
          {
            assertion = srv.overlays != { };
            message = "[Alloy] Service 'dns-auth.${srvName}': You must specify at least one network overlay in 'overlays' for the endpoint targets.";
          }
        ]
        ++ (lib.mapAttrsToList (hostName: _: {
          assertion = builtins.hasAttr hostName alloy.hosts;
          message = "[Alloy] Service 'dns-auth.${srvName}': host '${hostName}' is unknown. Please ensure it is defined in 'config.hosts'.";
        }) srv.hosts)
        ++ (lib.pipe srv.zones [
          (lib.filter (z: builtins.hasAttr z alloy.dns.zones))
          (builtins.groupBy (z: alloy.dns.zones.${z}.apex))
          (lib.mapAttrsToList (
            apex: zones: {
              assertion = builtins.length zones == 1;
              message = "[Alloy] Service 'dns-auth.${srvName}': Cannot serve zones [ ${lib.concatStringsSep ", " zones} ] simultaneously because they share the same apex '${apex}'.";
            }
          ))
        ]);

        endpoints.${srv.endpoint} = {
          port = 53;
          targets = lib.flatten (
            lib.mapAttrsToList (
              hostName: _:
              let
                jailName = "dns-auth-${srvName}-${hostName}";
              in
              lib.mapAttrsToList (overlayName: overlay: {
                ipv6 = alloy.jails.${jailName}.overlays.${overlayName}.ipv6;
                overlay = overlayName;
              }) srv.overlays
            ) srv.hosts
          );
        };

        dns.records = lib.map (z: {
          domain = {
            zone = z;
            name = "@";
          };
          data.soa = {
            mname = "${lib.removeSuffix "." alloy.dns.zones.${z}.nname}.";
            rname = "${lib.removeSuffix "." alloy.dns.zones.${z}.rname}.";
            serial = 1;
            refresh = 3600;
            retry = 1800;
            expire = 604800;
            minimum = 600;
          };
        }) srv.zones;

        jails = lib.mapAttrs' (
          hostName: _:
          let
            jailName = "dns-auth-${srvName}-${hostName}";
          in
          lib.nameValuePair jailName (
            { config, ... }:
            let
              jail = config;
            in
            {
              host = hostName;

              endpoints.${srv.endpoint} = { };

              overlays = lib.mapAttrs (_: _: { }) srv.overlays;

              nixosModule = { pkgs, ... }: {
                networking.firewall.allowedUDPPorts = [ 53 ];
                networking.firewall.allowedTCPPorts = [ 53 ];

                services.knot = {
                  enable = true;
                  settings = {
                    server.listen = [
                      "127.0.0.1@5353"
                      "::1@5353"
                    ]
                    ++ (lib.mapAttrsToList (_: overlay: "${overlay.ipv6}@53") jail.overlays);
                    zone = lib.listToAttrs (
                      lib.map (
                        z:
                        lib.nameValuePair alloy.dns.zones.${z}.apex {
                          file = pkgs.writeText "${z}.zone" alloy.dns.zones.${z}.bindConfig;
                        }
                      ) srv.zones
                    );
                  };
                };
              };
            }
          )
        ) srv.hosts;
      };

      services = lib.pipe alloy.services.dns-auth [
        (lib.filterAttrs (_: s: s.enable))
        (lib.mapAttrsToList mkService)
      ];
    in
    {
      options.services.dns-auth = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule serviceSubmodule);
      };

      config = {
        assertions = lib.mkMerge (lib.map (c: c.assertions) services);
        endpoints = lib.mkMerge (lib.map (c: c.endpoints) services);
        dns = lib.mkMerge (lib.map (c: c.dns) services);
        jails = lib.mkMerge (lib.map (c: c.jails) services);
      };
    };
}
