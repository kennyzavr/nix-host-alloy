{
  self,
  lib,
  ...
}:
let
  alib = self.lib;
in
{
  config.flake.lib = {
    evalModules =
      evalArgs:
      let
        res = lib.evalModules {
          modules = [
            self.alloyModules.default
          ]
          ++ (evalArgs.modules or [ ]);
          specialArgs = (evalArgs.specialArgs or { }) // {
            inherit alib;
          };
        };
        failedAssertions = lib.filter (a: !a.assertion) res.config.assertions;
      in
      if (evalArgs.checkAssertions or true) && failedAssertions != [ ] then
        builtins.throw ''
          Failed assertions:
          ${lib.concatMapStringsSep "\n" (x: "- ${x.message}") failedAssertions}
        ''
      else
        res;

    evalModule = module: alib.evalModules { modules = lib.toList module; };

    mkCli =
      { pkgs, module }:
      (alib.evalModules {
        checkAssertions = false;
        modules = [ module ];
      }).config.cli.package
        { inherit pkgs; };

    types.ageKeyPair = lib.types.submodule {
      options = {
        identity = lib.mkOption {
          type = lib.types.oneOf [
            lib.types.path
            lib.types.str
          ];
        };
        recipient = lib.mkOption {
          type = lib.types.oneOf [
            lib.types.path
            lib.types.str
          ];
        };
      };
    };

    types.assertion = lib.types.submodule {
      options = {
        assertion = lib.mkOption {
          type = lib.types.bool;
        };
        message = lib.mkOption {
          type = lib.types.str;
        };
      };
    };

    types.permissions = lib.types.submodule (
      { config, ... }: {
        options = {
          owner = lib.mkOption {
            type = lib.types.either lib.types.int lib.types.str;
            default = "root";
          };
          group = lib.mkOption {
            type = lib.types.either lib.types.int lib.types.str;
            default = config.owner;
          };
          mode = lib.mkOption {
            type = lib.types.str;
          };
        };
      }
    );

    types.dns.name =
      let
        labelRegex = "[a-zA-Z0-9_]([a-zA-Z0-9_-]{0,61}[a-zA-Z0-9_])?";
      in
      lib.types.addCheck (lib.types.strMatching "^(${labelRegex}\\.)*${labelRegex}\\.?$") (
        str: builtins.stringLength str <= 253
      )
      // {
        name = "dns domain name";
        description = "valid domain name (RFC 1123, max 253 total chars, max 63 per label)";
      };

    types.dns.label = lib.mkOptionType {
      name = "dnsLabel";
      description = "A valid DNS label (1-63 chars, alphanumeric and hyphens, no leading/trailing hyphens)";
      check =
        x:
        builtins.isString x && builtins.match "^[a-zA-Z0-9_]([a-zA-Z0-9_-]{0,61}[a-zA-Z0-9_])?$" x != null;
      merge = lib.options.mergeEqualOption;
    };

    types.ip.v4addr =
      lib.types.strMatching "^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$"
      // {
        name = "ipv4";
        description = "IPv4 address (with octets 0-255)";
      };

    types.ip.v6addr = lib.types.strMatching "^([0-9a-f]{4}:){7}[0-9a-f]{4}$" // {
      name = "ipv6";
      description = "IPv6 address";
    };

    types.zoneNode = lib.types.submodule {
      options.zone = lib.mkOption {
        type = lib.types.str;
      };
      options.name = lib.mkOption {
        type = lib.types.either alib.types.dns.name (lib.types.enum [ "@" ]);
      };
    };

    types.ip.addr = lib.types.attrTag {
      v4 = lib.mkOption {
        type = alib.types.ip.v4addr;
      };
      v6 = lib.mkOption {
        type = alib.types.ip.v6addr;
      };
    };

    types.netMatchOpts = {
      iface = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
      };
      ipv4 = lib.mkOption {
        type = lib.types.nullOr alib.types.ip.v4addr;
      };
      ipv6 = lib.mkOption {
        type = lib.types.nullOr alib.types.ip.v6addr;
      };
    };

    mkArpaIpv6 =
      ipv6:
      let
        cleanIpv6 = builtins.replaceStrings [ ":" ] [ "" ] ipv6;
        len = builtins.stringLength cleanIpv6;
        reversedChars = builtins.genList (i: builtins.substring (len - 1 - i) 1 cleanIpv6) len;
      in
      assert lib.assertMsg (
        builtins.match "^(([0-9a-f]{4})(:[0-9a-f]{4}){0,7})?$" ipv6 != null
      ) "mkArapIpv6: expected ipv6 blocks, got ${ipv6}";
      builtins.concatStringsSep "." reversedChars + ".ip6.arpa.";

    resolveZoneNode =
      zones: node:
      assert lib.assertMsg (builtins.hasAttr node.zone zones)
        "alloy: dns: resolveZoneNode 'zone ${node.zone}, name ${node.name}': the zone is not defined";
      "${if node.name == "@" then "" else "${lib.removeSuffix "." node.name}."}${
        lib.removeSuffix "." zones.${node.zone}.apex
      }.";

    extendZoneNode = node: extension: {
      zone = node.zone;
      name = "${lib.removeSuffix "." extension}${lib.optionalString (node.name != "@") ".${node.name}"}";
    };
  };

}
