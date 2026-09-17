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

      profileSubmodule = { config, name, ... }: {
        options = {
          remark = lib.mkOption {
            default = name;
            type = lib.types.str;
          };
          address = lib.mkOption {
            default = null;
            type = lib.types.nullOr lib.types.str;
          };
        };
      };

      serviceSubmodule = { config, name, ... }: {
        options = {
          enable = lib.mkOption {
            default = true;
            type = lib.types.bool;
          };
          domain = lib.mkOption {
            type = alib.types.zoneNode;
          };
          profiles = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (lib.types.submodule profileSubmodule);
          };
          countryCodes = lib.mkOption {
            default = [ ];
            type = lib.types.listOf lib.types.str;
          };
          tunnelEndpoint = lib.mkOption {
            readOnly = true;
            type = lib.types.str;
            default = "xhttp-proxy-tunnel";
          };
          subsEndpoint = lib.mkOption {
            readOnly = true;
            type = lib.types.str;
            default = "xhttp-proxy-subs";
          };
          fallbackEndpoint = lib.mkOption {
            type = lib.types.str;
          };
          host = lib.mkOption {
            type = lib.types.str;
          };
          overlays = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (lib.types.submodule { });
          };
          clients = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (lib.types.submodule { });
          };
        };
      };

      mkServerConfig = srvName: srv: jail: ''
        {
          "log": {
              "loglevel": "debug"
          },
          "inbounds": [
            {
              "tag": "proxy",
              "listen": "127.0.0.1",
              "port": 8080,
              "protocol": "vless",
              "settings": {
                "decryption": "none",
                "clients": [${
                  lib.pipe srv.clients [
                    (lib.mapAttrsToList (
                      clientName: _: ''
                        {
                          "id": "${jail.secrets."xhttp-proxy/${srvName}/clients/${clientName}/id".placeholder}",
                          "flow": ""
                        }
                      ''
                    ))
                    (lib.concatStringsSep "\n")
                  ]
                }]
              },
              "sniffing": {
                "enable": true,
                "destOverride": [
                  "http",
                  "tls",
                  "quic"
                ]
              },
              "streamSettings": {
                "network": "xhttp",
                "security": "none",
                "xhttpSettings": {
                  "path": "${jail.secrets."xhttp-proxy/${srvName}/path".placeholder}",
                  "host": "${lib.removeSuffix "." (alloy.dns.resolveNode srv.domain)}",
                  "mode": "auto"
                }
              }
            }
          ],
          "outbounds": [
            {
                "protocol": "freedom",
                "settings": {
                    "domainStrategy": "UseIPv4"
                },
                "tag": "direct"
            },
            {
                "protocol": "blackhole",
                "tag": "block"
            }
          ],
          "dns": {
              "servers": [
                  "1.1.1.1"
              ]
          },
          "routing": {
            "domainStrategy": "IPIfNonMatch",
            "rules": [
              {
                  "domain": [
                      "geosite:category-ads-all"
                  ],
                  "outboundTag": "block",
                  "type": "field"
              },
              {
                  "ip": [
                      "geoip:private"
                  ],
                  "outboundTag": "block",
                  "type": "field"
              },
              ${lib.concatMapStringsSep "\n" (code: ''
                {
                    "domain": [
                        "geosite:category-${code}"
                    ],
                    "outboundTag": "block",
                    "type": "field"
                },
                {
                    "ip": [
                        "geoip:${code}"
                    ],
                    "outboundTag": "block",
                    "type": "field"
                },
              '') srv.countryCodes}
              {
                  "inboundTag": [
                      "proxy"
                  ],
                  "outboundTag": "direct",
                  "type": "field"
              }
            ]
          }
        }
      '';

      mkClientProfile = srv: profileName: profile: ''
        {
          "remarks": ${builtins.toJSON profile.remark},
          "inbounds": [
            {
              "listen": "127.0.0.1",
              "port": 10808,
              "protocol": "socks",
              "settings": {
                "udp": true,
                "auth": "noauth"
              },
              "sniffing": {
                "enabled": true,
                "routeOnly": true,
                "destOverride": ["http", "tls", "quic"]
              }
            },
            {
              "listen": "127.0.0.1",
              "port": 10809,
              "protocol": "http",
              "settings": {
                "udp": true,
                "auth": "noauth"
              },
              "sniffing": {
                "enabled": true,
                "routeOnly": true,
                "destOverride": ["http", "tls", "quic"]
              }
            }
          ],
          "outbounds": [
            {
              "tag": "proxy",
              "protocol": "vless",
              "settings": {
                "vnext": [
                  {
                    "address": ${
                      builtins.toJSON (
                        if profile.address == null then
                          lib.removeSuffix "." (alloy.dns.resolveNode srv.domain)
                        else
                          profile.address
                      )
                    },
                    "port": 443,
                    "users":  [
                      {
                        "id": "%%CLIENT_ID%%",
                        "encryption": "none"
                      }
                    ]
                  }
                ]
              },
              "streamSettings": {
                "network": "xhttp",
                "security": "tls",
                "tlsSettings": {
                  "serverName": "${lib.removeSuffix "." (alloy.dns.resolveNode srv.domain)}"
                },
                "xhttpSettings": {
                  "path": "%%PATH%%",
                  "host": "${lib.removeSuffix "." (alloy.dns.resolveNode srv.domain)}",
                  "mode": "auto"
                }
              }
            },
            {
              "protocol": "freedom",
              "settings": {
                "domainStrategy": "UseIPv4"
              },
              "tag": "direct"
            },
            {
              "protocol": "blackhole",
              "tag": "block"
            }
          ],
          "dns": {
              "servers": [
                  "1.1.1.1",
                  "8.8.8.8",
                  "8.8.4.4"
              ],
              "queryStrategy": "UseIPv4"
          },
          "routing": {
            "domainStrategy": "AsIs",
            "domainMatcher": "hybrid",
            "rules": [
              {
                "domain": [
                  "geosite:category-ads-all"
                ],
                "outboundTag": "block",
                "type": "field"
              },
              {
                "ip": [
                    "geoip:private"
                ],
                "outboundTag": "direct",
                "type": "field"
              },
              ${lib.concatMapStringsSep "\n" (code: ''
                {
                    "domain": [
                        "geosite:category-${code}"
                    ],
                    "outboundTag": "direct",
                    "type": "field"
                },
                {
                    "ip": [
                        "geoip:${code}"
                    ],
                    "outboundTag": "direct",
                    "type": "field"
                },
              '') srv.countryCodes}
              {
                "network": "tcp,udp",
                "outboundTag": "proxy",
                "type": "field"
              }
            ]
          }
        }                          
      '';

      mkService = srvName: srv: {
        assertions = [
          {
            assertion = srv.overlays != { };
            message = "[Alloy] Service 'xhttp-proxy.${srvName}': you must specify at least one network overlay in 'overlays' for the endpoint targets.";
          }
          {
            assertion = srv.profiles != { };
            message = "[Alloy] Service 'xhttp-proxy.${srvName}': you must specify at least one profile.";
          }
          {
            assertion = lib.all (o: builtins.hasAttr o srv.overlays) (
              builtins.attrNames alloy.endpoints.${srv.fallbackEndpoint}.overlays
            );
            message = "[Alloy] Service 'xhttp-proxy.${srvName}': all overlays from fallbackEndpoint '${srv.fallbackEndpoint}' must be present in the service's 'overlays'.";
          }
        ];

        endpoints.${srv.tunnelEndpoint} = {
          port = 443;
          httpBuffering = false;
          targets = lib.mapAttrsToList (o: _: {
            ipv6 = alloy.jails."xhttp-proxy-${srvName}".overlays.${o}.ipv6;
            overlay = o;
          }) srv.overlays;
        };

        endpoints.${srv.subsEndpoint} = {
          port = 8443;
          targets = lib.mapAttrsToList (o: _: {
            ipv6 = alloy.jails."xhttp-proxy-${srvName}".overlays.${o}.ipv6;
            overlay = o;
          }) srv.overlays;
        };

        secrets = {
          "xhttp-proxy/${srvName}/path" = { };
        }
        // (lib.mapAttrs' (
          clientName: _: lib.nameValuePair "xhttp-proxy/${srvName}/clients/${clientName}/id" { }
        ) srv.clients);

        generators.instances = {
          "xhttp-proxy/${srvName}/path" = {
            secrets."xhttp-proxy/${srvName}/path" = { };
            tags = [
              "xhttp-proxy"
              "xhttp-proxy/${srvName}"
            ];
            package =
              { pkgs, ... }:
              pkgs.writeShellApplication {
                name = "xhttp-proxy-path-generator";
                runtimeInputs = [ pkgs.util-linux ];
                text = ''
                  path="/$(uuidgen)"
                  "$ALLOY_BIN" secrets set "xhttp-proxy/${srvName}/path" <<< "$path"
                '';
              };
          };
        }
        // (lib.mapAttrs' (
          clientName: _:
          lib.nameValuePair "xhttp-proxy/${srvName}/clients/${clientName}" {
            secrets."xhttp-proxy/${srvName}/clients/${clientName}/id" = { };
            secrets."xhttp-proxy/${srvName}/clients/${clientName}/config" = { };
            tags = [
              "xhttp-proxy"
              "xhttp-proxy/${srvName}"
            ];
            wants = [
              "xhttp-proxy/${srvName}/path"
            ];
            package =
              { pkgs, ... }:
              let
                template = pkgs.writeText "xhttp-proxy-${srvName}-client-template" ''
                  [
                    ${lib.concatMapAttrsStringSep ",\n" (mkClientProfile srv) srv.profiles}
                  ]
                '';
              in
              pkgs.writeShellApplication {
                name = "xhttp-proxy-client-generator";
                runtimeInputs = [
                  pkgs.util-linux
                  pkgs.jq
                ];
                text = ''
                  id=$(uuidgen)
                  path=$("$ALLOY_BIN" secrets get "xhttp-proxy/${srvName}/path")
                  config=$(jq --arg id "$id" --arg path "$path" 'walk(if type == "string" then gsub("%%CLIENT_ID%%"; $id) | gsub("%%PATH%%"; $path) else . end)' "${template}")

                  "$ALLOY_BIN" secrets set "xhttp-proxy/${srvName}/clients/${clientName}/id" <<< "$id"
                  "$ALLOY_BIN" secrets set "xhttp-proxy/${srvName}/clients/${clientName}/config" <<< "$config"
                '';
              };
          }

        ) srv.clients);

        jails."xhttp-proxy-${srvName}" =
          { config, ... }:
          let
            jail = config;
          in
          {
            host = srv.host;

            uplink.allowEgress = true;

            overlays = lib.mapAttrs (_: _: { }) srv.overlays;

            endpoints.${srv.tunnelEndpoint} = { };
            endpoints.${srv.subsEndpoint} = { };

            mtls.permissions = {
              owner = "nginx";
              group = "nginx";
              mode = "0640";
            };

            volumes."filebrowser-db" = {
              path = "/var/lib/filebrowser";
              driver.directory = { };
              permissions = {
                owner = "filebrowser";
                group = "filebrowser";
                mode = "0750";
              };
            };

            secrets = {
              "xhttp-proxy/${srvName}/path" = {
                permissions = {
                  owner = "xray";
                  group = "xray";
                  mode = "0640";
                };
              };
            }
            // (lib.mapAttrs' (
              clientName: _:
              lib.nameValuePair "xhttp-proxy/${srvName}/clients/${clientName}/id" {
                permissions = {
                  owner = "nginx";
                  group = "nginx";
                  mode = "0640";
                };
              }
            ) srv.clients)
            // (lib.mapAttrs' (
              clientName: _:
              lib.nameValuePair "xhttp-proxy/${srvName}/clients/${clientName}/config" {
                permissions = {
                  owner = "nginx";
                  group = "nginx";
                  mode = "0640";
                };
              }
            ) srv.clients);

            secretTemplates = {
              "server-config" = {
                permissions = {
                  owner = "xray";
                  group = "xray";
                  mode = "0640";
                };
                template = mkServerConfig srvName srv jail;
              };
              "tunnel-locations" = {
                permissions = {
                  owner = "nginx";
                  group = "nginx";
                  mode = "0640";
                };
                template = ''
                  location ^~ ${jail.secrets."xhttp-proxy/${srvName}/path".placeholder}/ {
                    proxy_pass http://127.0.0.1:8080;

                    proxy_set_header Host $host;
                    proxy_set_header X-Real-IP $remote_addr;
                    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

                    proxy_buffering off;
                  }

                  location / {
                    proxy_pass http://unix:/run/nginx/xhttp-proxy-fallback.sock;

                    proxy_set_header Host $host;
                    proxy_set_header X-Real-IP $remote_addr;
                    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                  }
                '';
              };
            };

            nixosModule = { pkgs, ... }: {
              networking.firewall.allowedTCPPorts = [
                443
                8443
              ];
              networking.firewall.allowedUDPPorts = [
                443
                8443
              ];

              users.users.xray = {
                isSystemUser = true;
                group = "xray";
              };
              users.groups.xray = { };

              systemd.services."xray-subs" = {
                before = [ "nginx.service" ];
                wantedBy = [ "multi-user.target" ];
                requiredBy = [ "nginx.service" ];

                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                };

                script = ''
                  rm -rf /var/lib/xray-clients
                  mkdir -p /var/lib/xray-clients

                  ${lib.concatMapAttrsStringSep "\n" (clientName: _: ''
                    ln -sf "${
                      jail.secrets."xhttp-proxy/${srvName}/clients/${clientName}/config".path
                    }" "/var/lib/xray-clients/$(cat "${
                      jail.secrets."xhttp-proxy/${srvName}/clients/${clientName}/id".path
                    }")"
                  '') srv.clients}
                '';
              };

              services.nginx = {
                enable = true;
                virtualHosts."tunnel" = {
                  listen = [
                    {
                      addr = "[::]";
                      port = 443;
                      ssl = true;
                    }
                  ];
                  default = true;
                  onlySSL = true;
                  sslCertificate = jail.mtls.certPath;
                  sslCertificateKey = jail.mtls.keyPath;
                  http2 = true;
                  extraConfig = ''
                    proxy_buffering off;
                    ssl_client_certificate ${alloy.mtls.certPath};
                    ssl_verify_client on;
                    ssl_verify_depth 1;

                    include ${jail.secretTemplates."tunnel-locations".path};
                  '';
                };

                virtualHosts."subs" = {
                  listen = [
                    {
                      addr = "[::]";
                      port = 8443;
                      ssl = true;
                    }
                  ];
                  default = true;
                  onlySSL = true;
                  sslCertificate = jail.mtls.certPath;
                  sslCertificateKey = jail.mtls.keyPath;
                  http2 = true;
                  locations."/" = {
                    root = "/var/lib/xray-clients";
                    extraConfig = ''
                      autoindex off;
                      add_header Cache-Control "no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0";
                      default_type application/json;
                      charset utf-8;
                    '';
                  };
                  extraConfig = ''
                    ssl_client_certificate ${alloy.mtls.certPath};
                    ssl_verify_client on;
                    ssl_verify_depth 1;
                  '';
                };

                virtualHosts."fallback" = {
                  listen = [
                    {
                      addr = "unix:/run/nginx/xhttp-proxy-fallback.sock";
                    }
                  ];
                  default = true;
                  locations."/" = {
                    recommendedProxySettings = true;
                    proxyPass =
                      let
                        fallback = alloy.endpoints.${srv.fallbackEndpoint};
                      in
                      "https://${fallback.domain}:${toString fallback.port}";
                  };
                  extraConfig = ''
                    proxy_ssl_certificate ${jail.mtls.certPath};
                    proxy_ssl_certificate_key ${jail.mtls.keyPath};
                    proxy_ssl_trusted_certificate ${alloy.mtls.certPath};
                    proxy_ssl_verify on;
                    proxy_ssl_verify_depth 1;
                  '';
                };
              };

              systemd.services.xray =
                let
                  assets = pkgs.runCommand "xray-assets" { } ''
                    mkdir -p $out
                    ln -s ${pkgs.v2ray-geoip}/share/v2ray/geoip.dat $out/geoip.dat
                    ln -s ${pkgs.v2ray-domain-list-community}/share/v2ray/geosite.dat $out/geosite.dat
                  '';
                in
                {
                  after = [ "network.target" ];
                  wantedBy = [ "multi-user.target" ];
                  environment.XRAY_LOCATION_ASSET = assets;
                  serviceConfig = {
                    ExecStart = "${lib.getExe pkgs.xray} run -format json -c ${
                      jail.secretTemplates."server-config".path
                    }";
                    User = "xray";
                    Group = "xray";
                    StateDirectory = "xray";
                    RuntimeDirectory = "xray";
                    RuntimeDirectoryPreserve = "yes";
                    ConfigurationDirectory = "xray";
                    CapabilityBoundingSet = "";
                    AmbientCapabilities = "";
                    NoNewPrivileges = true;
                    ProtectSystem = "strict";
                    ProtectHome = true;
                    PrivateTmp = true;
                    PrivateDevices = true;
                    PrivateMounts = true;
                    ProtectHostname = true;
                    ProtectClock = true;
                    ProtectKernelTunables = true;
                    ProtectKernelModules = true;
                    ProtectKernelLogs = true;
                    ProtectControlGroups = true;
                    ProtectProc = "invisible";
                    ProcSubset = "pid";
                    RemoveIPC = true;
                    RestrictAddressFamilies = [
                      "AF_INET"
                      "AF_INET6"
                      "AF_NETLINK"
                      "AF_UNIX"
                    ];
                    LockPersonality = true;
                    MemoryDenyWriteExecute = true;
                    RestrictRealtime = true;
                    RestrictSUIDSGID = true;
                  };
                };
            };
          };
      };
    in
    {
      options.services.xhttp-proxy = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule serviceSubmodule);
      };

      config =
        let
          services = lib.pipe alloy.services.xhttp-proxy [
            (lib.filterAttrs (_: srv: srv.enable))
            (lib.mapAttrsToList mkService)
          ];
        in
        {
          assertions = lib.mkMerge (lib.map (s: s.assertions) services);
          endpoints = lib.mkMerge (lib.map (s: s.endpoints) services);
          secrets = lib.mkMerge (lib.map (s: s.secrets) services);
          generators = lib.mkMerge (lib.map (s: s.generators) services);
          jails = lib.mkMerge (lib.map (s: s.jails) services);
        };
    };
}
