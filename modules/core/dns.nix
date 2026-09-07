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
        node = lib.mkOption {
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
                builtins.concatMapStringsSep " " (chunk: ''"${lib.escape [ "\"" "\\" ] chunk}"'') chunks
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
          "${alloy.dns.rezolveNode config.node} ${ttlStr}IN ${recordTypeStr} ${value}";
      };
    }
  );

  zoneType = lib.types.submodule (
    { config, name, ... }: {
      options = {
        apex = lib.mkOption {
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
      };
      config.bindConfig = ''
        $ORIGIN ${lib.removeSuffix "." config.apex}.
        $TTL ${toString config.ttl}
        ${lib.concatMapStringsSep "\n" (record: record.bindConfig) (
          lib.filter (r: r.node.zone == name) alloy.dns.records
        )}
      '';
    }
  );
in
{
  options.dns = {
    records = lib.mkOption {
      type = lib.types.listOf recordType;
    };
    zones = lib.mkOption {
      default = { };
      type = lib.types.attrsOf zoneType;
    };
    rezolveNode = lib.mkOption {
      type = lib.types.functionTo lib.types.str;
      readOnly = true;
      default = node: alib.resolveZoneNode config.dns.zones node;
    };
  };
}
