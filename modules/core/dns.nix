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

      mkAttrsOpt =
        opts:
        lib.mkOption {
          type = lib.types.submodule {
            options = opts;
          };
        };
      mkOpt =
        ty:
        lib.mkOption {
          type = ty;
        };

      recordType = lib.types.submodule (
        { config, ... }: {
          options = {
            domain = lib.mkOption {
              type = alib.types.zoneNode;
            };
            ttl = lib.mkOption {
              default = null;
              type = lib.types.nullOr lib.types.int;
            };
            data = lib.mkOption {
              type = lib.types.attrTag {
                a = mkOpt alib.types.ip.v4addr;
                aaaa = mkOpt alib.types.ip.v6addr;
                cname = mkOpt alib.types.dns.name;
                txt = mkOpt lib.types.str;
                ns = mkOpt alib.types.dns.name;
                ptr = mkOpt alib.types.dns.name;
                mx = mkAttrsOpt {
                  preference = mkOpt lib.types.ints.u16;
                  exchange = mkOpt alib.types.dns.name;
                };
                caa = mkAttrsOpt {
                  flags = mkOpt lib.types.ints.u8;
                  tag = mkOpt (lib.types.strMatching "[a-z0-9]{1,15}");
                  value = mkOpt lib.types.str;
                };
                srv = mkAttrsOpt {
                  priority = mkOpt lib.types.ints.u16;
                  weight = mkOpt lib.types.ints.u16;
                  port = mkOpt lib.types.ints.u16;
                  target = mkOpt alib.types.dns.name;
                };
                soa = mkAttrsOpt {
                  mname = mkOpt alib.types.dns.name;
                  rname = mkOpt alib.types.dns.name;
                  serial = mkOpt lib.types.ints.u32;
                  refresh = mkOpt lib.types.ints.u32;
                  retry = mkOpt lib.types.ints.u32;
                  expire = mkOpt lib.types.ints.u32;
                  minimum = mkOpt lib.types.ints.u32;
                };
                ds = mkAttrsOpt {
                  keyTag = mkOpt lib.types.ints.u16;
                  algorithm = mkOpt lib.types.ints.u8;
                  digestType = mkOpt lib.types.ints.u8;
                  digest = mkOpt (lib.types.strMatching "[0-9a-fA-F]+");
                };
                dnskey = mkAttrsOpt {
                  flags = mkOpt lib.types.ints.u16;
                  protocol = mkOpt lib.types.ints.u8;
                  algorithm = mkOpt lib.types.ints.u8;
                  publicKey = mkOpt lib.types.str;
                };
                sshfp = mkAttrsOpt {
                  algorithm = mkOpt lib.types.ints.u8;
                  type = mkOpt lib.types.ints.u8;
                  fingerprint = mkOpt (lib.types.strMatching "[0-9a-fA-F]+");
                };
                tlsa = mkAttrsOpt {
                  usage = mkOpt lib.types.ints.u8;
                  selector = mkOpt lib.types.ints.u8;
                  matchingType = mkOpt lib.types.ints.u8;
                  certificateAssociationData = mkOpt (lib.types.strMatching "[0-9a-fA-F]+");
                };
                https = mkAttrsOpt {
                  priority = mkOpt lib.types.ints.u16;
                  target = mkOpt (lib.types.either alib.types.dns.name (lib.types.enum [ "." ]));
                  params = mkOpt (lib.types.attrsOf lib.types.str);
                };
                svcb = mkAttrsOpt {
                  priority = mkOpt lib.types.ints.u16;
                  target = mkOpt alib.types.dns.name;
                  params = mkOpt (lib.types.attrsOf lib.types.str);
                };
              };
            };
            bindConfig = lib.mkOption {
              readOnly = true;
              type = lib.types.str;
            };
          };
          config = {
            bindConfig =
              let
                recordKey = builtins.head (builtins.attrNames config.data);
                recordTypeStr = lib.strings.toUpper recordKey;
                d = config.data.${recordKey};
                value =
                  if recordKey == "txt" then
                    let
                      limit = 255;
                      len = builtins.stringLength d;
                      numChunks = (len + limit - 1) / limit;
                      chunks =
                        if numChunks == 0 then
                          [ "" ]
                        else
                          builtins.genList (i: builtins.substring (i * limit) limit d) numChunks;
                    in
                    lib.concatMapStringsSep " " (chunk: ''"${lib.escape [ "\"" "\\" ] chunk}"'') chunks
                  else if recordKey == "caa" then
                    ''${toString d.flags} ${d.tag} "${lib.escape [ "\"" "\\" ] d.value}"''
                  else if recordKey == "mx" then
                    "${toString d.preference} ${d.exchange}"
                  else if recordKey == "srv" then
                    "${toString d.priority} ${toString d.weight} ${toString d.port} ${d.target}"
                  else if recordKey == "soa" then
                    "${d.mname} ${d.rname} ${toString d.serial} ${toString d.refresh} ${toString d.retry} ${toString d.expire} ${toString d.minimum}"
                  else if recordKey == "ds" then
                    "${toString d.keyTag} ${toString d.algorithm} ${toString d.digestType} ${d.digest}"
                  else if recordKey == "dnskey" then
                    "${toString d.flags} ${toString d.protocol} ${toString d.algorithm} ${d.publicKey}"
                  else if recordKey == "sshfp" then
                    "${toString d.algorithm} ${toString d.type} ${d.fingerprint}"
                  else if recordKey == "tlsa" then
                    "${toString d.usage} ${toString d.selector} ${toString d.matchingType} ${d.certificateAssociationData}"
                  else if recordKey == "https" || recordKey == "svcb" then
                    let
                      paramsStr = lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "${k}=\"${v}\"") d.params);
                    in
                    "${toString d.priority} ${d.target} ${paramsStr}"
                  else
                    toString d;
                ttlStr = lib.optionalString (config.ttl != null) "${toString config.ttl} ";
              in
              "${alloy.dns.resolveNode config.domain} ${ttlStr}IN ${recordTypeStr} ${value}";
          };
        }
      );

      acmeChallengeType = lib.types.submodule (
        { config, name, ... }: {
          options = {
            domain = lib.mkOption {
              type = alib.types.zoneNode;
            };
            tsigKeySecret = lib.mkOption {
              type = lib.types.str;
            };
          };
        }
      );

      zoneType = lib.types.submodule (
        { config, name, ... }: {
          options = {
            apex = lib.mkOption {
              type = alib.types.dns.name;
            };
            rname = lib.mkOption {
              type = alib.types.dns.name;
            };
            ttl = lib.mkOption {
              default = 3600;
              type = lib.types.int;
            };
            bindConfig = lib.mkOption {
              readOnly = true;
              type = lib.types.str;
            };
            nameservers = lib.mkOption {
              default = [ ];
              type = lib.types.listOf lib.types.str;
            };
            acmeChallenge = {
              enable = lib.mkOption {
                default = false;
                type = lib.types.bool;
              };
              subzone = lib.mkOption {
                type = alib.types.dns.name;
                default = "acme";
              };
              endpoint = lib.mkOption {
                type = lib.types.str;
              };
            };
          };
          # TODO: choose unique records
          config.bindConfig = ''
            $ORIGIN ${lib.removeSuffix "." config.apex}.
            $TTL ${toString config.ttl}
            ${lib.concatMapStringsSep "\n" (record: record.bindConfig) (
              lib.filter (r: r.domain.zone == name) alloy.dns.records
            )}
          '';
        }
      );

      nodeSubmodule =
        type:
        { name, config, ... }:
        let
          nodeName = name;
        in
        {
          options = {
            overlays = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.submodule (
                  { name, ... }:
                  let
                    oName = name;
                  in
                  {
                    options = {
                      domain = lib.mkOption {
                        type = lib.types.str;
                        readOnly = true;
                      };
                    };
                    config = {
                      domain = "${nodeName}.${type}.${alloy.overlays.${oName}.domain}";
                    };
                  }
                )
              );
            };
            dns = {
              upstreamResolvers = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [
                  "8.8.8.8"
                  "1.1.1.1"
                ];
              };
            };
          };
          config.nixosModule = {
            services.resolved.enable = false;
            services.coredns = {
              enable = true;
              config = ''
                . {
                  bind 127.0.0.1 ::1
                  forward . ${lib.concatStringsSep " " config.dns.upstreamResolvers}
                  cache
                }
                ${alloy.dns.discovery.domain} {
                  bind 127.0.0.1 ::1
                  hosts {
                    ${lib.concatStringsSep "\n                  " (
                      let
                        allHostRecords = lib.flatten (
                          lib.mapAttrsToList (
                            hName: h: lib.mapAttrsToList (oName: o: "${o.ipv6} ${o.domain}") h.overlays
                          ) alloy.hosts
                        );
                        allJailRecords = lib.flatten (
                          lib.mapAttrsToList (
                            jName: j: lib.mapAttrsToList (oName: o: "${o.ipv6} ${o.domain}") j.overlays
                          ) alloy.jails
                        );
                        allEndpointRecords = lib.flatten (
                          lib.mapAttrsToList (eName: e: lib.map (t: "${t.ipv6} ${e.domain}") e.targets) alloy.endpoints
                        );
                      in
                      allHostRecords ++ allJailRecords ++ allEndpointRecords
                    )}
                    fallthrough
                  }
                }
              '';
            };
            networking.nameservers = [
              "127.0.0.1"
              "::1"
            ];
          };
        };
    in
    {
      options.dns = {
        discovery = {
          domain = lib.mkOption {
            type = alib.types.dns.name;
            default = "alloy.internal";
          };
        };
        records = lib.mkOption {
          default = [ ];
          type = lib.types.listOf recordType;
        };
        acmeChallenges = lib.mkOption {
          default = [ ];
          type = lib.types.listOf acmeChallengeType;
        };
        zones = lib.mkOption {
          default = { };
          type = lib.types.attrsOf zoneType;
        };
        resolveNode = lib.mkOption {
          type = lib.types.functionTo lib.types.str;
          readOnly = true;
          default = domain: alib.resolveZoneNode config.dns.zones domain;
        };
        mkTsigKeyId = lib.mkOption {
          type = lib.types.functionTo lib.types.str;
          readOnly = true;
          default =
            tsigKeySecret:
            let
              fullHash = builtins.hashString "sha256" tsigKeySecret;
            in
            "${builtins.substring 0 32 fullHash}.${builtins.substring 32 32 fullHash}";
        };
      };

      options.overlays = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, ... }: {
              options = {
                domain = lib.mkOption {
                  type = lib.types.str;
                  readOnly = true;
                };
              };
              config = {
                domain = "${name}.${alloy.dns.discovery.domain}";
              };
            }
          )
        );
      };

      options.endpoints = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, ... }: {
              options = {
                domain = lib.mkOption {
                  type = lib.types.str;
                  readOnly = true;
                };
              };
              config = {
                domain = "${name}.ep.${alloy.dns.discovery.domain}";
              };
            }
          )
        );
      };

      options.hosts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule (nodeSubmodule "host"));
      };

      options.jails = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule (nodeSubmodule "jail"));
      };

      config = {
        assertions = lib.map (ch: {
          assertion = alib.types.dns.name.check (lib.replaceStrings [ "/" ] [ "." ] ch.tsigKeySecret);
          message = "[Alloy] DNS acmeChallenge for zone '${ch.domain.zone}' has an invalid tsigKeySecret '${ch.tsigKeySecret}'. When slashes are replaced by dots, it must form a valid DNS name.";
        }) alloy.dns.acmeChallenges;

        generators.templates."dns/tsig-key" = { config, ... }: {
          options = {
            keySecret = lib.mkOption { type = lib.types.str; };
          };
          config.secrets.${config.keySecret} = {};
          config.tags = [
            "dns"
            "tsig-key"
          ];
          config.package =
            { pkgs, ... }:
            pkgs.writeShellScriptBin "dns-tsig-key-gen" ''
              TSIG_KEY=$(${pkgs.openssl}/bin/openssl rand -base64 32)
              "$ALLOY_BIN" secrets set "${config.keySecret}" <<< "$TSIG_KEY"
            '';
        };
      };
    };
}
