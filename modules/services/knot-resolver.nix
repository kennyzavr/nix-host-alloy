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
        };
      };

      activeServices = lib.filterAttrs (_: s: s.enable) alloy.services.knot-resolver;

      nodeSubmodule =
        type:
        { config, name, ... }:
        let
          node = config;
          resolverIps = lib.flatten (
            lib.mapAttrsToList (
              srvName: srv:
              let
                jailName = "knot-resolver-${srvName}-${srv.host}";
                resolverJail = alloy.jails.${jailName};
                commonOverlays = lib.intersectAttrs node.overlays srv.overlays;
              in
              lib.mapAttrsToList (oName: _: resolverJail.overlays.${oName}.ipv6) commonOverlays
            ) activeServices
          );
        in
        {
          dns = lib.mkIf (resolverIps != [ ]) {
            upstreamResolvers = lib.mkBefore resolverIps;
          };
        };

      mkService =
        srvName: srv:
        let
          jailName = "knot-resolver-${srvName}-${srv.host}";
        in
        {
          assertions = [
            {
              assertion = srv.enable -> builtins.hasAttr srv.host alloy.hosts;
              message = "[Alloy] Service 'knot-resolver.${srvName}': host '${srv.host}' is unknown. Please ensure it is defined in 'config.hosts'.";
            }
            {
              assertion = srv.enable -> srv.overlays != { };
              message = "[Alloy] Service 'knot-resolver.${srvName}': You must specify at least one network overlay in 'overlays'.";
            }
          ];

          jails = {
            ${jailName} = { config, pkgs, ... }: {
              host = srv.host;

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
                      subtree = [ "${zone.apex}." ];
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

      services = lib.mapAttrsToList mkService activeServices;
    in
    {
      options.services.knot-resolver = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule serviceSubmodule);
      };

      options.hosts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule (nodeSubmodule "host"));
      };

      options.jails = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule (nodeSubmodule "jail"));
      };

      config = {
        assertions = lib.mkMerge (lib.map (c: c.assertions) services);
        jails = lib.mkMerge (lib.map (c: c.jails) services);
      };
    };
}
