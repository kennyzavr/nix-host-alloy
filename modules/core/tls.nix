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

      certSubmodule = { config, name, ... }: {
        options = {
          id = lib.mkOption {
            readOnly = true;
            default = name;
            type = lib.types.str;
          };
          domains = lib.mkOption {
            default = [ ];
            type = lib.types.listOf alib.types.dns.name;
            apply = lib.map (n: lib.removePrefix "." (lib.removeSuffix "." n));
          };
          ips = lib.mkOption {
            default = [ ];
            type = lib.types.listOf (
              lib.types.submodule {
                options.addr = lib.mkOption {
                  type = alib.types.ip.addr;
                };
                options.prefixLength = lib.mkOption {
                  type = lib.types.int;
                };
              }
            );
          };
          acme = {
            server = lib.mkOption {
              default = null;
              type = lib.types.nullOr lib.types.str;
            };
            email = lib.mkOption {
              default = null;
              type = lib.types.nullOr lib.types.str;
            };
          };
          assertions = lib.mkOption {
            type = lib.types.listOf alib.types.unspecified;
            default = [ ];
          };
        };

        config = {
          assertions = [
            {
              assertion = config.domains != [ ] || config.ips != [ ];
              message = ''
                [Alloy] Invalid TLS certificate definition '${name}'

                A TLS certificate must specify at least one domain or IP address.
                Please define 'domains' or 'ips' (or both) for this certificate.
              '';
            }
          ];
        };
      };

      extractIps =
        ips:
        lib.map (i: {
          addr = if builtins.isString i.addr then i.addr else (i.addr.v4 or i.addr.v6 or i.addr);
          prefixLength = i.prefixLength;
        }) ips;

      hostSubmodule = { config, name, ... }: {
        options.tls = {
          static-ca = {
            certFact = lib.mkOption {
              type = lib.types.str;
              default = "tls/certs/hosts/${name}/cert.crt";
            };
            keySecret = lib.mkOption {
              type = lib.types.str;
              default = "tls/certs/hosts/${name}/key.pem";
            };
            generator = lib.mkOption {
              type = lib.types.str;
              default = "tls/certs/hosts/${name}";
            };
          };
        };
        config = {
          secrets.${config.tls.static-ca.keySecret} = { };

          nixosModule = {
            security.pki.certificates = lib.map (c: alloy.facts.${c}.value) alloy.tls.pki.certificateFacts;
          };
        };
      };

      jailSubmodule = { config, name, ... }: {
        options.tls = {
          static-ca = {
            certFact = lib.mkOption {
              type = lib.types.str;
              default = "tls/certs/jails/${name}/cert.crt";
            };
            keySecret = lib.mkOption {
              type = lib.types.str;
              default = "tls/certs/jails/${name}/key.pem";
            };
            generator = lib.mkOption {
              type = lib.types.str;
              default = "tls/certs/jails/${name}";
            };
          };
        };
        config = {
          secrets.${config.tls.static-ca.keySecret} = { };

          nixosModule = {
            security.pki.certificates = lib.map (c: alloy.facts.${c}.value) alloy.tls.pki.certificateFacts;
          };
        };
      };
    in
    {
      options.tls = {
        pki = {
          certificateFacts = lib.mkOption {
            default = [ ];
            type = lib.types.listOf lib.types.str;
          };
        };
        certs = lib.mkOption {
          default = { };
          type = lib.types.attrsOf (lib.types.submodule certSubmodule);
        };
        static-ca = {
          certFact = lib.mkOption {
            type = lib.types.str;
            default = "tls/certs/root/cert.crt";
          };
          keySecret = lib.mkOption {
            type = lib.types.str;
            default = "tls/certs/root/key.pem";
          };
          generator = lib.mkOption {
            type = lib.types.str;
            default = "tls/certs/root";
          };
        };
      };

      options.hosts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
      };

      options.jails = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule jailSubmodule);
      };

      config =
        let
          mkHost = hostName: host: {
            facts.${host.tls.static-ca.certFact} = { };
            secrets.${host.tls.static-ca.keySecret} = { };

            generators.instances.${host.tls.static-ca.generator} = {
              imports = [ alloy.generators.templates."tls/leaf-cert" ];

              tags = [ "tls/static-ca/leaf" ];

              wants = [
                alloy.tls.static-ca.generator
              ];

              parent = {
                inherit (alloy.tls.static-ca) certFact keySecret;
              };
              inherit (host.tls.static-ca) certFact keySecret;
              subject = "Alloy Host ${hostName}";
              san.ips = lib.mapAttrsToList (_: overlay: {
                addr.v6 = overlay.ipv6;
              }) host.overlays;
            };
          };

          mkJail = jailName: jail: {
            facts.${jail.tls.static-ca.certFact} = { };
            secrets.${jail.tls.static-ca.keySecret} = { };

            generators.instances.${jail.tls.static-ca.generator} = {
              imports = [ alloy.generators.templates."tls/leaf-cert" ];

              tags = [ "tls/static-ca/leaf" ];

              wants = [
                alloy.tls.static-ca.generator
              ];

              parent = {
                inherit (alloy.tls.static-ca) certFact keySecret;
              };
              inherit (jail.tls.static-ca) certFact keySecret;
              subject = "Alloy Jail ${jailName}";
              san.ips = lib.mapAttrsToList (_: overlay: {
                addr.v6 = overlay.ipv6;
              }) jail.overlays;
            };
          };

          configs = lib.flatten [
            (lib.mapAttrsToList mkHost alloy.hosts)
            (lib.mapAttrsToList mkJail alloy.jails)
          ];
        in
        {
          assertions = lib.flatten (lib.mapAttrsToList (name: cert: cert.assertions) alloy.tls.certs);

          facts = lib.mkMerge [
            (lib.mkMerge (lib.map (c: c.facts) configs))
            {
              ${alloy.tls.static-ca.certFact} = { };
            }
          ];

          secrets = lib.mkMerge [
            (lib.mkMerge (lib.map (c: c.secrets) configs))
            {
              ${alloy.tls.static-ca.keySecret} = { };
            }
          ];

          tls.pki.certificateFacts = [
            alloy.tls.static-ca.certFact
          ];

          generators = lib.mkMerge [
            (lib.mkMerge (lib.map (c: c.generators) configs))
            {
              instances.${alloy.tls.static-ca.generator} = {
                imports = [ alloy.generators.templates."tls/ca-cert" ];

                tags = [ "tls/static-ca/root" ];

                certFact = alloy.tls.static-ca.certFact;
                keySecret = alloy.tls.static-ca.keySecret;

                subject = "Alloy Root CA";

                notAfter = "8760h";
                maxPathLen = 0;

                permitted.ips = lib.mapAttrsToList (_: overlay: {
                  addr.v6 = "${overlay.ipv6Prefix}:0000:0000:0000:0000:0000";
                  prefixLength = 48;
                }) alloy.overlays;
              };

              templates."tls/ca-cert" = { config, ... }: {
                # ... (твои options оставляем как были)
                options = {
                  certFact = lib.mkOption { type = lib.types.str; };
                  keySecret = lib.mkOption { type = lib.types.str; };
                  parent = lib.mkOption {
                    default = null;
                    type = lib.types.nullOr (
                      lib.types.submodule {
                        options = {
                          certFact = lib.mkOption { type = lib.types.str; };
                          keySecret = lib.mkOption { type = lib.types.str; };
                        };
                      }
                    );
                  };
                  subject = lib.mkOption { type = lib.types.str; };
                  notBefore = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                  };
                  notAfter = lib.mkOption {
                    type = lib.types.str;
                    default = if config.parent == null then "8760h" else "4380h";
                  };
                  maxPathLen = lib.mkOption {
                    default = if config.parent == null then 1 else 0;
                    type = lib.types.int;
                  };
                  permitted.domains = lib.mkOption {
                    default = [ ];
                    type = lib.types.listOf alib.types.dns.name;
                    apply = lib.map (n: lib.removePrefix "." (lib.removeSuffix "." n));
                  };
                  permitted.ips = lib.mkOption {
                    default = [ ];
                    type = lib.types.listOf (
                      lib.types.submodule {
                        options.addr = lib.mkOption { type = alib.types.ip.addr; };
                        options.prefixLength = lib.mkOption { type = lib.types.int; };
                      }
                    );
                  };
                };

                config.tags = [ "tls/ca-cert" ];
                config.package =
                  { pkgs, ... }:
                  pkgs.writers.writePython3Bin "tls-ca-cert-generator"
                    {
                      libraries = [ pkgs.python3Packages.cryptography ];
                    }
                    ''
                      import os
                      import sys
                      import json
                      import subprocess
                      import datetime
                      import ipaddress

                      from cryptography import x509
                      from cryptography.x509.oid import NameOID
                      from cryptography.hazmat.primitives.asymmetric import ed25519
                      from cryptography.hazmat.primitives import serialization


                      ALLOY_BIN = os.environ.get("ALLOY_BIN", "alloy")


                      def run_alloy(cmd_args, input_data=None, capture=True):
                          cmd = [ALLOY_BIN] + cmd_args
                          if capture:
                              res = subprocess.run(
                                  cmd, input=input_data, text=True, capture_output=True
                              )
                              if res.returncode != 0:
                                  print(f"Error: {res.stderr}", file=sys.stderr)
                                  sys.exit(1)
            
                              return res.stdout.strip()

                          res = subprocess.run(cmd, input=input_data, text=True)
                          if res.returncode != 0:
                              sys.exit(1)


                      def parse_time(spec):
                          if not spec:
                              return datetime.datetime.now(datetime.timezone.utc)
                          now = datetime.datetime.now(datetime.timezone.utc)
                          if spec.startswith(("+", "-")) or spec[0].isdigit():
                              sign = -1 if spec.startswith("-") else 1
                              if spec.startswith(("+", "-")):
                                  spec = spec[1:]
                              if spec.endswith("h"):
                                  delta = datetime.timedelta(hours=int(spec[:-1]))
                              elif spec.endswith("d"):
                                  delta = datetime.timedelta(days=int(spec[:-1]))
                              elif spec.endswith("m"):
                                  delta = datetime.timedelta(minutes=int(spec[:-1]))
                              elif spec.endswith("s"):
                                  delta = datetime.timedelta(seconds=int(spec[:-1]))
                              else:
                                  raise ValueError(f"Unknown format: {spec}")
                              return now + (sign * delta)
                          return datetime.datetime.fromisoformat(spec.replace("Z", "+00:00"))


                      config_data = json.loads("""${
                        builtins.toJSON {
                          inherit (config)
                            certFact
                            keySecret
                            subject
                            notBefore
                            notAfter
                            maxPathLen
                            ;
                          permittedDomains = config.permitted.domains;
                          permittedIps = config.permitted.ips;
                          parent = config.parent;
                        }
                      }""")  # noqa: E501

                      parent_cfg = config_data.get("parent")

                      if parent_cfg:
                          parent_key_pem = run_alloy(
                              ["secrets", "view", parent_cfg["keySecret"]]
                          )
                          parent_cert_pem = run_alloy(
                              ["facts", "view", parent_cfg["certFact"]]
                          )

                          issuer_key = serialization.load_pem_private_key(
                              parent_key_pem.encode(), password=None
                          )
                          parent_cert = x509.load_pem_x509_certificate(
                              parent_cert_pem.encode()
                          )
                          issuer_name = parent_cert.subject
                      else:
                          issuer_key = None
                          parent_cert = None

                      key = ed25519.Ed25519PrivateKey.generate()
                      key_pem = key.private_bytes(
                          encoding=serialization.Encoding.PEM,
                          format=serialization.PrivateFormat.PKCS8,
                          encryption_algorithm=serialization.NoEncryption()
                      ).decode("utf-8")

                      if not issuer_key:
                          issuer_key = key

                      subject_name = x509.Name([
                          x509.NameAttribute(NameOID.COMMON_NAME, config_data["subject"])
                      ])
                      if not parent_cert:
                          issuer_name = subject_name

                      if config_data.get("notBefore"):
                          nb = parse_time(config_data.get("notBefore"))
                      else:
                          nb = datetime.datetime.now(
                              datetime.timezone.utc
                          ) - datetime.timedelta(hours=1)

                      na = parse_time(config_data["notAfter"])

                      builder = x509.CertificateBuilder().subject_name(
                          subject_name
                      ).issuer_name(
                          issuer_name
                      ).public_key(
                          key.public_key()
                      ).serial_number(
                          x509.random_serial_number()
                      ).not_valid_before(
                          nb
                      ).not_valid_after(
                          na
                      )

                      max_path = config_data.get("maxPathLen")
                      builder = builder.add_extension(
                          x509.BasicConstraints(
                              ca=True,
                              path_length=max_path if max_path >= 0 else None
                          ),
                          critical=True
                      ).add_extension(
                          x509.KeyUsage(
                              digital_signature=True,
                              content_commitment=False,
                              key_encipherment=False,
                              data_encipherment=False,
                              key_agreement=False,
                              key_cert_sign=True,
                              crl_sign=True,
                              encipher_only=False,
                              decipher_only=False
                          ),
                          critical=True
                      ).add_extension(
                          x509.SubjectKeyIdentifier.from_public_key(key.public_key()),
                          critical=False
                      )

                      if parent_cert:
                          builder = builder.add_extension(
                              x509.AuthorityKeyIdentifier.from_issuer_public_key(
                                  issuer_key.public_key()
                              ),
                              critical=False
                          )

                      permitted_dns = config_data.get("permittedDomains", [])
                      permitted_ips = config_data.get("permittedIps", [])
                      if permitted_dns or permitted_ips:
                          permitted = []
                          for d in permitted_dns:
                              permitted.append(x509.DNSName(d))
                          for ip_obj in permitted_ips:
                              addr_data = ip_obj["addr"]
                              if isinstance(addr_data, dict):
                                  addr_str = addr_data.get("v4") or addr_data.get("v6")
                              else:
                                  addr_str = addr_data

                              network = ipaddress.ip_network(
                                  f"{addr_str}/{ip_obj['prefixLength']}", strict=False
                              )
                              permitted.append(x509.IPAddress(network))

                          builder = builder.add_extension(
                              x509.NameConstraints(
                                  permitted_subtrees=permitted, excluded_subtrees=None
                              ),
                              critical=True
                          )

                      cert = builder.sign(issuer_key, None)
                      cert_pem = cert.public_bytes(serialization.Encoding.PEM).decode("utf-8")

                      run_alloy(
                          ["secrets", "set", config_data["keySecret"]],
                          input_data=key_pem,
                          capture=False
                      )
                      run_alloy(
                          ["facts", "set", config_data["certFact"]],
                          input_data=cert_pem,
                          capture=False
                      )
                    '';
              };

              templates."tls/leaf-cert" = { config, ... }: {
                # ... (твои options оставляем как были)
                options = {
                  certFact = lib.mkOption { type = lib.types.str; };
                  keySecret = lib.mkOption { type = lib.types.str; };
                  parent = {
                    certFact = lib.mkOption { type = lib.types.str; };
                    keySecret = lib.mkOption { type = lib.types.str; };
                  };
                  subject = lib.mkOption { type = lib.types.str; };
                  notBefore = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                  };
                  notAfter = lib.mkOption {
                    type = lib.types.str;
                    default = if config.parent == null then "8760h" else "4380h";
                  };
                  maxPathLen = lib.mkOption {
                    default = if config.parent == null then 1 else 0;
                    type = lib.types.int;
                  };
                  san.domains = lib.mkOption {
                    default = [ ];
                    type = lib.types.listOf alib.types.dns.name;
                    apply = lib.map (n: lib.removePrefix "." (lib.removeSuffix "." n));
                  };
                  san.ips = lib.mkOption {
                    default = [ ];
                    type = lib.types.listOf (
                      lib.types.submodule {
                        options.addr = lib.mkOption { type = alib.types.ip.addr; };
                        # options.prefixLength = lib.mkOption { type = lib.types.int; };
                      }
                    );
                  };
                };

                config.tags = [ "tls/leaf-cert" ];
                config.package =
                  { pkgs, ... }:
                  pkgs.writers.writePython3Bin "tls-leaf-cert-generator"
                    {
                      libraries = [ pkgs.python3Packages.cryptography ];
                    }
                    ''
                      import os
                      import sys
                      import json
                      import subprocess
                      import datetime
                      import ipaddress

                      from cryptography import x509
                      from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID
                      from cryptography.hazmat.primitives.asymmetric import ed25519
                      from cryptography.hazmat.primitives import serialization


                      ALLOY_BIN = os.environ.get("ALLOY_BIN", "alloy")


                      def run_alloy(cmd_args, input_data=None, capture=True):
                          cmd = [ALLOY_BIN] + cmd_args
                          if capture:
                              res = subprocess.run(
                                  cmd, input=input_data, text=True, capture_output=True
                              )
                              if res.returncode != 0:
                                  print(f"Error: {res.stderr}", file=sys.stderr)
                                  sys.exit(1)
            
                              return res.stdout.strip()

                          res = subprocess.run(cmd, input=input_data, text=True)
                          if res.returncode != 0:
                              sys.exit(1)


                      def parse_time(spec):
                          if not spec:
                              return datetime.datetime.now(datetime.timezone.utc)
                          now = datetime.datetime.now(datetime.timezone.utc)
                          if spec.startswith(("+", "-")) or spec[0].isdigit():
                              sign = -1 if spec.startswith("-") else 1
                              if spec.startswith(("+", "-")):
                                  spec = spec[1:]
                              if spec.endswith("h"):
                                  delta = datetime.timedelta(hours=int(spec[:-1]))
                              elif spec.endswith("d"):
                                  delta = datetime.timedelta(days=int(spec[:-1]))
                              elif spec.endswith("m"):
                                  delta = datetime.timedelta(minutes=int(spec[:-1]))
                              elif spec.endswith("s"):
                                  delta = datetime.timedelta(seconds=int(spec[:-1]))
                              else:
                                  raise ValueError(f"Unknown format: {spec}")
                              return now + (sign * delta)
                          return datetime.datetime.fromisoformat(spec.replace("Z", "+00:00"))


                      config_data = json.loads("""${
                        builtins.toJSON {
                          inherit (config)
                            certFact
                            keySecret
                            subject
                            notBefore
                            notAfter
                            parent
                            ;
                          sanDomains = config.san.domains;
                          sanIps = config.san.ips;
                        }
                      }""")  # noqa: E501

                      parent_cfg = config_data.get("parent")
                      if not parent_cfg:
                          print("Error: Leaf certificate requires a parent CA.", file=sys.stderr)
                          sys.exit(1)

                      parent_key_pem = run_alloy(["secrets", "view", parent_cfg["keySecret"]])
                      parent_cert_pem = run_alloy(["facts", "view", parent_cfg["certFact"]])

                      issuer_key = serialization.load_pem_private_key(
                          parent_key_pem.encode(), password=None
                      )
                      parent_cert = x509.load_pem_x509_certificate(parent_cert_pem.encode())

                      key = ed25519.Ed25519PrivateKey.generate()
                      key_pem = key.private_bytes(
                          encoding=serialization.Encoding.PEM,
                          format=serialization.PrivateFormat.PKCS8,
                          encryption_algorithm=serialization.NoEncryption()
                      ).decode("utf-8")

                      subject_name = x509.Name([
                          x509.NameAttribute(NameOID.COMMON_NAME, config_data["subject"])
                      ])

                      if config_data.get("notBefore"):
                          nb = parse_time(config_data.get("notBefore"))
                      else:
                          nb = datetime.datetime.now(
                              datetime.timezone.utc
                          ) - datetime.timedelta(hours=1)

                      na = parse_time(config_data["notAfter"])

                      builder = x509.CertificateBuilder().subject_name(
                          subject_name
                      ).issuer_name(
                          parent_cert.subject
                      ).public_key(
                          key.public_key()
                      ).serial_number(
                          x509.random_serial_number()
                      ).not_valid_before(
                          nb
                      ).not_valid_after(
                          na
                      )

                      builder = builder.add_extension(
                          x509.BasicConstraints(ca=False, path_length=None), critical=True
                      ).add_extension(
                          x509.KeyUsage(
                              digital_signature=True,
                              content_commitment=False,
                              key_encipherment=False,
                              data_encipherment=False,
                              key_agreement=False,
                              key_cert_sign=False,
                              crl_sign=False,
                              encipher_only=False,
                              decipher_only=False
                          ),
                          critical=True
                      ).add_extension(
                          x509.ExtendedKeyUsage([
                              ExtendedKeyUsageOID.SERVER_AUTH,
                              ExtendedKeyUsageOID.CLIENT_AUTH
                          ]),
                          critical=False
                      ).add_extension(
                          x509.SubjectKeyIdentifier.from_public_key(key.public_key()),
                          critical=False
                      ).add_extension(
                          x509.AuthorityKeyIdentifier.from_issuer_public_key(
                              issuer_key.public_key()
                          ),
                          critical=False
                      )

                      san_dns = config_data.get("sanDomains", [])
                      san_ips = config_data.get("sanIps", [])

                      sans = []
                      for d in san_dns:
                          sans.append(x509.DNSName(d))
                      for ip_obj in san_ips:
                          addr_data = ip_obj["addr"]
                          if isinstance(addr_data, dict):
                              addr_str = addr_data.get("v4") or addr_data.get("v6")
                          else:
                              addr_str = addr_data
                          sans.append(x509.IPAddress(ipaddress.ip_address(addr_str)))

                      if sans:
                          builder = builder.add_extension(
                              x509.SubjectAlternativeName(sans), critical=False
                          )

                      cert = builder.sign(issuer_key, None)
                      cert_pem = cert.public_bytes(serialization.Encoding.PEM).decode("utf-8")

                      run_alloy(
                          ["secrets", "set", config_data["keySecret"]],
                          input_data=key_pem,
                          capture=False
                      )
                      run_alloy(
                          ["facts", "set", config_data["certFact"]],
                          input_data=cert_pem,
                          capture=False
                      )
                    '';
              };
            }
          ];
        };
    };
}
