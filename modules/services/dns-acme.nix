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
      subzone = lib.mkOption {
        type = alib.types.dns.name;
        default = "acme";
      };
      gateway = lib.mkOption {
        type = lib.types.str;
      };
      endpoint = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "dns-acme-${name}";
      };
      domains = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              zone = lib.mkOption { type = lib.types.str; };
              name = lib.mkOption { type = lib.types.either alib.types.dns.name (lib.types.enum [ "@" ]); };
              tsigSecret = lib.mkOption {
                type = lib.types.str;
                default = "dns-acme-${name}-tsig";
              };
            };
          }
        );
        default = [ ];
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

  mkService =
    srvName: srv:
    let
      jailName = "dns-acme-${srvName}-${srv.host}";

      uniqueTsigSecrets = lib.unique (lib.map (d: d.tsigSecret) srv.domains);

      uniqueParentZones = lib.unique (lib.map (d: d.zone) srv.domains);

      getParentApex = p: "${lib.removeSuffix "." alloy.dns.zones."${p}".apex}.";

      getSubzoneId = p: "${srvName}-${p}-subzone";
      getSubzoneApex = p: "${srv.subzone}.${lib.removeSuffix "." (getParentApex p)}";

      cnameRecords = lib.map (
        node:
        let
          cnameFrom = "_acme-challenge${lib.optionalString (node.name != "@") ".${node.name}"}";
          cnameTo = "_acme-challenge.${
            lib.optionalString (node.name != "@") "${lib.removeSuffix "." node.name}."
          }${srv.subzone}";
        in
        {
          node = {
            zone = node.zone;
            name = cnameFrom;
          };
          data.cname = cnameTo;
        }
      ) srv.domains;

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
                nsFqdn = "ns${toString entrypointIdx}.${lib.removeSuffix "." srv.subzone}";
              in
              [
                {
                  node = {
                    zone = p;
                    name = srv.subzone;
                  };
                  data.ns = nsFqdn;
                }
              ]
              ++ (lib.optional (entrypoint.ipv4 != null) {
                node = {
                  zone = p;
                  name = nsFqdn;
                };
                data.a = entrypoint.ipv4;
              })
              ++ (lib.optional (entrypoint.ipv6 != null) {
                node = {
                  zone = p;
                  name = nsFqdn;
                };
                data.aaaa = entrypoint.ipv6;
              })
            ))
            lib.flatten
          ])
        ) uniqueParentZones
      );

      subzoneRecords = lib.flatten (
        lib.map (
          p:
          let
            szId = getSubzoneId p;
          in
          [
            {
              node = {
                zone = szId;
                name = "@";
              };
              data.soa = {
                mname = "ns1";
                rname = "${lib.removeSuffix "." alloy.dns.zones."${p}".rname}.";
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
                    zone = szId;
                    name = "@";
                  };
                  data.ns = nsFqdn;
                }
              ]
              ++ (lib.optional (entrypoint.ipv4 != null) {
                node = {
                  zone = szId;
                  name = nsFqdn;
                };
                data.a = entrypoint.ipv4;
              })
              ++ (lib.optional (entrypoint.ipv6 != null) {
                node = {
                  zone = szId;
                  name = nsFqdn;
                };
                data.aaaa = entrypoint.ipv6;
              })
            ))
            lib.flatten
          ])
        ) uniqueParentZones
      );

      newZones = lib.listToAttrs (
        lib.map (
          p:
          lib.nameValuePair (getSubzoneId p) {
            apex = getSubzoneApex p;
          }
        ) uniqueParentZones
      );
    in
    {
      assertions = [
        {
          assertion = srv.enable -> srv.overlays != { };
          message = "[Alloy] Service 'dns-acme.${srvName}': When 'gateway' is configured, you must specify at least one network overlay in 'overlays' for the endpoint targets.";
        }
        {
          assertion = srv.enable -> builtins.hasAttr srv.gateway alloy.gateways;
          message = "[Alloy] Service 'dns-acme.${srvName}': gateway '${srv.gateway}' is unknown. Please ensure it is defined in 'config.gateways'.";
        }
        {
          assertion = srv.enable -> builtins.hasAttr srv.host alloy.hosts;
          message = "[Alloy] Service 'dns-acme.${srvName}': host '${srv.host}' is unknown. Please ensure it is defined in 'config.hosts'.";
        }
      ]
      ++ (lib.map (p: {
        assertion = srv.enable -> builtins.hasAttr p alloy.dns.zones;
        message = "[Alloy] Service 'dns-acme.${srvName}': Zone '${p}' specified in 'domains' is unknown. Please ensure it is defined in 'config.dns.zones'.";
      }) uniqueParentZones)
      ++ (lib.pipe uniqueParentZones [
        (lib.filter (z: builtins.hasAttr z alloy.dns.zones))
        (builtins.groupBy (z: alloy.dns.zones.${z}.apex))
        (lib.mapAttrsToList (
          apex: zones: {
            assertion = srv.enable -> builtins.length zones == 1;
            message = "[Alloy] Service 'dns-acme.${srvName}': Cannot serve zones [ ${lib.concatStringsSep ", " zones} ] simultaneously because they share the same apex '${apex}'.";
          }
        ))
      ]);

      endpoints = lib.mkIf (srv.enable) {
        ${srv.endpoint}.targets = lib.mapAttrsToList (overlayName: overlay: {
          ipv6 = alloy.jails.${jailName}.overlays.${overlayName}.ipv6;
          overlay = overlayName;
          port = 53;
        }) srv.overlays;
      };

      gateways = lib.mkIf (srv.enable) {
        ${srv.gateway}.dns.routes."dns-acme-${srvName}" = {
          suffixes = lib.map (p: "${lib.removeSuffix "." srv.subzone}.${getParentApex p}") uniqueParentZones;
          endpoint = srv.endpoint;
        };
      };

      dns.zones = lib.mkIf srv.enable newZones;
      dns.records = lib.mkIf srv.enable (cnameRecords ++ parentDelegationRecords ++ subzoneRecords);

      generators.instances = lib.mkIf srv.enable {
        "dns-acme-${srvName}-tsig" = {
          imports = [ alloy.generators.templates."dns-tsig-key" ];
          name = "dns-acme-${srvName}-tsig";
        };
      };

      jails.${jailName} = lib.mkIf srv.enable (
        { config, ... }:
        let
          jail = config;
        in
        {
          host = srv.host;

          uplink = {
            allowEgress = true;
          };

          secrets = lib.genAttrs uniqueTsigSecrets (_: { });

          secretTemplates = lib.genAttrs uniqueTsigSecrets (secName: {
            permissions = {
              owner = "knot";
              group = "knot";
              mode = "0400";
            };
            template = ''
              key:
                - id: ${builtins.toJSON secName}
                  algorithm: hmac-sha256
                  secret: ${jail.secrets.${secName}.placeholder}
            '';
          });

          overlays = lib.mapAttrs (_: _: { }) srv.overlays;

          nixosModule = { pkgs, ... }: {
            networking.firewall.allowedUDPPorts = [53];
            networking.firewall.allowedTCPPorts = [53];
            
            services.knot = {
              enable = true;
              keyFiles = lib.map (secName: jail.secretTemplates.${secName}.path) uniqueTsigSecrets;
              settings = {
                server.listen = [
                  "127.0.0.1@53"
                ]
                ++ (lib.mapAttrsToList (_: overlay: "${overlay.ipv6}@53") jail.overlays);
                acl = lib.listToAttrs (
                  lib.map (
                    secName:
                    lib.nameValuePair "acl_tsig_${secName}" {
                      key = secName;
                      action = "update";
                      update-type = "TXT";
                      update-owner = "name";
                      update-owner-match = "equal";
                      update-owner-name = lib.pipe srv.domains [
                        (lib.filter (d: d.tsigSecret == secName))
                        (lib.map (
                          d:
                          "_acme-challenge.${
                            lib.optionalString (d.name != "@") "${lib.removeSuffix "." d.name}."
                          }${getSubzoneApex d.zone}"
                        ))
                        lib.unique
                      ];
                    }
                  ) uniqueTsigSecrets
                );
                zone = lib.genAttrs' uniqueParentZones (
                  p:
                  lib.nameValuePair (getSubzoneApex p) {
                    file = "/var/lib/knot/${getSubzoneId p}.zone";
                    acl = lib.pipe srv.domains [
                      (lib.filter (d: d.zone == p))
                      (lib.map (d: "acl_tsig_${d.tsigSecret}"))
                      lib.unique
                    ];
                  }
                );
              };
            };

            systemd.services.knot.serviceConfig.ExecStartPre = lib.map (
              p:
              let
                szId = getSubzoneId p;
                bootstrapFile = pkgs.writeText "${szId}-bootstrap.zone" alloy.dns.zones.${szId}.bindConfig;
              in
              "+/bin/sh -c 'if [ ! -f /var/lib/knot/${szId}.zone ]; then cp ${bootstrapFile} /var/lib/knot/${szId}.zone; chown knot:knot /var/lib/knot/${szId}.zone; fi'"
            ) uniqueParentZones;
          };
        }
      );
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
    dns.zones = lib.mkMerge (lib.map (c: c.dns.zones) services);
    dns.records = lib.mkMerge (lib.map (c: c.dns.records) services);
    endpoints = lib.mkMerge (lib.map (c: c.endpoints) services);
    gateways = lib.mkMerge (lib.map (c: c.gateways) services);
    generators.instances = lib.mkMerge (lib.map (c: c.generators.instances) services);
    jails = lib.mkMerge (lib.map (c: c.jails) services);

    generators.templates."dns-tsig-key" = { config, ... }: {
      options = {
        name = lib.mkOption { type = lib.types.str; };
      };
      config = {
        secrets.${config.name} = { };
        script = ''
          import os
          import base64
          if not AlloySecretsAPI.exists("${config.name}") or getattr(args, "force", False):
              key_bytes = os.urandom(32)
              key_b64 = base64.b64encode(key_bytes).decode('utf-8')
              
              AlloySecretsAPI.set("${config.name}", key_b64.encode(), force=getattr(args, "force", False), add_to_git=getattr(args, "add_to_git", False))
          else:
              CLI.skip("Secret '${config.name}' already exists. Use --force to overwrite.")
        '';
      };
    };
  };
}
