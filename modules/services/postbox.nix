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
            default = "postboxes/${srvName}/users/${name}/login";
          };
          passwdSecret = lib.mkOption {
            type = lib.types.str;
            default = "postboxes/${srvName}/users/${name}/passwd";
          };
          passwdGenerator = lib.mkOption {
            type = lib.types.str;
            default = "postboxes/${srvName}/users/${name}/passwd";
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
          jmap.endpoint = lib.mkOption {
            type = lib.types.str;
            readOnly = true;
            default = "postbox-${name}-jmap";
          };
          domain = lib.mkOption {
            type = alib.types.zoneNode;
          };
          users = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule (userSubmodule name));
          };
        };
      };

      mkService =
        srvName: srv:
        let
          domain = lib.removeSuffix "." (alloy.dns.resolveNode srv.domain);
          relayEndpoint = alloy.endpoints.${srv.smtp.relayEndpoint};
        in
        {
          assertions = [ ];

          facts = lib.mapAttrs' (userName: user: lib.nameValuePair user.loginFact { }) srv.users;
          secrets = lib.mapAttrs' (userName: user: lib.nameValuePair user.passwdSecret { }) srv.users;

          generators.instances = lib.mapAttrs' (
            userName: user:
            lib.nameValuePair user.passwdGenerator {
              package =
                { pkgs, ... }:
                pkgs.writeShellScriptBin "postbox-gen-passwd" ''
                  pass=$(${pkgs.openssl}/bin/openssl rand -base64 32)
                  "$ALLOY_BIN" secrets set "${user.passwdSecret}" <<< "$pass"
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

            ${srv.jmap.endpoint} = {
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
                alloy.endpoints.${srv.jmap.endpoint}.domain
              ];

              volumes."cyrus" = {
                path = "/var/lib/cyrus";
                driver.directory = { };
                permissions = {
                  owner = "cyrus";
                  group = "postbox";
                  mode = "0750";
                };
              };

              secrets =
                lib.pipe srv.users [
                  (lib.mapAttrsToList (
                    userName: user: {
                      ${user.passwdSecret} = { };
                    }
                  ))
                  lib.mkMerge
                ]
                // {
                  ${jail.static-ca.keySecret} = {
                    permissions = {
                      owner = "root";
                      group = "smtpd";
                      mode = "0640";
                    };
                  };
                };

              secretTemplates."userdb" = {
                template = lib.concatMapAttrsStringSep "\n" (
                  userName: user:
                  "${lib.removePrefix "\n" (lib.removeSuffix "\n" alloy.facts.${user.loginFact}.value)}@${domain}:${
                    jail.secrets.${user.passwdSecret}.placeholder
                  }"
                ) srv.users;
                path = "/var/lib/cyrus/users.txt";
                permissions = {
                  owner = "cyrus";
                  group = "postbox";
                  mode = "0440";
                };
              };

              nixosModule = { pkgs, ... }: {
                networking.firewall.allowedTCPPorts = [
                  465
                  25
                  443
                  993
                ];

                users.groups."postbox" = { };

                users.users."smtpd" = {
                  extraGroups = [ "postbox" ];
                };
                users.users."cyrus" = {
                  group = lib.mkForce "postbox";
                };

                systemd.services.opensmtpd.wants = [ "network-online.target" ];
                systemd.services.opensmtpd.after = [ "network-online.target" ];
                systemd.services.opensmtpd.path = [ pkgs.mkpasswd ];
                systemd.services.opensmtpd.preStart = ''
                  while IFS=: read -r user pass; do
                    if [ -n "$pass" ]; then
                      hash=$(mkpasswd -m sha-512 "$pass")
                      echo "$user:$hash"
                    fi
                  done < /var/lib/cyrus/users.txt > /var/lib/cyrus/users-smtp.txt
                  chown root:smtpd /var/lib/cyrus/users-smtp.txt
                  chmod 0440 /var/lib/cyrus/users-smtp.txt
                '';

                services.opensmtpd = {
                  enable = true;

                  extraServerArgs = [
                    "-T"
                    "all"
                  ];

                  serverConfiguration = ''
                    pki "static-ca" cert "${alloy.facts.${jail.static-ca.certFact}.path}"
                    pki "static-ca" key "${jail.secrets.${jail.static-ca.keySecret}.path}"
                    ca "static-ca" cert "${alloy.facts.${alloy.static-ca.certFact}.path}"

                    table vdomains { "${domain}" }
                    table relay_ips { ${lib.concatMapStringsSep ", " (t: t.ipv6) relayEndpoint.targets} }
                    table user_passwords file:/var/lib/cyrus/users-smtp.txt

                    ${lib.concatMapAttrsStringSep "\n" (_: overlay: ''
                      listen on ${overlay.ipv6} port 465 smtps ${lib.optionalString srv.smtps.proxyV2 "proxy-v2"} pki "static-ca" ca "static-ca" hostname "${domain}" auth <user_passwords>
                      listen on ${overlay.ipv6} port 25 tls-require verify pki "static-ca" ca "static-ca" hostname "${domain}"
                    '') jail.overlays}
                    listen on socket

                    action "to_cyrus" lmtp "/run/cyrus/lmtp" rcpt-to
                    action "to_relay" relay \
                      host "tls://${relayEndpoint.domain}:${toString relayEndpoint.port}" \
                      helo "${domain}" \
                      pki "static-ca" \
                      ca "static-ca"

                    match tls from src <relay_ips> for domain <vdomains> action "to_cyrus"
                    match auth from any for domain <vdomains> action "to_relay"
                    match from local for domain <vdomains> action "to_relay"

                    match auth for any action "to_relay"
                    match from local for any action "to_relay"
                  '';
                };

                services.cyrus-imap = {
                  enable = true;
                  group = "postbox";
                  cyrusSettings = {
                    START = {
                      recover = {
                        cmd = [
                          "ctl_cyrusdb"
                          "-r"
                        ];
                      };
                    };
                    SERVICES = {
                      lmtpunix = {
                        cmd = [ "lmtpd" ];
                        listen = "/run/cyrus/lmtp";
                      };
                      jmap = {
                        cmd = [
                          "httpd"
                          "-j"
                          "-s"
                        ];
                        listen = 443;
                        prefork = 0;
                      };
                      imaps = {
                        cmd = [
                          "imapd"
                          "-s"
                        ];
                        listen = 993;
                        prefork = 0;
                      };
                    };
                    EVENTS = {
                      checkpoint = {
                        cmd = [
                          "ctl_cyrusdb"
                          "-c"
                        ];
                        period = 30;
                      };
                      deleteprune = {
                        at = 430;
                        cmd = [
                          "cyr_expire"
                          "-E"
                          "4"
                          "-D"
                          "28"
                        ];
                      };
                      delprune = {
                        at = 400;
                        cmd = [
                          "cyr_expire"
                          "-E"
                          "3"
                        ];
                      };
                      expungeprune = {
                        at = 445;
                        cmd = [
                          "cyr_expire"
                          "-E"
                          "4"
                          "-X"
                          "28"
                        ];
                      };
                      tlsprune = {
                        at = 400;
                        cmd = [
                          "tls_prune"
                        ];
                      };
                    };
                    DAEMON = { };
                  };
                  imapdSettings = {
                    defaultdomain = domain;

                    sasl_pwcheck_method = "auxprop";
                    sasl_auxprop_plugin = "authfile";
                    sasl_authfile_path = "/var/lib/cyrus/users.txt";
                    sasl_mech_list = "PLAIN LOGIN";

                    jmap_enable = "yes";
                    httpmodules = [
                      "jmap"
                      "caldav"
                      "carddav"
                    ];
                    jmap_max_size_upload = 50000000;

                    tls_server_cert = alloy.facts.${jail.static-ca.certFact}.path;
                    tls_server_key = jail.secrets.${jail.static-ca.keySecret}.path;
                    tls_server_cafile = alloy.facts.${alloy.static-ca.certFact}.path;
                    tls_client_ca_file = alloy.facts.${jail.static-ca.certFact}.path;
                    tls_required_cert = 1;

                    lmtp_downcase_final_addr = true;
                    autocreate_inbox = "1";
                    autocreate_folders = "Sent|Drafts|Trash|Junk";

                    lmtpsocket = "/run/cyrus/lmtp";
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
