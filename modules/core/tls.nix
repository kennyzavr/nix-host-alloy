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
  };

  config.assertions = lib.flatten (lib.mapAttrsToList (name: cert: cert.assertions) alloy.tls.certs);

  config.generators.templates."tls-x509-ca-cert" = { config, ... }: {
    options = {
      certFact = lib.mkOption {
        type = lib.types.str;
      };
      keySecret = lib.mkOption {
        type = lib.types.str;
      };
      parent = lib.mkOption {
        default = null;
        type = lib.types.nullOr (
          lib.types.submodule {
            options = {
              certFact = lib.mkOption {
                type = lib.types.str;
              };
              keySecret = lib.mkOption {
                type = lib.types.str;
              };
            };
          }
        );
      };
      subject = lib.mkOption {
        type = lib.types.str;
      };
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
            options.addr = lib.mkOption {
              type = alib.types.ip.addr;
            };
            options.prefixLength = lib.mkOption {
              type = lib.types.int;
            };
          }
        );
      };
    };

    config = {
      tags = [
        "tls-x509-cert"
        "tls-x509-ca-cert"
      ];

      assertions = [
        {
          assertion = config.permitted.domains != [ ] || config.permitted.ips != [ ];
          message = ''
            [Alloy] Unconstrained CA certificate '${config.certFact}'

            A CA certificate template must specify at least one permitted domain or IP address.
            Please define 'permitted.domains' or 'permitted.ips' to enforce Name Constraints.
          '';
        }
      ];

      facts."${config.certFact}" = {
        type = lib.types.str;
      };

      secrets."${config.keySecret}" = { };

      script = ''
        import json

        add_to_git = getattr(args, "add_to_git", False)

        cert_fact_name = "${config.certFact}"
        key_secret_name = "${config.keySecret}"

        if not AlloySecretsAPI.exists(key_secret_name):
            CLI.step(f"Generating CA certificate for '{cert_fact_name}'...")
            
            parent_key = None
            parent_cert = None
            ${lib.optionalString (config.parent != null) ''
              if not AlloySecretsAPI.exists("${config.parent.keySecret}"):
                  CLI.abort("Parent CA key secret '${config.parent.keySecret}' is missing! It must be generated first.")
              if not AlloyFactsAPI.exists("${config.parent.certFact}"):
                  CLI.abort("Parent CA cert fact '${config.parent.certFact}' is missing! It must be generated first.")

              parent_key_pem = AlloySecretsAPI.get("${config.parent.keySecret}")
              parent_cert_json = AlloyFactsAPI.get("${config.parent.certFact}")
              parent_key = AlloyTlsAPI.load_key_from_pem(parent_key_pem)
              parent_cert = AlloyTlsAPI.load_cert_from_pem(parent_cert_json.encode())
            ''}
            
            key, cert = AlloyTlsAPI.generate_ca_cert(
                subject="${config.subject}",
                not_before=${if config.notBefore == null then "None" else ''"${config.notBefore}"''},
                not_after="${config.notAfter}",
                max_path_len=${if config.maxPathLen == null then "-1" else toString config.maxPathLen},
                permitted_dns=${builtins.toJSON config.permitted.domains},
                permitted_ips=${builtins.toJSON (extractIps config.permitted.ips)},
                parent_key=parent_key,
                parent_cert=parent_cert
            )
            
            AlloySecretsAPI.set(key_secret_name, AlloyTlsAPI.key_to_pem(key), force=True, add_to_git=add_to_git)
            AlloyFactsAPI.set(cert_fact_name, json.dumps(AlloyTlsAPI.cert_to_pem(cert).decode()), force=True, add_to_git=add_to_git)
      '';
    };
  };

  config.generators.templates."tls-x509-leaf-cert" = { config, ... }: {
    options = {
      certFact = lib.mkOption {
        type = lib.types.str;
      };
      keySecret = lib.mkOption {
        type = lib.types.str;
      };
      parent = lib.mkOption {
        type = lib.types.submodule {
          options = {
            certFact = lib.mkOption {
              type = lib.types.str;
            };
            keySecret = lib.mkOption {
              type = lib.types.str;
            };
          };
        };
      };
      subject = lib.mkOption {
        type = lib.types.str;
      };
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
            options.addr = lib.mkOption {
              type = alib.types.ip.addr;
            };
            options.prefixLength = lib.mkOption {
              type = lib.types.int;
            };
          }
        );
      };
    };

    config = {
      tags = [
        "tls-x509-cert"
        "tls-x509-leaf-cert"
      ];

      assertions = [
        {
          assertion = config.san.domains != [ ] || config.san.ips != [ ];
          message = ''
            [Alloy] Invalid leaf certificate '${config.certFact}'

            A leaf certificate must specify at least one Subject Alternative Name (SAN).
            Please define 'san.domains' or 'san.ips' for this certificate.
          '';
        }
      ];

      facts."${config.certFact}" = {
        type = lib.types.str;
      };

      secrets."${config.keySecret}" = { };

      script = ''
        import json

        add_to_git = getattr(args, "add_to_git", False)

        cert_fact_name = "${config.certFact}"
        key_secret_name = "${config.keySecret}"

        if not AlloySecretsAPI.exists(key_secret_name):
            CLI.step(f"Generating leaf certificate for '{cert_fact_name}'...")
            
            if not AlloySecretsAPI.exists("${config.parent.keySecret}"):
                CLI.abort("Parent CA key secret '${config.parent.keySecret}' is missing! It must be generated first.")
            if not AlloyFactsAPI.exists("${config.parent.certFact}"):
                CLI.abort("Parent CA cert fact '${config.parent.certFact}' is missing! It must be generated first.")
            
            parent_key_pem = AlloySecretsAPI.get("${config.parent.keySecret}")
            parent_cert_json = AlloyFactsAPI.get("${config.parent.certFact}")
            parent_key = AlloyTlsAPI.load_key_from_pem(parent_key_pem)
            parent_cert = AlloyTlsAPI.load_cert_from_pem(parent_cert_json.encode())
            
            key, cert = AlloyTlsAPI.generate_leaf_cert(
                subject="${config.subject}",
                not_before=${if config.notBefore == null then "None" else ''"${config.notBefore}"''},
                not_after="${config.notAfter}",
                san_dns=${builtins.toJSON config.san.domains},
                san_ips=${builtins.toJSON (extractIps config.san.ips)},
                parent_key=parent_key,
                parent_cert=parent_cert
            )
            
            AlloySecretsAPI.set(key_secret_name, AlloyTlsAPI.key_to_pem(key), force=True, add_to_git=add_to_git)
            AlloyFactsAPI.set(cert_fact_name, json.dumps(AlloyTlsAPI.cert_to_pem(cert).decode()), force=True, add_to_git=add_to_git)
      '';
    };
  };

  config.cli.apis."AlloyTlsAPI" = {
    description = "API for generating X.509 certificates for the cluster";
    libraries = { pkgs, ... }: [ pkgs.python3Packages.cryptography ];
    script = ''
      import datetime
      import ipaddress
      from cryptography import x509
      from cryptography.x509.oid import NameOID
      from cryptography.hazmat.primitives import hashes
      from cryptography.hazmat.primitives.asymmetric import ed25519
      from cryptography.hazmat.primitives import serialization

      class AlloyTlsAPI:
          """
          Provides helpers to generate CA and Leaf certificates using Ed25519.
          """
          
          @staticmethod
          def generate_private_key():
              return ed25519.Ed25519PrivateKey.generate()

          @staticmethod
          def key_to_pem(key) -> bytes:
              return key.private_bytes(
                  encoding=serialization.Encoding.PEM,
                  format=serialization.PrivateFormat.PKCS8,
                  encryption_algorithm=serialization.NoEncryption()
              )

          @staticmethod
          def cert_to_pem(cert) -> bytes:
              return cert.public_bytes(serialization.Encoding.PEM)

          @staticmethod
          def load_key_from_pem(pem_bytes: bytes):
              return serialization.load_pem_private_key(pem_bytes, password=None)

          @staticmethod
          def load_cert_from_pem(pem_bytes: bytes):
              return x509.load_pem_x509_certificate(pem_bytes)

          @staticmethod
          def _parse_time_spec(spec: str) -> datetime.datetime:
              if not spec:
                  return datetime.datetime.now(datetime.timezone.utc)
              
              now = datetime.datetime.now(datetime.timezone.utc)
              if spec.startswith("+") or spec.startswith("-") or spec[0].isdigit():
                  sign = -1 if spec.startswith("-") else 1
                  if spec.startswith("+") or spec.startswith("-"):
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
                      raise ValueError(f"Unknown duration format: {spec}")
                  return now + (sign * delta)
              
              return datetime.datetime.fromisoformat(spec.replace("Z", "+00:00"))

          @staticmethod
          def generate_ca_cert(subject: str, not_before: str, not_after: str, max_path_len: int, permitted_dns: list, permitted_ips: list, parent_key=None, parent_cert=None):
              key = AlloyTlsAPI.generate_private_key()
              
              subject_name = x509.Name([
                  x509.NameAttribute(NameOID.COMMON_NAME, subject),
              ])
              
              issuer_name = parent_cert.subject if parent_cert else subject_name
              issuer_key = parent_key if parent_key else key
              
              nb = AlloyTlsAPI._parse_time_spec(not_before) if not_before else (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1))
              na = AlloyTlsAPI._parse_time_spec(not_after)
              
              if nb > na:
                  raise ValueError(f"notBefore ({nb.isoformat()}) must be less than or equal to notAfter ({na.isoformat()})")
              
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
              ).add_extension(
                  x509.BasicConstraints(ca=True, path_length=max_path_len if max_path_len >= 0 else None), critical=True,
              ).add_extension(
                  x509.KeyUsage(
                      digital_signature=True, content_commitment=False, key_encipherment=False, 
                      data_encipherment=False, key_agreement=False, key_cert_sign=True, 
                      crl_sign=True, encipher_only=False, decipher_only=False
                  ), critical=True,
              ).add_extension(
                  x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False,
              )
              
              if parent_cert:
                  builder = builder.add_extension(
                      x509.AuthorityKeyIdentifier.from_issuer_public_key(parent_key.public_key()), critical=False,
                  )
              
              if permitted_dns or permitted_ips:
                  permitted = []
                  for dns in permitted_dns:
                      permitted.append(x509.DNSName(dns))
                  for ip_obj in permitted_ips:
                      network = ipaddress.ip_network(f"{ip_obj['addr']}/{ip_obj['prefixLength']}", strict=False)
                      permitted.append(x509.IPAddress(network))
                  
                  if permitted:
                      builder = builder.add_extension(
                          x509.NameConstraints(permitted_subtrees=permitted, excluded_subtrees=None), critical=True
                      )

              cert = builder.sign(issuer_key, None)
              return key, cert

          @staticmethod
          def generate_leaf_cert(subject: str, not_before: str, not_after: str, san_dns: list, san_ips: list, parent_key, parent_cert):
              key = AlloyTlsAPI.generate_private_key()
              
              subject_name = x509.Name([
                  x509.NameAttribute(NameOID.COMMON_NAME, subject),
              ])
              
              nb = AlloyTlsAPI._parse_time_spec(not_before) if not_before else (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1))
              na = AlloyTlsAPI._parse_time_spec(not_after)
              
              if nb > na:
                  raise ValueError(f"notBefore ({nb.isoformat()}) must be less than or equal to notAfter ({na.isoformat()})")
              
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
              ).add_extension(
                  x509.BasicConstraints(ca=False, path_length=None), critical=True,
              ).add_extension(
                  x509.KeyUsage(
                      digital_signature=True, content_commitment=False, key_encipherment=False, 
                      data_encipherment=False, key_agreement=False, key_cert_sign=False, 
                      crl_sign=False, encipher_only=False, decipher_only=False
                  ), critical=True,
              ).add_extension(
                  x509.ExtendedKeyUsage([
                      x509.oid.ExtendedKeyUsageOID.SERVER_AUTH, 
                      x509.oid.ExtendedKeyUsageOID.CLIENT_AUTH
                  ]), critical=False,
              ).add_extension(
                  x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False,
              ).add_extension(
                  x509.AuthorityKeyIdentifier.from_issuer_public_key(parent_key.public_key()), critical=False,
              )
              
              sans = []
              for dns in san_dns:
                  sans.append(x509.DNSName(dns))
              for ip_obj in san_ips:
                  sans.append(x509.IPAddress(ipaddress.ip_address(ip_obj['addr'])))
                  
              if sans:
                  builder = builder.add_extension(x509.SubjectAlternativeName(sans), critical=False)
                  
              cert = builder.sign(parent_key, None)
              return key, cert
    '';
  };
}
