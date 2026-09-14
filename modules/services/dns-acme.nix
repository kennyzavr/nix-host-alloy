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
            type = lib.types.str;
            readOnly = true;
            default = "dns-acme-${name}";
          };
          host = lib.mkOption {
            type = lib.types.str;
          };
          zones = lib.mkOption {
            default = [ ];
            type = lib.types.listOf lib.types.str;
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
          jailName = "dns-acme-${srvName}-${srv.host}";

          dnsupdateCerts = lib.pipe alloy.tls.certs [
            (lib.filterAttrs (
              _: cert: cert.src ? acme && cert.src.acme.challenge ? dns && cert.src.acme.challenge.dns ? dnsupdate
            ))
            (lib.mapAttrsToList (certName: cert: cert // { name = certName; }))
          ];

          requests = lib.flatten (
            lib.flip lib.map srv.zones (
              acmeZone:
              lib.flip lib.map dnsupdateCerts (
                cert:
                lib.flip lib.map cert.domains (
                  certDomain:
                  let
                    zone = alloy.dns.zones.${acmeZone}.parentZone;
                  in
                  lib.optionals (certDomain.zone == zone) [
                    {
                      inherit
                        acmeZone
                        certDomain
                        ;
                      tsigKey = cert.src.acme.challenge.dns.dnsupdate.tsigKey;
                    }
                  ]
                )
              )
            )
          );
        in
        {
          assertions = [
            {
              assertion = srv.overlays != { };
              message = "[Alloy] Service 'dns-acme.${srvName}': you must specify at least one network overlay in 'overlays' for the endpoint targets.";
            }
            {
              assertion = builtins.hasAttr srv.host alloy.hosts;
              message = "[Alloy] Service 'dns-acme.${srvName}': host '${srv.host}' is unknown. Please ensure it is defined in 'config.hosts'.";
            }
          ]
          ++ (lib.pipe srv.zones [
            (lib.filter (z: builtins.hasAttr z alloy.dns.zones))
            (builtins.groupBy (z: alloy.dns.zones.${z}.apex))
            (lib.mapAttrsToList (
              apex: zones: {
                assertion = builtins.length zones == 1;
                message = "[Alloy] Service 'dns-acme.${srvName}': Cannot serve zones [ ${lib.concatStringsSep ", " zones} ] simultaneously because they share the same apex '${apex}'.";
              }
            ))
          ]);

          endpoints.${srv.endpoint} = {
            port = 53;
            targets = lib.mapAttrsToList (overlayName: overlay: {
              ipv6 = alloy.jails.${jailName}.overlays.${overlayName}.ipv6;
              overlay = overlayName;
            }) srv.overlays;
          };

          # dns.zones = lib.genAttrs' srv.zones (
          #   zone:
          #   lib.nameValuePair alloy.dns.zones.${zone}.parentZone {
          #     acme.server.endpoint = srv.endpoint;
          #   }
          # );

          dns.records =
            (lib.flip lib.map requests (req: {
              domain = alib.extendZoneNode req.certDomain "_acme-challenge";
              data.cname = alloy.dns.resolveNode (
                alib.extendZoneNode {
                  zone = req.acmeZone;
                  name = req.certDomain.name;
                } "_acme-challenge"
              );
            }))
            ++ (lib.flip lib.map srv.zones (zone: {
              domain = {
                inherit zone;
                name = "@";
              };
              data.soa = {
                mname = "${lib.removeSuffix "." alloy.dns.zones.${zone}.nname}.";
                rname = "${lib.removeSuffix "." alloy.dns.zones.${zone}.rname}.";
                serial = 1;
                refresh = 3600;
                retry = 1800;
                expire = 604800;
                minimum = 0;
              };
            }));

          secrets = lib.pipe requests [
            (lib.map (req: lib.nameValuePair req.tsigKey.secret { }))
            builtins.listToAttrs
          ];

          generators.instances = lib.pipe requests [
            (lib.map (
              req:
              lib.nameValuePair req.tsigKey.generator {
                imports = [ alloy.generators.templates."dns/tsig-key" ];
                keySecret = req.tsigKey.secret;
                tags = [
                  "dns-acme"
                  "dns-acme/${srvName}"
                ];
              }
            ))
            builtins.listToAttrs
          ];

          jails.${jailName} =
            { config, ... }:
            let
              jail = config;
            in
            {
              host = srv.host;

              overlays = lib.mapAttrs (_: _: { }) srv.overlays;

              endpoints.${srv.endpoint} = { };

              secrets = lib.pipe requests [
                (lib.map (req: lib.nameValuePair req.tsigKey.secret { }))
                builtins.listToAttrs
              ];

              secretTemplates = builtins.listToAttrs (
                lib.flip lib.map requests (
                  req:
                  lib.nameValuePair req.tsigKey.secret {
                    permissions = {
                      owner = "knot";
                      group = "knot";
                      mode = "0400";
                    };
                    template = ''
                      key:
                        - id: ${req.tsigKey.name}
                          algorithm: ${lib.removeSuffix "." req.tsigKey.alg}
                          secret: ${lib.removeSuffix "\n" jail.secrets.${req.tsigKey.secret}.placeholder}
                    '';
                  }
                )
              );

              nixosModule = { pkgs, ... }: {
                networking.firewall.allowedUDPPorts = [ 53 ];
                networking.firewall.allowedTCPPorts = [ 53 ];

                services.knot = {
                  enable = true;
                  keyFiles = lib.flip lib.map requests (req: jail.secretTemplates.${req.tsigKey.secret}.path);
                  settings = {
                    server.listen = [
                      "127.0.0.1@5353"
                      "::1@5353"
                    ]
                    ++ (lib.mapAttrsToList (_: overlay: "${overlay.ipv6}@53") jail.overlays);
                    acl = lib.pipe requests [
                      (lib.map (req: {
                        "${req.tsigKey.name}.acl" = {
                          key = req.tsigKey.name;
                          action = "update";
                          update-type = "TXT";
                          update-owner = "name";
                          update-owner-match = "equal";
                          update-owner-name = lib.singleton (
                            alloy.dns.resolveNode (
                              alib.extendZoneNode {
                                zone = req.acmeZone;
                                name = req.certDomain.name;
                              } "_acme-challenge"
                            )
                          );
                        };
                      }))
                      lib.mkMerge
                    ];
                    zone = lib.pipe srv.zones [
                      (lib.map (
                        zone:
                        lib.nameValuePair alloy.dns.zones.${zone}.apex (
                          let
                            acl = lib.pipe requests [
                              (lib.filter (req: req.acmeZone == zone))
                              (lib.map (req: "${req.tsigKey.name}.acl"))
                            ];
                          in
                          {
                            file = "/var/lib/knot/${zone}.zone";
                          }
                          // (lib.optionalAttrs (acl != [ ]) {
                            inherit acl;
                          })
                        )
                      ))
                      builtins.listToAttrs
                    ];
                  };
                };

                systemd.services.knot.preStart = lib.concatMapStringsSep "\n" (
                  zone:
                  let
                    bootstrapContent = alloy.dns.zones.${zone}.bindConfig;
                    bootstrapFile = pkgs.writeText "${zone}-bootstrap.zone" bootstrapContent;
                  in
                  ''
                    if [ ! -f /var/lib/knot/${zone}.zone ]; then
                      cp ${bootstrapFile} /var/lib/knot/${zone}.zone
                      chmod 0644 /var/lib/knot/${zone}.zone
                    fi
                  ''
                ) srv.zones;
              };
            };
        };

      services = lib.pipe alloy.services.dns-acme [
        (lib.filterAttrs (_: s: s.enable))
        (lib.mapAttrsToList mkService)
      ];
    in
    {
      options.services.dns-acme = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule serviceSubmodule);
      };

      config = {
        assertions = lib.mkMerge (lib.map (c: c.assertions) services);
        # dns.zones = lib.mkMerge (lib.map (c: c.dns.zones) services);
        dns.records = lib.mkMerge (lib.map (c: c.dns.records) services);
        endpoints = lib.mkMerge (lib.map (c: c.endpoints) services);
        secrets = lib.mkMerge (lib.map (c: c.secrets) services);
        generators = lib.mkMerge (lib.map (c: c.generators) services);
        jails = lib.mkMerge (lib.map (c: c.jails) services);
      };
    };
}
