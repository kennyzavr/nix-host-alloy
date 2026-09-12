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

      userSubmodule = srvName: { config, name, ... }: {
        options = {
          loginFact = lib.mkOption {
            # TODO check value format
            type = lib.types.str;
            readOnly = true;
            default = "postboxes/${srvName}/users/${name}/login";
          };
          hashedPasswdSecret = lib.mkOption {
            type = lib.types.str;
            readOnly = true;
            default = "postboxes/${srvName}/users/${name}/hashed-passwd";
          };
          hashedPasswdGenerator = lib.mkOption {
            type = lib.types.str;
            readOnly = true;
            default = "postboxes/${srvName}/users/${name}/hashed-passwd";
          };
        };
      };

      serviceSubmodule = { config, name, ... }: {
        options = {
          host = lib.mkOption {
            type = lib.types.str;
          };
          overlays = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (lib.types.submodule { });
          };
          smtp = {
            endpoint = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              default = "postbox-${name}-smtp";
            };
            relayEndpoint = lib.mkOption {
              type = lib.types.str;
            };
          };
          smtps = {
            proxyV2 = lib.mkOption {
              default = true;
              type = lib.types.bool;
            };
            endpoint = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              default = "postbox-${name}-smtps";
            };
          };
          imap = {
            proxyV2 = lib.mkOption {
              default = true;
              type = lib.types.bool;
            };
            endpoint = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              default = "postbox-${name}-imap";
            };
          };
          https = {
            proxyV2 = lib.mkOption {
              default = false;
              type = lib.types.bool;
            };
            endpoint = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              default = "postbox-${name}-https";
            };
          };
          domain = lib.mkOption {
            type = alib.types.zoneNode;
          };
          extraDomains = lib.mkOption {
            default = [ ];
            type = lib.types.listOf alib.types.zoneNode;
          };
          admin = lib.mkOption {
            default = null;
            type = lib.types.nullOr lib.types.str;
          };
          users = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule (userSubmodule name));
          };
        };
      };

      mkService =
        srvName: srv:
        let
          mkDomain = d: lib.removeSuffix "." (alloy.dns.resolveNode d);
          relayEndpoint = alloy.endpoints.${srv.smtp.relayEndpoint};
        in
        {
          assertions = [ ];

          facts = lib.mapAttrs' (userName: user: lib.nameValuePair user.loginFact { }) srv.users;
          secrets = lib.mapAttrs' (userName: user: lib.nameValuePair user.hashedPasswdSecret { }) srv.users;

          generators.instances = lib.mapAttrs' (
            userName: user:
            lib.nameValuePair user.hashedPasswdGenerator {
              package =
                { pkgs, ... }:
                pkgs.writeShellScriptBin "postbox-gen-passwd" ''
                  # TODO: add cli command to check secret existance or check just the store file
                  # if [ "''${ALLOY_FORCE:-0}" = "1" ] || ! [ -r "${alloy.secrets.${user.hashedPasswdSecret}.file}" ]; then
                    read -r -s -p "Enter password for ${userName}: " pass
                    echo
                    hash=$(printf "%s\n" "$pass" | ${pkgs.mkpasswd}/bin/mkpasswd -m sha-512 -s)
                    "$ALLOY_BIN" secrets set "${user.hashedPasswdSecret}" <<< "$hash"
                  # fi
                '';
            }
          ) srv.users;

          endpoints = {
            ${srv.smtp.endpoint} = {
              port = 25;
              targets = lib.mapAttrsToList (overlayName: _: {
                ipv6 = alloy.jails."postbox-${srvName}".overlays.${overlayName}.ipv6;
                overlay = overlayName;
              }) srv.overlays;
            };

            ${srv.smtps.endpoint} = {
              port = 465;
              targets = lib.mapAttrsToList (overlayName: _: {
                ipv6 = alloy.jails."postbox-${srvName}".overlays.${overlayName}.ipv6;
                overlay = overlayName;
              }) srv.overlays;
            };

            ${srv.imap.endpoint} = {
              port = 993;
              targets = lib.mapAttrsToList (overlayName: _: {
                ipv6 = alloy.jails."postbox-${srvName}".overlays.${overlayName}.ipv6;
                overlay = overlayName;
              }) srv.overlays;
            };

            ${srv.https.endpoint} = {
              port = 443;
              targets = lib.mapAttrsToList (overlayName: _: {
                ipv6 = alloy.jails."postbox-${srvName}".overlays.${overlayName}.ipv6;
                overlay = overlayName;
              }) srv.overlays;
            };
          };

          jails."postbox-${srvName}" =
            { config, ... }:
            let
              jail = config;
            in
            {
              host = srv.host;

              overlays = lib.mapAttrs (_: _: { }) srv.overlays;

              static-ca.domains = [
                alloy.endpoints.${srv.smtp.endpoint}.domain
                alloy.endpoints.${srv.smtps.endpoint}.domain
                alloy.endpoints.${srv.imap.endpoint}.domain
                alloy.endpoints.${srv.https.endpoint}.domain
              ];

              volumes."dovecot" = {
                path = "/var/lib/dovecot";
                driver.directory = { };
                permissions = {
                  owner = "dovecot2";
                  group = "dovecot2";
                  mode = "0755";
                };
              };

              secrets =
                lib.pipe srv.users [
                  (lib.mapAttrsToList (
                    userName: user: {
                      ${user.hashedPasswdSecret} = { };
                    }
                  ))
                  lib.mkMerge
                ]
                // {
                  ${jail.static-ca.keySecret} = {
                    permissions = {
                      owner = "root";
                      group = "postfix";
                      mode = "0640";
                    };
                  };
                };

              secretTemplates."userdb" = {
                template = lib.concatMapAttrsStringSep "\n" (
                  userName: user:
                  let
                    login = lib.removePrefix "\n" (lib.removeSuffix "\n" alloy.facts.${user.loginFact}.value);
                    hash = jail.secrets.${user.hashedPasswdSecret}.placeholder;
                  in
                  lib.concatMapStringsSep "\n" (d: "${login}@${mkDomain d}:${hash}") (
                    [ srv.domain ] ++ srv.extraDomains
                  )
                ) srv.users;
                permissions = {
                  owner = "dovecot2";
                  group = "dovecot2";
                  mode = "0440";
                };
              };

              nixosModule = { pkgs, config, ... }: {
                networking.firewall.allowedTCPPorts = [
                  465
                  25
                  443
                  993
                ];

                services.nginx = {
                  enable = true;
                  virtualHosts."default" = {
                    default = true;
                    listen = [
                      {
                        addr = "[::]";
                        port = 443;
                        ssl = true;
                        proxyProtocol = srv.https.proxyV2;
                      }
                    ];
                    sslCertificate = alloy.facts.${jail.static-ca.certFact}.path;
                    sslCertificateKey = jail.secrets.${jail.static-ca.keySecret}.path;
                    
                    locations."/mail/config-v1.1.xml".alias = pkgs.writeText "autoconfig.xml" ''
                      <?xml version="1.0" encoding="UTF-8"?>
                      <clientConfig version="1.1">
                        <emailProvider id="${mkDomain srv.domain}">
                          <domain>${mkDomain srv.domain}</domain>
                          <displayName>${mkDomain srv.domain} Mail</displayName>
                          <displayShortName>${mkDomain srv.domain}</displayShortName>
                          <incomingServer type="imap">
                            <hostname>${mkDomain srv.domain}</hostname>
                            <port>993</port>
                            <socketType>SSL</socketType>
                            <authentication>password-cleartext</authentication>
                            <username>%EMAILADDRESS%</username>
                          </incomingServer>
                          <outgoingServer type="smtp">
                            <hostname>${mkDomain srv.domain}</hostname>
                            <port>465</port>
                            <socketType>SSL</socketType>
                            <authentication>password-cleartext</authentication>
                            <username>%EMAILADDRESS%</username>
                          </outgoingServer>
                        </emailProvider>
                      </clientConfig>
                    '';

                    locations."/autodiscover/autodiscover.xml" = {
                      extraConfig = ''
                        error_page 405 =200 $uri;
                      '';
                      alias = pkgs.writeText "autodiscover.xml" ''
                        <?xml version="1.0" encoding="utf-8" ?>
                        <Autodiscover xmlns="http://schemas.microsoft.com/exchange/autodiscover/responseschema/2006">
                          <Response xmlns="http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a">
                            <Account>
                              <AccountType>email</AccountType>
                              <Action>settings</Action>
                              <Protocol>
                                <Type>IMAP</Type>
                                <Server>${mkDomain srv.domain}</Server>
                                <Port>993</Port>
                                <DomainRequired>off</DomainRequired>
                                <LoginName></LoginName>
                                <SPA>off</SPA>
                                <SSL>on</SSL>
                                <AuthRequired>on</AuthRequired>
                              </Protocol>
                              <Protocol>
                                <Type>SMTP</Type>
                                <Server>${mkDomain srv.domain}</Server>
                                <Port>465</Port>
                                <DomainRequired>off</DomainRequired>
                                <LoginName></LoginName>
                                <SPA>off</SPA>
                                <SSL>on</SSL>
                                <AuthRequired>on</AuthRequired>
                                <UsePOPAuth>on</UsePOPAuth>
                                <SMTPLast>off</SMTPLast>
                              </Protocol>
                            </Account>
                          </Response>
                        </Autodiscover>
                      '';
                    };

                    locations."/.well-known/mta-sts.txt".alias = pkgs.writeText "mta-sts.txt" ''
                      version: STSv1
                      mode: enforce
                      mx: ${mkDomain srv.domain}
                      mx: *.${mkDomain srv.domain}
                      max_age: 604800
                    '';
                  };
                };

                systemd.services.postfix.wants = [ "network-online.target" ];
                systemd.services.postfix.after = [ "network-online.target" ];

                services.postfix = {
                  enable = true;
                  enableSubmission = false;
                  enableSmtp = false;
                  enableSubmissions = false;
                  virtual = lib.mkIf (srv.admin != null) (
                    lib.pipe ([ srv.domain ] ++ srv.extraDomains) [
                      (lib.map (
                        domain:
                        let
                          admin = alloy.facts.${srv.users.${srv.admin}.loginFact}.value;
                        in
                        [
                          "postmaster@${mkDomain domain} ${admin}@${mkDomain srv.domain}"
                          "hostmaster@${mkDomain domain} ${admin}@${mkDomain srv.domain}"
                          "abuse@${mkDomain domain} ${admin}@${mkDomain srv.domain}"
                          "root@${mkDomain domain} ${admin}@${mkDomain srv.domain}"
                        ]
                      ))
                    ]
                  );
                  settings.main = {
                    myhostname = mkDomain srv.domain;
                    mydestination = "";
                    mynetworks = lib.map (t: "[${t.ipv6}]") relayEndpoint.targets;

                    virtual_mailbox_domains = [ (mkDomain srv.domain) ] ++ (lib.map mkDomain srv.extraDomains);

                    virtual_transport = "lmtp:unix:/run/dovecot2/lmtp";
                    relayhost = [ "[${relayEndpoint.domain}]:${toString relayEndpoint.port}" ];

                    smtpd_tls_cert_file = alloy.facts.${jail.static-ca.certFact}.path;
                    smtpd_tls_key_file = jail.secrets.${jail.static-ca.keySecret}.path;
                    smtpd_tls_CAfile = alloy.facts.${alloy.static-ca.certFact}.path;
                    smtpd_tls_security_level = "encrypt";

                    smtp_tls_cert_file = alloy.facts.${jail.static-ca.certFact}.path;
                    smtp_tls_key_file = jail.secrets.${jail.static-ca.keySecret}.path;
                    smtp_tls_CAfile = alloy.facts.${alloy.static-ca.certFact}.path;
                    smtp_tls_security_level = "encrypt";
                  };
                  settings.master = {
                    "25" = {
                      type = "inet";
                      private = false;
                      command = "smtpd";
                      args = [
                        "-o smtpd_tls_security_level=encrypt"
                        "-o smtpd_tls_req_ccert=yes"
                        "-o smtpd_client_restrictions=permit_mynetworks,reject"
                        "-o smtpd_relay_restrictions=reject_unauth_destination"
                      ];
                    };
                    "465" = {
                      type = "inet";
                      private = false;
                      command = "smtpd";
                      args = [
                        "-o smtpd_tls_security_level=encrypt"
                        "-o smtpd_tls_req_ccert=yes"
                        "-o smtpd_tls_wrappermode=yes"
                        "-o smtpd_sasl_auth_enable=yes"
                        "-o smtpd_sasl_type=dovecot"
                        "-o smtpd_sasl_path=/run/dovecot2/auth"
                        "-o smtpd_client_restrictions=permit_sasl_authenticated,reject"
                      ]
                      ++ lib.optional srv.smtps.proxyV2 "-o smtpd_upstream_proxy_protocol=haproxy";
                    };
                  };
                };

                services.dovecot2 = {
                  enable = true;
                  settings = {
                    dovecot_config_version = config.services.dovecot2.package.version;
                    dovecot_storage_version = config.services.dovecot2.package.version;

                    protocols = {
                      imap = true;
                      lmtp = true;
                      pop3 = false;
                    };

                    first_valid_uid = 1;

                    mail_driver = "maildir";
                    mail_path = "/var/lib/dovecot/mail/%{user | username}";

                    ssl = "required";
                    ssl_server_cert_file = alloy.facts.${jail.static-ca.certFact}.path;
                    ssl_server_key_file = jail.secrets.${jail.static-ca.keySecret}.path;
                    ssl_server_ca_file = alloy.facts.${alloy.static-ca.certFact}.path;
                    ssl_server_request_client_cert = true;

                    haproxy_trusted_networks = lib.mapAttrsToList (
                      overlayName: _: "${alloy.overlays.${overlayName}.ipv6Prefix}::/48"
                    ) srv.overlays;

                    "passdb passwd-file" = {
                      passwd_file_path = jail.secretTemplates."userdb".path;
                    };
                    "userdb static" = {
                      fields = {
                        uid = "dovecot2";
                        gid = "dovecot2";
                        home = "/var/lib/dovecot/mail/%{user | username}";
                      };
                    };

                    service = [
                      {
                        _section = {
                          name = "imap-login";
                        };
                        "inet_listener imaps" = {
                          port = 993;
                          ssl = "yes";
                          haproxy = if srv.imap.proxyV2 then "yes" else "no";
                        };
                        "inet_listener imap" = {
                          port = 0;
                        };
                      }
                      {
                        _section = {
                          name = "lmtp";
                        };
                        "unix_listener lmtp" = {
                          mode = "0660";
                          user = "postfix";
                          group = "postfix";
                        };
                      }
                      {
                        _section = {
                          name = "auth";
                        };
                        "unix_listener auth" = {
                          mode = "0660";
                          user = "postfix";
                          group = "postfix";
                        };
                      }
                    ];
                  };
                };
              };
            };
        };
    in
    {
      options.services.postbox = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule serviceSubmodule);
      };

      config =
        let
          configs = lib.pipe alloy.services.postbox [
            (lib.mapAttrsToList mkService)
            lib.flatten
          ];
        in
        {
          assertions = lib.mkMerge (lib.map (c: c.assertions) configs);
          endpoints = lib.mkMerge (lib.map (c: c.endpoints) configs);
          secrets = lib.mkMerge (lib.map (c: c.secrets) configs);
          facts = lib.mkMerge (lib.map (c: c.facts) configs);
          generators = lib.mkMerge (lib.map (c: c.generators) configs);
          jails = lib.mkMerge (lib.map (c: c.jails) configs);
        };
    };
}
