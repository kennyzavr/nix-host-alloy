{
  self,
  inputs,
  lib,
  flake-parts-lib,
  config,
  ...
}:
let
  infra = (inputs.alloy.lib.evalModule self.alloyModules.test).config;
in
{
  imports = [
    inputs.alloy.flakeModules.default
  ];

  config = {

    flake.nixosConfigurations = lib.mapAttrs (_: host: host.nixosConfiguration) infra.hosts;

    flake.alloyModules.test =
      { alib, config, ... }:
      let
        alloy = config;

        hostSubmodule =
          { name, config, ... }:
          let
            hostName = name;
            host = config;
          in
          {
            config.nixosModule = { pkgs, ... }: {
              environment.systemPackages = [
                pkgs.dig
                pkgs.vim
                pkgs.nftables
                pkgs.tcpdump
                pkgs.wireguard-tools
              ];

              users = {
                mutableUsers = false;
                users.admin = {
                  isNormalUser = true;
                  createHome = true;
                  home = "/home/admin";
                  group = "admin";
                  password = "admin";
                  extraGroups = [ "wheel" ];
                  openssh.authorizedKeys.keys = [
                    (builtins.readFile ./test_ed25519_key.pub)
                  ];
                };
                groups.admin = { };
              };

              services.openssh = {
                enable = true;
                ports = [
                  22
                ];
                settings = {
                  PermitRootLogin = "no";
                  PasswordAuthentication = false;
                };
              };

              networking.firewall.allowedTCPPorts = [ 22 ];

              system.activationScripts.prepareSshKeys = {
                text = ''
                  SSH_DIR="/etc/ssh"

                  KEY_FILE="$SSH_DIR/ssh_host_ed25519_key"
                  PUB_KEY_FILE="$SSH_DIR/ssh_host_ed25519_key.pub"

                  $DRY_RUN_CMD mkdir -p "$SSH_DIR"
                  $DRY_RUN_CMD chmod 755 "$SSH_DIR"
                  $DRY_RUN_CMD echo "${builtins.readFile ./test_ed25519_key}" > "$KEY_FILE"
                  $DRY_RUN_CMD mkdir -p "$SSH_DIR"
                  $DRY_RUN_CMD chmod 600 "$KEY_FILE"
                  $DRY_RUN_CMD ${pkgs.openssh}/bin/ssh-keygen -y -f "$KEY_FILE" > "$PUB_KEY_FILE"
                  echo "ssh key $KEY_FILE has been wrote"
                '';
                deps = [ "specialfs" ];
              };

              system.activationScripts.agenixInstall = {
                text = "";
                deps = [ "prepareSshKeys" ];
              };

              virtualisation.vmVariant = {
                virtualisation.graphics = false;
                virtualisation.qemu.options = [
                  "-netdev vde,id=net1,sock=\${VDE_SOCK_DIR}"
                  "-device virtio-net-pci,netdev=net1,mac=52:54:00:00:00:0${toString (host.idx)}"
                ];
                networking.interfaces.eth1.ipv4.addresses = [
                  {
                    address = "192.168.100.${toString (host.idx)}";
                    prefixLength = 24;
                  }
                ];
              };

              networking.hostName = hostName;
              system.stateVersion = "26.05";
              security.sudo = {
                wheelNeedsPassword = false;
                extraConfig = ''
                  Defaults pwfeedback
                '';
              };
              nixpkgs = {
                config.allowUnfree = true;
              };
              nix.settings.experimental-features = [
                "nix-command"
                "flakes"
              ];
            };
          };

      in
      {
        options.hosts = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
        };

        config = {
          dns.zones = {
            "public" = {
              apex = "d108.dev";
              rname = "admin.d108.dev";
            };
            "private" = {
              apex = "d108.internal";
              rname = "admin.d108.internal";
            };
          };

          gateways."public" = { };

          services.dns-gateways."public" = {
            hosts."iridium" = {
              ipv4 = "192.168.100.2";
            };
            hosts."gallium" = {
              ipv4 = "192.168.100.1";
            };
          };

          services.dns."main" = {
            gateway = "public";
            hosts = {
              "iridium" = { };
              "gallium" = { };
            };
            overlays = {
              "main" = { };
            };
            zones = {
              "public" = { };
              "private" = { };
            };
          };

          services.dns-acme."main" = {
            gateway = "public";
            host = "iridium";
            overlays = {
              "main" = { };
            };
            domains = [
              {
                zone = "public";
                name = "foobar";
                tsigSecret = "dns-acme/public/foobar";
              }
            ];
          };

          # jails."fooooo" = {
          #   host = "gallium";
          # };

          generators.instances."dns-acme/public/foobar" = {
            imports = [
              alloy.generators.templates."dns/tsig-key"
            ];
            secret = "dns-acme/public/foobar";
          };

          workspace.root = toString self;

          workspace.secrets = {
            age.keyPairs = [
              {
                identity = ./test_ed25519_key;
                recipient = ./test_ed25519_key.pub;
              }
            ];
          };

          overlays."main" = {
            links = [
              {
                a.host = "iridium";
                b.host = "gallium";
              }
            ];
          };

          jails."testjail" = { config, ... }: {
            host = "iridium";
            overlays."main" = { };
            uplink.allowEgress = true;
            uplink.forwards = [
              {
                proto = "tcp";
                port = 80;
                ipv4 = "192.168.100.2";
              }
            ];
            nixosModule = { pkgs, ... }: {
              services.nginx.enable = true;
              services.nginx.virtualHosts."_" = {
                default = true;
                root = pkgs.writeTextDir "index.html" ''
                  <!DOCTYPE html>
                  <html>
                    <head><title>Test</title></head>
                    <body>
                      <h1>Hello from NixOS Nginx!</h1>
                      <p>Это работает.</p>
                    </body>
                  </html>
                '';
              };
            };
          };

          hosts.iridium = { config, ... }: {
            system = "x86_64-linux";

            workspace.secrets = {
              age.keyPairs = [
                {
                  identity = ./test_ed25519_key;
                  recipient = ./test_ed25519_key.pub;
                }
              ];
            };

            overlays."main" = {
              wg.endpoint = "192.168.100.${toString config.idx}";
            };

            nixosModule = {
              networking.firewall.allowedTCPPorts = [ 80 ];
            };
          };

          hosts.gallium = { config, ... }: {
            system = "x86_64-linux";

            workspace.secrets = {
              age.keyPairs = [
                {
                  identity = ./test_ed25519_key;
                  recipient = ./test_ed25519_key.pub;
                }
              ];
            };

            overlays."main" = {
              wg.endpoint = "192.168.100.${toString config.idx}";
            };
          };

          # overlays.main = {
          #   links = [
          #     {
          #       a.host = "iridium";
          #       b.host = "gallium";
          #     }
          #   ];
          # };

          # dns.zones."public" = {
          #   origin = "d108.dev";
          #   soa.rname = "hostmaster";
          # };

          # secrets."ca-root" = {
          #   generator.tls-x509-ca = {
          #     subject = "${alloy.dns.zones."public".origin} Root CA";
          #     permitted.dnsNames = [
          #       alloy.dns.zones."public".origin
          #     ];
          #   };
          # };
          # secrets."ca-intermediate" = {
          #   generator.tls-x509-ca = {
          #     root = "ca-root";
          #     subject = "${alloy.dns.zones."public".origin} Intermediate CA";
          #   };
          # };

          # tls.certs."ca" = {
          #   dnames = [
          #     "ca.${alloy.dns.zones.public.origin}"
          #   ];
          #   acme.server = "https://${alloy.jails.ca.nets.main.dname}/acme/acme-main/directory";
          #   acme.email = "hostmaster@${alloy.dns.zones.public.origin}";
          # };

          # services.nameservers.public = {
          #   hosts.iridium = {
          #     dname = "ns1.${alloy.dns.zones."public".origin}";
          #     listenOn = [
          #       {
          #         iface = "eth1";
          #         ipv4 = "192.168.100.${toString alloy.hosts.iridium.idx}";
          #       }
          #     ];
          #   };
          #   hosts.gallium = {
          #     dname = "ns2.${alloy.dns.zones."public".origin}";
          #     listenOn = [
          #       {
          #         iface = "eth1";
          #         ipv4 = "192.168.100.${toString alloy.hosts.gallium.idx}";
          #       }
          #     ];
          #   };
          #   nets."main" = { };
          #   zones."public" = { };
          # };

          # services.gateways.public = {
          #   hosts.iridium = {
          #     listenOn = [
          #       {
          #         iface = "eth1";
          #         ipv4 = "192.168.100.${toString alloy.hosts.iridium.idx}";
          #       }
          #     ];
          #   };
          #   hosts.gallium = {
          #     listenOn = [
          #       {
          #         iface = "eth1";
          #         ipv4 = "192.168.100.${toString alloy.hosts.gallium.idx}";
          #       }
          #     ];
          #   };
          #   http.routes."ca.${alloy.dns.zones.public.origin}" = {
          #     downstream = {
          #       tls.mode = "force";
          #       tls.cert = "ca";
          #     };
          #     upstream.endpoint = "ca";
          #   };
          # };

          # endpoints."ca".targets = [
          #   {
          #     net = "main";
          #     ipv6 = [ alloy.jails.ca.nets.main.ipv6 ];
          #     port = 443;
          #   }
          # ];

          # volumes."step-ca-db" = {
          #   driver.directory = { };
          #   hosts = [ "iridium" ];
          #   permissions = {
          #     owner = 7001;
          #     group = 7001;
          #     mode = "0750";
          #   };
          # };
          # jails."ca" = { config, ... }: {
          #   host = "iridium";
          #   nets."main" = {
          #     tls.permissions.owner = "nginx";
          #   };
          #   secrets."ca-root".permissions = {
          #     owner = "step-ca";
          #   };
          #   secrets."ca-intermediate".permissions = {
          #     owner = "step-ca";
          #   };
          #   volumes."step-ca-db" = {
          #     mountPoint = "/var/lib/step-ca";
          #   };
          #   nixosModule = { pkgs, ... }: {
          #     environment.systemPackages = [
          #       pkgs.dig
          #     ];
          #     users.users.step-ca.uid = 7001;
          #     users.groups.step-ca.gid = 7001;
          #     networking.firewall.allowedTCPPorts = [ 443 ];
          #     services.nginx = {
          #       enable = true;
          #       virtualHosts."default" = {
          #         listen = [
          #           {
          #             addr = "[${config.nets."main".addr}]";
          #             port = 443;
          #             ssl = true;
          #           }
          #         ];
          #         onlySSL = true;
          #         serverName = config.nets."main".dname;
          #         sslCertificate = config.nets."main".ssl.certPath;
          #         sslCertificateKey = config.nets."main".ssl.keyPath;
          #         sslTrustedCertificate = alloy.secrets."ca-root".generator.ssl-x509-ca.certPath;
          #         locations."/" = {
          #           proxyPass = "https://127.0.0.1:8443";
          #           recommendedProxySettings = true;
          #         };
          #         locations."/acme/main/" = {
          #           proxyPass = "https://127.0.0.1:8443";
          #           extraConfig = ''
          #             allow ${alloy.nets."main".subnet}::/48;
          #             deny all;
          #           '';
          #         };
          #       };
          #     };
          #     systemd.services.step-ca.serviceConfig = {
          #       PrivateUsers = lib.mkForce false;
          #       DynamicUser = lib.mkForce false;
          #     };
          #     services.step-ca = {
          #       enable = true;
          #       address = "127.0.0.1";
          #       port = 8443;
          #       settings = {
          #         root = alloy.secrets."ca-root".generator.ssl-x509-ca.certPath;
          #         crt = alloy.secrets."ca-intermediate".generator.ssl-x509-ca.certPath;
          #         key = config.secrets."ca-intermediate".mountPoint;
          #         dnsNames = [
          #           "ca.${alloy.dns.zones."public".origin}"
          #         ];
          #         logger.format = "text";
          #         db = {
          #           type = "badgerv2";
          #           dataSource = "/var/lib/step-ca/db";
          #           badgerFileLoadingMode = "";
          #         };
          #         authority = {
          #           claims = {
          #             minTLSCertDuration = "5m";
          #             maxTLSCertDuration = "24h";
          #             defaultTLSCertDuration = "24h";
          #             disableRenewal = false;
          #             allowedRenewalAfterExpiry = false;
          #             minHostSSHCertDuration = "5m";
          #             maxHostSSHCertDuration = "1680h";
          #             defaultHostSSHCertDuration = "720h";
          #             minUserSSHCertDuration = "5m";
          #             maxUserSSHCertDuration = "24h";
          #             defaultUserSSHCertDuration = "16h";
          #           };
          #           policy.x509 = {
          #             allow.dns = [
          #               "*.${alloy.dns.zones.public.origin}"
          #               alloy.dns.zones.public.origin
          #             ];
          #             allowWildcardNames = false;
          #           };
          #           policy.ssh.user = {
          #             allow.email = [ "@${alloy.dns.zones."public".origin}" ];
          #           };
          #           policy.ssh.host = {
          #             allow.dns = [ "*.${lib.removeSuffix "." alloy.nets."main".dname}" ];
          #           };
          #           provisioners = [
          #             {
          #               type = "ACME";
          #               name = "acme-main";
          #             }
          #           ];
          #         };
          #         tls = {
          #           cipherSuites = [
          #             "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256"
          #             "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"
          #           ];
          #           minVersions = 1.2;
          #           maxVersions = 1.3;
          #           renegoration = false;
          #         };
          #       };
          #     };
          #   };
          # };

        };
      };

    perSystem = { pkgs, config, ... }: {
      packages.alloy = inputs.alloy.lib.mkCli {
        module = self.alloyModules.test;
        inherit pkgs;
      };

      apps = {

        setup-vde = {
          type = "app";
          program =
            let
              script = pkgs.writeShellApplication {
                name = "setup-vde";
                runtimeInputs = [ pkgs.vde2 ];
                text = ''
                      # Используем текущую директорию запуска (PWD)
                  STATE_DIR="$PWD/.simple-cluster"
                  SOCK="$STATE_DIR/vde-switch.sock"
                  TAP_DEV="vde-test"
                  HOST_IP="192.168.100.254/24"

                  mkdir -p "$STATE_DIR"

                  echo "🌐 Настраиваем сетевой интерфейс хоста $TAP_DEV ($HOST_IP)..."
                  if ! ip link show "$TAP_DEV" >/dev/null 2>&1; then
                    sudo ip tuntap add dev "$TAP_DEV" mode tap user "$(whoami)"
                  fi
                  sudo ip addr add "$HOST_IP" dev "$TAP_DEV" 2>/dev/null || true
                  sudo ip link set dev "$TAP_DEV" up

                  echo "🔌 Запускаем VDE свитч..."
                  coproc vde_switch -s "$SOCK" -tap "$TAP_DEV" &

                  while [ ! -e "$SOCK" ]; do
                    sleep 0.1
                  done

                  cleanup() {
                    echo "🛑 Выключаем VDE свитч и удаляем интерфейс..."
                    trap - EXIT INT TERM
                    killall -9 vde_switch 2>/dev/null || true
                    sudo ip link delete "$TAP_DEV" 2>/dev/null || true
                    rm -rf "$SOCK"
                    exit 0
                  }
                  trap cleanup EXIT INT TERM

                  echo "✅ Сеть поднята! Все файлы будут лежать в $STATE_DIR"
                  echo "Оставь этот терминал открытым, а кластер запускай в другом терминале."
                  echo "Нажми Ctrl+C для выключения сети."
                  wait
                '';
              };
            in
            "${script}/bin/setup-vde";
        };

        # Скрипт для запуска виртуалок (НЕ ТРЕБУЕТ sudo)
        run-cluster = {
          type = "app";
          program =
            let
              script = pkgs.writeShellApplication {
                name = "run-cluster";
                runtimeInputs = [ pkgs.vde2 ];
                text = ''
                  STATE_DIR="$PWD/.simple-cluster"
                  SOCK="$STATE_DIR/vde-switch.sock"
                  export VDE_SOCK_DIR="$SOCK"

                  # Проверяем, что сеть поднята
                  if [ ! -e "$SOCK" ]; then
                    echo "❌ Ошибка: VDE свитч не найден в $STATE_DIR!"
                    echo "Сначала открой другой терминал в этой же директории и запусти: nix run .#setup-vde"
                    exit 1
                  fi

                  cleanup() {
                    echo "🛑 Выключаем кластер..."
                    trap - EXIT INT TERM
                    killall -9 qemu-kvm qemu-system-x86_64 2>/dev/null || true
                    exit 0
                  }
                  trap cleanup EXIT INT TERM

                  # === БЛОК 1: Запускаем все виртуалки параллельно ===
                  ${lib.concatMapAttrsStringSep "\n" (hostName: host: ''
                    export NIX_DISK_IMAGE="$STATE_DIR/${hostName}.qcow2"

                    LOG_FILE="$STATE_DIR/${hostName}.log"
                    echo "🚀 Запускаем ${hostName} (логи в $LOG_FILE)..."

                    ${host.nixosConfiguration.config.system.build.vm}/bin/run-${hostName}-vm > "$LOG_FILE" 2>&1 &
                  '') infra.hosts}

                  echo "⏳ Ожидаем загрузки кластера (это может занять немного времени)..."

                  # === БЛОК 2: Ждем загрузки каждой по очереди ===
                  ${lib.concatMapAttrsStringSep "\n" (hostName: host: ''
                    LOG_FILE="$STATE_DIR/${hostName}.log"

                    while [ ! -f "$LOG_FILE" ]; do sleep 0.1; done

                    # Читаем лог раз в секунду
                    while ! grep -a -q -E -i "login:|Started OpenSSH Daemon|Reached target.*Multi-User" "$LOG_FILE" 2>/dev/null; do
                      sleep 1
                    done

                    echo "✅ Хост ${hostName} полностью загрузился и готов!"
                  '') infra.hosts}

                  echo "🎉 Весь кластер работает! Нажмите Ctrl+C для выключения виртуалок."
                  wait
                '';
              };
            in
            "${script}/bin/run-cluster";
        };
      };
    };
  };
}
