{
  lib,
  alib,
}:
{
  assertion = lib.types.submodule {
    options = {
      assertion = lib.mkOption {
        type = lib.types.bool;
      };
      message = lib.mkOption {
        type = lib.types.str;
      };
    };
  };

  permissions = lib.types.submodule (
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

  # dns.name =
  #   lib.types.addCheck
  #     (lib.types.strMatching "^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\\.)*[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\\.?$")
  #     (
  #       str:
  #       let
  #         validTotalLength = builtins.stringLength str <= 253;
  #         labels = lib.strings.splitString "." str;
  #         nonEmptyLabels = lib.filter (l: l != "") labels;
  #         validLabelLengths = lib.all (l: builtins.stringLength l <= 63) nonEmptyLabels;
  #       in
  #       validTotalLength && validLabelLengths
  #     )
  #   // {
  #     name = "dns domain name";
  #     description = "valid domain name (RFC 1123, max 253 total chars, max 63 per label)";
  #   };

  dns.name =
    let
      labelRegex = "[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?";
    in
    lib.types.addCheck (lib.types.strMatching "^(${labelRegex}\\.)*${labelRegex}\\.?$") (
      str: builtins.stringLength str <= 253
    )
    // {
      name = "dns domain name";
      description = "valid domain name (RFC 1123, max 253 total chars, max 63 per label)";
    };

  dns.label = lib.mkOptionType {
    name = "dnsLabel";
    description = "A valid DNS label (1-63 chars, alphanumeric and hyphens, no leading/trailing hyphens)";
    check =
      x: builtins.isString x && builtins.match "^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$" x != null;
    merge = lib.options.mergeEqualOption;
  };

  # TODO check octeds values: 0 <= octed value <= 255
  # ip.v4addr = lib.types.strMatching "^([0-9]{1,3}\\.){3}[0-9]{1,3}$" // {
  #   name = "ipv4";
  #   description = "IPv4 address";
  # };

  ip.v4addr =
    lib.types.strMatching "^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$"
    // {
      name = "ipv4";
      description = "IPv4 address (with octets 0-255)";
    };

  ip.v6addr = lib.types.strMatching "^([0-9a-f]{4}:){7}[0-9a-f]{4}$" // {
    name = "ipv6";
    description = "IPv6 address";
  };

  zoneNode = lib.types.submodule {
    options.zone = lib.mkOption {
      type = lib.types.str;
    };
    options.name = lib.mkOption {
      type = lib.types.either alib.types.dns.name (lib.types.enum [ "@" ]);
    };
  };

  ip.addr = lib.types.attrTag {
    v4 = lib.mkOption {
      type = alib.types.ip.v4addr;
    };
    v6 = lib.mkOption {
      type = alib.types.ip.v6addr;
    };
  };

  netMatchOpts = {
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
}
