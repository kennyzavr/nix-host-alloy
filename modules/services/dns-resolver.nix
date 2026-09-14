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
          host = lib.mkOption {
            type = lib.types.str;
          };
          overlays = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (lib.types.submodule { });
          };
          endpoint = lib.mkOption {
            readOnly = true;
            type = lib.types.str;
            default = "dns-resolver-${name}";
          };
        };
      };

      mkService =
        srvName: srv:
        let
          jailName = "dns-resolver-${srvName}-${srv.host}";
        in
        {
          assertions = [
            {
              assertion = builtins.hasAttr srv.host alloy.hosts;
              message = "[Alloy] Service 'dns-resolver.${srvName}': host '${srv.host}' is unknown. Please ensure it is defined in 'config.hosts'.";
            }
            {
              assertion = srv.overlays != { };
              message = "[Alloy] Service 'dns-resolver.${srvName}': You must specify at least one network overlay in 'overlays'.";
            }
          ];

          endpoints.${srv.endpoint} = {
            port = 53;
            targets = lib.flatten (
              lib.mapAttrsToList (overlayName: overlay: {
                ipv6 = alloy.jails.${jailName}.overlays.${overlayName}.ipv6;
                overlay = overlayName;
              }) srv.overlays
            );
          };

          dns.resolvers = [
            {
              endpoint = srv.endpoint;
            }
          ];

          jails = {
            ${jailName} = { config, pkgs, ... }: {
              host = srv.host;

              uplink.allowEgress = true;

              endpoints.${srv.endpoint} = { };

              overlays = lib.mapAttrs (_: _: { }) srv.overlays;

              nixosModule = {
                networking.firewall.allowedUDPPorts = [ 53 ];
                networking.firewall.allowedTCPPorts = [ 53 ];
                services.coredns.enable = lib.mkForce false;

                services.knot-resolver = {
                  enable = true;
                  settings = {
                    network.listen = [
                      {
                        interface = [
                          "127.0.0.1"
                          "::1"
                        ]
                        ++ (lib.mapAttrsToList (_: overlay: overlay.ipv6) config.overlays);
                        port = 53;
                      }
                    ];

                    forward = lib.mapAttrsToList (zName: zone: {
                      subtree = [ "${lib.removeSuffix "." zone.apex}." ];
                      servers = zone.nameservers;
                      options = {
                        authoritative = true;
                        dnssec = false;
                      };
                    }) (lib.filterAttrs (_: zone: zone.nameservers != [ ]) alloy.dns.zones);
                  };
                };
              };
            };
          };
        };

      services = lib.pipe alloy.services.dns-resolver [
        (lib.filterAttrs (_: s: s.enable))
        (lib.mapAttrsToList mkService)
      ];
    in
    {
      options.services.dns-resolver = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule serviceSubmodule);
      };

      config = {
        assertions = lib.mkMerge (lib.map (c: c.assertions) services);
        jails = lib.mkMerge (lib.map (c: c.jails) services);
        dns = lib.mkMerge (lib.map (c: c.dns) services);
        endpoints = lib.mkMerge (lib.map (c: c.endpoints) services);
      };
    };
}
