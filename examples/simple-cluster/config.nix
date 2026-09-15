{
  self,
  inputs,
  lib,
  ...
}:
let
  simple-cluster = (inputs.alloy.lib.evalModule self.alloyModules.test).config;
in
{
  imports = [
    inputs.alloy.flakeModules.default
  ];

  config = {

    flake.nixosConfigurations = lib.mapAttrs (_: host: host.nixosConfiguration) simple-cluster.hosts;

    flake.alloyModules.test =
      { alib, config, ... }:
      let
        alloy = config;

        hostSubmodule =
          { name, config, ... }:
          let
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
                pkgs.swaks
              ];

              users = {
                users.admin = {
                  openssh.authorizedKeys.keys = [
                    (builtins.readFile ./test_ed25519_key.pub)
                  ];
                };
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

              # system.activationScripts.agenixInstall = {
              #   text = "";
              #   deps = [ "prepareSshKeys" ];
              # };

              # virtualisation.vmVariant = {
              #   virtualisation.graphics = false;
              #   virtualisation.memorySize = 4096;
              #   virtualisation.qemu.options = [
              #     "-netdev vde,id=net1,sock=\${VDE_SOCK_DIR}"
              #     "-device virtio-net-pci,netdev=net1,mac=52:54:00:00:00:0${toString (host.idx)}"
              #   ];
              #   networking.interfaces.eth1.ipv4.addresses = [
              #     {
              #       address = "192.168.100.${toString (host.idx)}";
              #       prefixLength = 24;
              #     }
              #   ];
              # };

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
          name = "simple-cluster";

          workspace.root = toString self;

          workspace.secrets = {
            age.keyPairs = [
              {
                identity = ./test_ed25519_key;
                recipient = ./test_ed25519_key.pub;
              }
            ];
          };

          qemu.nets."main" = { };

          # overlays."main" = {
          #   links = [
          #     {
          #       a.host = "iridium";
          #       b.host = "gallium";
          #     }
          #   ];
          # };

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

            nets."public" = {
              primary = true;
              static = true;
              iface = config.qemu.nets."main".iface;
              v4 = {
                address = "192.168.100.${toString config.idx}";
              };
            };

            # overlays."main" = {
            #   wg.endpoint = "192.168.100.${toString config.idx}";
            # };

            users.admin = {
              isAdmin = true;
            };

            qemu.variant = "qemu-vm";
            qemu.nets."main" = { };
            qemu.portForwards = [
              {
                host = 2255;
                quest = 22;
              }
            ];

            # nixosModule = {
            #   networking.firewall.allowedTCPPorts = [ 80 ];
            # };
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

            nets."public" = {
              primary = true;
              static = true;
              iface = config.qemu.nets."main".iface;
              v4 = {
                address = "192.168.100.${toString config.idx}";
              };
            };

            users.admin = {
              isAdmin = true;
            };

            qemu.variant = "qemu-vm";
            qemu.nets."main" = { };
            qemu.portForwards = [
              {
                host = 2256;
                quest = 22;
              }
            ];

            # overlays."main" = {
            #   wg.endpoint = "192.168.100.${toString config.idx}";
            # };
          };

          # dns.zones."public" = {
          #   apex = "d108.dev";
          #   rname = "me.d108.dev";
          # };
          # dns.zones."public-acme" = {
          #   apex = "acme.d108.dev";
          #   rname = "me.d108.dev";
          #   parentZone = "public";
          # };

          # tls.ca."d108" = { };

          # tls.certs."filebrowser" = {
          #   domains = [
          #     {
          #       zone = "public";
          #       name = "filebrowser";
          #     }
          #   ];
          #   ca = "d108";
          #   src.acme = {
          #     email = "me@d108.dev";
          #     challenge.dns.dnsupdate = {
          #       server.endpoint = alloy.services.dns-acme."public".endpoint;
          #     };
          #   };
          # };

          # tls.certs."public-ca" = {
          #   domains = [
          #     {
          #       zone = "public";
          #       name = "ca";
          #     }
          #   ];
          #   ca = "d108";
          #   src.acme = {
          #     email = "me@d108.dev";
          #     challenge.dns.dnsupdate = {
          #       server.endpoint = alloy.services.dns-acme."public".endpoint;
          #     };
          #   };
          # };

          # tls.certs."public-mail" = {
          #   domains = [
          #     {
          #       zone = "public";
          #       name = "mail";
          #     }
          #   ];
          #   ca = "d108";
          #   src.acme = {
          #     email = "me@d108.dev";
          #     challenge.dns.dnsupdate = {
          #       server.endpoint = alloy.services.dns-acme."public".endpoint;
          #     };
          #   };
          # };

          # services.dns-resolver."main" = {
          #   host = "gallium";
          #   overlays."main" = { };
          # };

          # services.dns-edge."public" = {
          #   routes."public" = {
          #     zone = "public";
          #     upstream.endpoint = alloy.services.dns-auth."public".endpoint;
          #   };
          #   routes."public-acme" = {
          #     zone = "public-acme";
          #     upstream.endpoint = alloy.services.dns-acme."public".endpoint;
          #   };
          #   hosts."iridium" = {
          #     ipv4 = "192.168.100.2";
          #   };
          #   hosts."gallium" = {
          #     ipv4 = "192.168.100.1";
          #   };
          # };

          # services.http-edge."public" = {
          #   routes."filebrowser" = {
          #     domain = {
          #       zone = "public";
          #       name = "filebrowser";
          #     };
          #     downstream.tls.mode = "only";
          #     downstream.tls.cert = "filebrowser";
          #     upstream.endpoint = alloy.services.xhttp-proxy."main".tunnelEndpoint;
          #   };

          #   routes."public-ca" = {
          #     domain = {
          #       zone = "public";
          #       name = "ca";
          #     };
          #     downstream.tls.mode = "only";
          #     downstream.tls.cert = "public-ca";
          #     upstream.endpoint = alloy.services.ca."d108".endpoint;
          #   };
          #   hosts."iridium" = {
          #     ipv4 = "192.168.100.2";
          #   };
          #   hosts."gallium" = {
          #     ipv4 = "192.168.100.1";
          #   };
          # };

          # services.tls-edge."public" = {
          #   routes."main-mail-smtps" = {
          #     domain = {
          #       zone = "public";
          #       name = "mail";
          #     };
          #     downstream.port = 465;
          #     downstream.tls.enable = true;
          #     downstream.tls.cert = "public-mail";
          #     upstream.endpoint = alloy.services.postbox."public".smtps.endpoint;
          #   };
          #   routes."public-mail-imap" = {
          #     domain = {
          #       zone = "public";
          #       name = "mail";
          #     };
          #     downstream.port = 993;
          #     downstream.tls.enable = true;
          #     downstream.tls.cert = "public-mail";
          #     upstream.endpoint = alloy.services.postbox."public".imap.endpoint;
          #   };
          #   hosts."iridium" = {
          #     ipv4 = "192.168.100.2";
          #   };
          #   hosts."gallium" = {
          #     ipv4 = "192.168.100.1";
          #   };
          # };

          # services.smtp-edge."public" = {
          #   hostname = {
          #     zone = "public";
          #     name = "mail";
          #   };
          #   routes."public-email-smtp" = {
          #     domain = {
          #       zone = "public";
          #       name = "@";
          #     };
          #     upstream.endpoint = alloy.services.postbox."public".smtp.endpoint;
          #   };
          #   explicitTLS.mode = "require";
          #   explicitTLS.cert = "public-mail";
          #   dkim.enable = true;
          #   hosts."iridium" = {
          #     ipv4 = "192.168.100.2";
          #   };
          #   hosts."gallium" = {
          #     ipv4 = "192.168.100.1";
          #   };
          # };

          # services.dns-auth."public" = {
          #   zones = [
          #     "public"
          #   ];
          #   hosts."iridium" = { };
          #   hosts."gallium" = { };
          #   overlays."main" = { };
          # };

          # services.dns-acme."public" = {
          #   zones = [
          #     "public-acme"
          #   ];
          #   host = "iridium";
          #   overlays."main" = { };
          # };

          # services.ca."d108" = {
          #   subject = "D108";
          #   domain = {
          #     zone = "public";
          #     name = "ca";
          #   };
          #   permittedDomains = [
          #     {
          #       zone = "public";
          #       name = "@";
          #     }
          #   ];
          #   acme.enable = true;
          #   overlays."main" = { };
          #   host = "iridium";
          # };

          # facts."users/admin/login" = { };

          # services.postbox."public" = {
          #   domain = {
          #     zone = "public";
          #     name = "@";
          #   };
          #   admin = "admin";
          #   users.admin = {
          #     loginFact = "users/admin/login";
          #   };
          #   overlays."main" = { };
          #   host = "gallium";
          #   smtp.relayEndpoint = alloy.services.smtp-edge."public".endpoint;
          # };

          # services.xhttp-proxy."main" = {
          #   host = "iridium";
          #   overlays."main" = { };
          #   domain = {
          #     zone = "public";
          #     name = "filebrowser";
          #   };
          #   fallbackEndpoint = "filebrowser";
          #   clients."me" = { };
          #   profiles."default" = { };
          # };

          # endpoints."filebrowser" = {
          #   port = 443;
          #   targets = [
          #     {
          #       ipv6 = alloy.jails."filebrowser".overlays."main".ipv6;
          #       overlay = "main";
          #     }
          #   ];
          # };
          # jails."filebrowser" = { config, ... }: {
          #   host = "gallium";
          #   overlays."main" = { };
          #   endpoints."filebrowser" = {};
          #   mtls.permissions = {
          #     owner = "nginx";
          #     group = "nginx";
          #     mode = "0640";
          #   };
          #   volumes."db" = {
          #     path = "/var/lib/filebrowser";
          #     driver.directory = { };
          #     permissions = {
          #       owner = "filebrowser";
          #       group = "filebrowser";
          #       mode = "0750";
          #     };
          #   };
          #   nixosModule = {
          #     networking.firewall.allowedTCPPorts = [ 443 ];

          #     services.nginx = {
          #       enable = true;
          #       virtualHosts."_" = {
          #         default = true;
          #         listenAddresses = [ "[::]" ];
          #         onlySSL = true;
          #         sslCertificate = config.mtls.certPath;
          #         sslCertificateKey = config.mtls.keyPath;
          #         locations."/" = {
          #           recommendedProxySettings = true;
          #           proxyPass = "http://127.0.0.1:8080";
          #         };
          #       };
          #     };

          #     services.filebrowser = {
          #       enable = true;
          #       settings.port = 8080;
          #       settings.address = "127.0.0.1";
          #     };
          #   };
          # };

        };
      };

    perSystem = { pkgs, config, ... }: {
      packages.cli = inputs.alloy.lib.mkCli {
        module = self.alloyModules.simpleCluster;
        inherit pkgs;
      };
    };
  };
}
