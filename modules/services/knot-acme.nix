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
          gateway = lib.mkOption {
            type = lib.types.str;
          };
          endpoint = lib.mkOption {
            type = lib.types.str;
            readOnly = true;
            default = "knot-acme-${name}";
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
          jailName = "knot-acme-${srvName}-${srv.host}";

          handledChallenges = lib.unique (
            lib.filter (c: builtins.elem c.domain.zone srv.zones) alloy.dns.acmeChallenges
          );

          parentZones = srv.zones;

          getParentApex = p: "${lib.removeSuffix "." alloy.dns.zones."${p}".apex}.";

          getSubzoneId = p: "${srvName}-${p}-subzone";
          getSubzoneApex =
            p: "${alloy.dns.zones."${p}".acmeChallenge.subzone}.${lib.removeSuffix "." (getParentApex p)}";

          cnameRecords = lib.map (
            c:
            let
              cnameFrom = "_acme-challenge${lib.optionalString (c.domain.name != "@") ".${c.domain.name}"}";
              cnameTo = "_acme-challenge.${
                lib.optionalString (c.domain.name != "@") "${lib.removeSuffix "." c.domain.name}."
              }${alloy.dns.zones."${c.domain.zone}".acmeChallenge.subzone}";
            in
            {
              domain = {
                zone = c.domain.zone;
                name = cnameFrom;
              };
              data.cname = cnameTo;
            }
          ) handledChallenges;

          parentDelegationRecords = lib.flatten (
            lib.map (
              p:
              [ ]
              ++ (lib.pipe alloy.gateways.${srv.gateway}.dns.entrypoints [
                (lib.mapAttrsToList (entrypointName: entrypoint: { inherit entrypointName entrypoint; }))
                (lib.imap1 (
                  entrypointIdx:
                  { entrypointName, entrypoint }:
                  let
                    nsFqdn = "ns${toString entrypointIdx}.${
                      lib.removeSuffix "." alloy.dns.zones."${p}".acmeChallenge.subzone
                    }";
                  in
                  [
                    {
                      domain = {
                        zone = p;
                        name = alloy.dns.zones."${p}".acmeChallenge.subzone;
                      };
                      data.ns = nsFqdn;
                    }
                  ]
                  ++ (lib.optional (entrypoint.ipv4 != null) {
                    domain = {
                      zone = p;
                      name = nsFqdn;
                    };
                    data.a = entrypoint.ipv4;
                  })
                  ++ (lib.optional (entrypoint.ipv6 != null) {
                    domain = {
                      zone = p;
                      name = nsFqdn;
                    };
                    data.aaaa = entrypoint.ipv6;
                  })
                ))
                lib.flatten
              ])
            ) parentZones
          );

        in
        {
          assertions = [
            {
              assertion = srv.overlays != { };
              message = "[Alloy] Service 'knot-acme.${srvName}': When 'gateway' is configured, you must specify at least one network overlay in 'overlays' for the endpoint targets.";
            }
            {
              assertion = builtins.hasAttr srv.gateway alloy.gateways;
              message = "[Alloy] Service 'knot-acme.${srvName}': gateway '${srv.gateway}' is unknown. Please ensure it is defined in 'config.gateways'.";
            }
            {
              assertion = builtins.hasAttr srv.host alloy.hosts;
              message = "[Alloy] Service 'knot-acme.${srvName}': host '${srv.host}' is unknown. Please ensure it is defined in 'config.hosts'.";
            }
          ]
          ++ (lib.map (p: {
            assertion = builtins.hasAttr p alloy.dns.zones;
            message = "[Alloy] Service 'knot-acme.${srvName}': Zone '${p}' specified in 'zones' is unknown. Please ensure it is defined in 'config.dns.zones'.";
          }) parentZones)
          ++ (lib.map (p: {
            assertion = (alloy.dns.zones.${p}.acmeChallenge.enable or true) != false;
            message = "[Alloy] Service 'knot-acme.${srvName}': Zone '${p}' has acmeChallenge.enable = false, but is assigned to this service.";
          }) parentZones)
          ++ (lib.pipe parentZones [
            (lib.filter (z: builtins.hasAttr z alloy.dns.zones))
            (builtins.groupBy (z: alloy.dns.zones.${z}.apex))
            (lib.mapAttrsToList (
              apex: zones: {
                assertion = builtins.length zones == 1;
                message = "[Alloy] Service 'knot-acme.${srvName}': Cannot serve zones [ ${lib.concatStringsSep ", " zones} ] simultaneously because they share the same apex '${apex}'.";
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

          gateways.${srv.gateway}.dns.routes."knot-acme-${srvName}" = {
            suffixes = lib.map (
              p: "${lib.removeSuffix "." alloy.dns.zones."${p}".acmeChallenge.subzone}.${getParentApex p}"
            ) parentZones;
            upstream.endpoint = srv.endpoint;
          };

          dns.zones = lib.listToAttrs (
            lib.map (
              p:
              lib.nameValuePair p {
                acmeChallenge.enable = true;
                acmeChallenge.endpoint = srv.endpoint;
              }
            ) parentZones
          )
          ;
          # // lib.listToAttrs (
          #   lib.map (
          #     p:
          #     lib.nameValuePair "${p}-acme" {
          #       apex = "${getSubzoneApex p}.";
          #       nameservers = lib.pipe alloy.gateways.${srv.gateway}.dns.entrypoints [
          #         (lib.mapAttrsToList (
          #           _: e: [ ] ++ (lib.optional (e.ipv4 != null) e.ipv4) ++ (lib.optional (e.ipv6 != null) e.ipv6)
          #         ))
          #         lib.flatten
          #       ];
          #     }
          #   ) parentZones
          # );

          dns.records = cnameRecords ++ parentDelegationRecords;
          secrets = lib.listToAttrs (lib.map (c: lib.nameValuePair c.tsigKeySecret { }) handledChallenges);

          jails.${jailName} =
            { config, ... }:
            let
              jail = config;
            in
            {
              host = srv.host;

              static-ca.domains = [
                alloy.endpoints.${srv.endpoint}.domain
              ];

              overlays = lib.mapAttrs (_: _: { }) srv.overlays;

              secrets = lib.listToAttrs (lib.map (c: lib.nameValuePair c.tsigKeySecret { }) handledChallenges);

              secretTemplates = lib.listToAttrs (
                lib.map (
                  c:
                  lib.nameValuePair c.tsigKeySecret {
                    permissions = {
                      owner = "knot";
                      group = "knot";
                      mode = "0400";
                    };
                    template = ''
                      key:
                        - id: ${alloy.dns.mkTsigKeyId c.tsigKeySecret}
                          algorithm: hmac-sha256
                          secret: ${jail.secrets.${c.tsigKeySecret}.placeholder}
                    '';
                  }
                ) handledChallenges
              );

              nixosModule = { pkgs, ... }: {
                networking.firewall.allowedUDPPorts = [ 53 ];
                networking.firewall.allowedTCPPorts = [ 53 ];

                services.knot = {
                  enable = true;
                  keyFiles = lib.map (c: jail.secretTemplates.${c.tsigKeySecret}.path) handledChallenges;
                  settings = {
                    server.listen = [
                      "127.0.0.1@5353"
                      "::1@5353"
                    ]
                    ++ (lib.mapAttrsToList (_: overlay: "${overlay.ipv6}@53") jail.overlays);
                    acl = lib.listToAttrs (
                      lib.map (
                        c:
                        lib.nameValuePair "acl_tsig_${c.tsigKeySecret}" {
                          key = alloy.dns.mkTsigKeyId c.tsigKeySecret;
                          action = "update";
                          update-type = "TXT";
                          update-owner = "name";
                          update-owner-match = "equal";
                          update-owner-name = lib.pipe handledChallenges [
                            (lib.filter (ch: ch.tsigKeySecret == c.tsigKeySecret))
                            (lib.map (
                              ch:
                              "_acme-challenge.${
                                lib.optionalString (ch.domain.name != "@") "${lib.removeSuffix "." ch.domain.name}."
                              }${getSubzoneApex ch.domain.zone}."
                            ))
                            lib.unique
                          ];
                        }
                      ) handledChallenges
                    );
                    zone = lib.genAttrs' parentZones (
                      p:
                      let
                        zoneAcl = lib.pipe handledChallenges [
                          (lib.filter (c: c.domain.zone == p))
                          (lib.map (c: "acl_tsig_${c.tsigKeySecret}"))
                          lib.unique
                        ];
                      in
                      lib.nameValuePair (getSubzoneApex p) (
                        {
                          file = "/var/lib/knot/${getSubzoneId p}.zone";
                        }
                        // lib.optionalAttrs (builtins.length zoneAcl > 0) {
                          acl = zoneAcl;
                        }
                      )
                    );
                  };
                };

                systemd.services.knot.preStart = lib.concatMapStringsSep "\n" (
                  p:
                  let
                    szId = getSubzoneId p;
                    szApex = getSubzoneApex p;
                    rname = lib.removeSuffix "." alloy.dns.zones."${p}".rname;
                    nsRecords = lib.concatStringsSep "\n" (
                      lib.pipe alloy.gateways.${srv.gateway}.dns.entrypoints [
                        (lib.mapAttrsToList (_: e: e))
                        (lib.imap1 (
                          idx: e:
                          "@ IN NS ns${toString idx}\n"
                          + (lib.optionalString (e.ipv4 != null) "ns${toString idx} IN A ${e.ipv4}\n")
                          + (lib.optionalString (e.ipv6 != null) "ns${toString idx} IN AAAA ${e.ipv6}")
                        ))
                      ]
                    );
                    bootstrapContent = ''
                      $ORIGIN ${szApex}.
                      $TTL 3600
                      @ IN SOA ns1 ${rname}. 1 3600 1800 604800 600
                      ${nsRecords}
                    '';
                    bootstrapFile = pkgs.writeText "${szId}-bootstrap.zone" bootstrapContent;
                  in
                  ''
                    if [ ! -f /var/lib/knot/${szId}.zone ]; then
                      cp ${bootstrapFile} /var/lib/knot/${szId}.zone
                      chmod 0644 /var/lib/knot/${szId}.zone
                    fi
                  ''
                ) parentZones;
              };
            };
        };

      services = lib.pipe alloy.services.knot-acme [
        (lib.filterAttrs (_: s: s.enable))
        (lib.mapAttrsToList mkService)
      ];
    in
    {
      options.services.knot-acme = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule serviceSubmodule);
      };

      config = {
        assertions = lib.mkMerge (lib.map (c: c.assertions) services);
        dns.zones = lib.mkMerge (lib.map (c: c.dns.zones) services);
        dns.records = lib.mkMerge (lib.map (c: c.dns.records) services);
        endpoints = lib.mkMerge (lib.map (c: c.endpoints) services);
        secrets = lib.mkMerge (lib.map (c: c.secrets) services);
        gateways = lib.mkMerge (lib.map (c: c.gateways) services);
        jails = lib.mkMerge (lib.map (c: c.jails) services);
      };
    };
}
