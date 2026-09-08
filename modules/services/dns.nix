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
      gateway = lib.mkOption {
        type = lib.types.str;
      };
      endpoint = lib.mkOption {
        readOnly = true;
        type = lib.types.str;
        default = "dns-${name}";
      };
      zones = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule { });
      };
      hosts = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              host = lib.mkOption {
                type = lib.types.str;
              };
            };
          }
        );
      };
      overlays = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule { });
      };
    };
  };

  mkService =
    srvName: srv:
    let
      zoneRecords = lib.flatten (
        lib.mapAttrsToList (
          z: _:
          [
            {
              node = {
                zone = z;
                name = "@";
              };
              data.soa = {
                mname = "ns1";
                rname = "${lib.removeSuffix "." alloy.dns.zones.${z}.rname}.";
                serial = 1;
                refresh = 3600;
                retry = 1800;
                expire = 604800;
                minimum = 600;
              };
            }
          ]
          ++ (lib.pipe alloy.gateways.${srv.gateway}.dns.entrypoints [
            (lib.mapAttrsToList (entrypointName: entrypoint: { inherit entrypointName entrypoint; }))
            (lib.imap1 (
              entrypointIdx:
              { entrypointName, entrypoint }:
              let
                nsFqdn = "ns${toString entrypointIdx}";
              in
              [
                {
                  node = {
                    zone = z;
                    name = "@";
                  };
                  data.ns = nsFqdn;
                }
              ]
              ++ (lib.optional (entrypoint.ipv4 != null) {
                node = {
                  zone = z;
                  name = nsFqdn;
                };
                data.a = entrypoint.ipv4;
              })
              ++ (lib.optional (entrypoint.ipv6 != null) {
                node = {
                  zone = z;
                  name = nsFqdn;
                };
                data.aaaa = entrypoint.ipv6;
              })
            ))
            lib.flatten
          ])
        ) srv.zones
      );
    in
    {
      assertions = [
        {
          assertion = srv.enable -> srv.overlays != { };
          message = "[Alloy] Service 'dns.${srvName}': You must specify at least one network overlay in 'overlays' for the endpoint targets.";
        }
        {
          assertion = srv.enable -> builtins.hasAttr srv.gateway alloy.gateways;
          message = "[Alloy] Service 'dns.${srvName}': gateway '${srv.gateway}' is unknown. Please ensure it is defined in 'config.gateways'.";
        }
      ]
      ++ (lib.mapAttrsToList (hostName: _: {
        assertion = srv.enable -> builtins.hasAttr hostName alloy.hosts;
        message = "[Alloy] Service 'dns.${srvName}': host '${hostName}' is unknown. Please ensure it is defined in 'config.hosts'.";
      }) srv.hosts)
      ++ (lib.mapAttrsToList (z: _: {
        assertion = srv.enable -> builtins.hasAttr z alloy.dns.zones;
        message = "[Alloy] Service 'dns.${srvName}': Zone '${z}' specified in 'zones' is unknown. Please ensure it is defined in 'config.dns.zones'.";
      }) srv.zones);

      endpoints = lib.mkIf srv.enable {
        ${srv.endpoint}.targets = lib.flatten (
          lib.mapAttrsToList (
            hostName: _:
            let
              jailName = "dns-${srvName}-${hostName}";
            in
            lib.mapAttrsToList (overlayName: overlay: {
              ipv6 = alloy.jails.${jailName}.overlays.${overlayName}.ipv6;
              overlay = overlayName;
              port = 53;
            }) srv.overlays
          ) srv.hosts
        );
      };

      gateways = lib.mkIf srv.enable {
        ${srv.gateway}.dns.routes."dns-${srvName}" = {
          suffixes = lib.mapAttrsToList (z: _: alloy.dns.zones.${z}.apex) srv.zones;
          endpoint = srv.endpoint;
        };
      };

      dns.records = lib.mkIf srv.enable zoneRecords;

      jails = lib.mkIf srv.enable (
        lib.mapAttrs' (
          hostName: _:
          let
            jailName = "dns-${srvName}-${hostName}";
          in
          lib.nameValuePair jailName (
            { config, ... }:
            let
              jail = config;
            in
            {
              host = hostName;

              uplink = {
                allowEgress = true;
              };

              overlays = lib.mapAttrs (_: _: { }) srv.overlays;

              nixosModule = { pkgs, ... }: {
                networking.firewall.allowedUDPPorts = [ 53 ];
                networking.firewall.allowedTCPPorts = [ 53 ];

                services.knot = {
                  enable = true;
                  settings = {
                    server.listen = [
                      "127.0.0.1@53"
                    ]
                    ++ (lib.mapAttrsToList (_: overlay: "${overlay.ipv6}@53") jail.overlays);
                    zone = lib.mapAttrs' (
                      z: _:
                      lib.nameValuePair alloy.dns.zones.${z}.apex {
                        file = pkgs.writeText "${z}.zone" alloy.dns.zones.${z}.bindConfig;
                      }
                    ) srv.zones;
                  };
                };
              };
            }
          )
        ) srv.hosts
      );
    };

  services = lib.pipe alloy.services.dns [
    (lib.filterAttrs (_: s: s.enable))
    (lib.mapAttrsToList mkService)
  ];
in
{
  options.services.dns = lib.mkOption {
    default = { };
    type = lib.types.attrsOf (lib.types.submodule serviceSubmodule);
  };

  config = {
    assertions = lib.mkMerge (lib.map (c: c.assertions) services);
    dns.records = lib.mkMerge (lib.map (c: c.dns.records) services);
    endpoints = lib.mkMerge (lib.map (c: c.endpoints) services);
    gateways = lib.mkMerge (lib.map (c: c.gateways) services);
    jails = lib.mkMerge (lib.map (c: c.jails) services);
  };
}
