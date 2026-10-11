{
  self,
  lib,
  ...
}:
{
  flake.nixosConfigurations = lib.mapAttrs (
    _: host: host.nixosConfiguration
  ) (self.lib.evalModule self.alloyModules.simpleCluster).config.hosts;

  flake.alloyModules.simpleCluster =
    { alib, config, ... }:
    let
      alloy = config;
    in
    {
      imports = [
        self.alloyModules.disko
      ];

      name = "simple-cluster";

      workspace.root = self + "/examples/simple-cluster";

      workspace.secrets = {
        age.keyPairs = [
          {
            identity = alloy.facts."test_ssh_key".path;
            recipient = alloy.facts."test_ssh_pub_key".path;
          }
        ];
      };

      qemu.nets."main" = { };

      overlays."main" = {
        links = [
          {
            a.host = "iridium";
            b.host = "gallium";
          }
        ];
      };

      facts."test_ssh_pub_key" = {
        file = "test_ssh_pub_key";
      };
      facts."test_ssh_key" = {
        file = "test_ssh_key";
      };

      hosts.iridium = { config, ... }: {
        system = "x86_64-linux";

        facts."test_ssh_key" = {
          permissions.mode = "0600";
        };

        workspace.secrets = {
          age.keyPairs = [
            {
              identity = alloy.facts."test_ssh_key".path;
              recipient = alloy.facts."test_ssh_pub_key".path;
            }
          ];
        };

        ssh = {
          enable = true;
          listen = [
            {
              net = "slipr";
              port = 22;
            }
          ];
          keyPaths = [
            config.facts."test_ssh_key".path
          ];
        };

        boot = {
          facts."test_ssh_key" = { };

          ssh = {
            enable = true;
            authKeyFacts = [ "test_ssh_pub_key" ];
            keyPaths = [ config.boot.facts."test_ssh_key".path ];
            port = 2022;
          };
        };

        qemu.forwardPorts = [
          {
            name = "ssh";
            hypervisor = 2251;
            guest = 22;
            proto = "tcp";
          }
          {
            name = "initrd ssh";
            hypervisor = 2250;
            guest = 2022;
            proto = "tcp";
          }
        ];

        nets."slipr" = {
          default = true;
          static = true;
          v4.address = "10.0.2.15";
          v4.prefixLength = 24;
          v4.gateway = "10.0.2.2";
          iface = "eth0";
        };

        nets."public" = {
          primary = true;
          static = true;
          iface = config.qemu.nets."main".iface;
          v4 = {
            address = "192.168.100.${toString config.idx}";
            prefixLength = 24;
          };
        };

        overlays."main" = {
          wg.endpoint = "192.168.100.${toString config.idx}";
        };

        users.admin = {
          isAdmin = true;
          ssh.authKeyFacts = [
            "test_ssh_pub_key"
          ];
        };

        disko = {
          enable = true;
          settings = { ... }: {
            devices.disk.main = {
              type = "disk";
              device = "/dev/vda";
              content = {
                type = "gpt";
                partitions = {
                  ESP = {
                    size = "512M";
                    type = "EF00";
                    content = {
                      type = "filesystem";
                      format = "vfat";
                      mountpoint = "/boot";
                    };
                  };
                  luks = {
                    size = "100%";
                    content = {
                      type = "luks";
                      name = "cryptroot";
                      settings = { };
                      askPassword = true;
                      content = {
                        type = "filesystem";
                        format = "ext4";
                        mountpoint = "/";
                      };
                    };
                  };
                };
              };
            };
          };
        };

        qemu.nets."main" = { };
        qemu.variant = "direct-boot";

        nixosModule = {
          boot.loader.systemd-boot.enable = true;
          boot.loader.efi.canTouchEfiVariables = true;

          system.stateVersion = "26.05";

          nixpkgs = {
            config.allowUnfree = true;
          };

          nix.settings.experimental-features = [
            "nix-command"
            "flakes"
          ];
        };
      };

      hosts.gallium = { config, ... }: {
        system = "x86_64-linux";

        workspace.secrets = {
          age.keyPairs = [
            {
              identity = alloy.facts."test_ssh_key".path;
              recipient = alloy.facts."test_ssh_pub_key".path;
            }
          ];
        };

        facts."test_ssh_key" = {
          permissions.mode = "0600";
        };

        nets."public" = {
          primary = true;
          static = true;
          iface = config.qemu.nets."main".iface;
          v4 = {
            address = "192.168.100.${toString config.idx}";
            prefixLength = 24;
          };
        };

        nets."slipr" = {
          default = true;
          v4.address = "10.0.2.15";
          v4.prefixLength = 24;
          iface = "eth0";
        };

        ssh = {
          enable = true;
          listen = [
            {
              net = "slipr";
              port = 22;
            }
          ];
          keyPaths = [
            config.facts."test_ssh_key".path
          ];
        };

        qemu.forwardPorts = [
          {
            name = "ssh";
            hypervisor = 2261;
            guest = 22;
            proto = "tcp";
          }
        ];

        users.admin = {
          isAdmin = true;
          ssh.authKeyFacts = [
            "test_ssh_pub_key"
          ];
        };

        qemu.nets."main" = { };
        qemu.variant = "direct-boot";

        overlays."main" = {
          wg.endpoint = "192.168.100.${toString config.idx}";
        };

        nixosModule = {
          boot.loader.systemd-boot.enable = true;
          boot.loader.efi.canTouchEfiVariables = true;

          system.stateVersion = "26.05";

          nixpkgs = {
            config.allowUnfree = true;
          };

          nix.settings.experimental-features = [
            "nix-command"
            "flakes"
          ];
        };
      };

      dns.zones."main" = {
        apex = "simple-cluster.internal";
        rname = "admin.simple-cluster.internal";
      };
      dns.zones."main-acme" = {
        apex = "acme.simple-cluster.internal";
        rname = "admin.simple-cluster.internal";
        parentZone = "main";
      };

      tls.ca."main" = { };

      tls.certs."ca" = {
        domains = [
          {
            zone = "main";
            name = "ca";
          }
        ];
        ca = "main";
        src.acme = {
          email = "admin@simple-cluster.internal";
          challenge.dns.dnsupdate = {
            server.endpoint = alloy.services.dns-acme."main".endpoint;
          };
        };
      };

      tls.certs."mail" = {
        domains = [
          {
            zone = "main";
            name = "mail";
          }
        ];
        ca = "main";
        src.acme = {
          email = "me@simple-cluster.internal";
          challenge.dns.dnsupdate = {
            server.endpoint = alloy.services.dns-acme."main".endpoint;
          };
        };
      };

      services.dns-resolver."main" = {
        host = "gallium";
        overlays."main" = { };
      };

      services.dns-edge."public" = {
        routes."main" = {
          zone = "main";
          upstream.endpoint = alloy.services.dns-auth."main".endpoint;
        };
        routes."main-acme" = {
          zone = "main-acme";
          upstream.endpoint = alloy.services.dns-acme."main".endpoint;
        };
        hosts."iridium" = { };
        hosts."gallium" = { };
      };

      services.http-edge."public" = {
        routes."ca" = {
          domain = {
            zone = "main";
            name = "ca";
          };
          downstream.tls.mode = "only";
          downstream.tls.cert = "ca";
          upstream.endpoint = alloy.services.ca."main".endpoint;
        };
        hosts."iridium" = { };
        hosts."gallium" = { };
      };

      services.dns-auth."main" = {
        zones = [
          "main"
        ];
        hosts."iridium" = { };
        hosts."gallium" = { };
        overlays."main" = { };
      };

      services.dns-acme."main" = {
        zones = [
          "main-acme"
        ];
        host = "iridium";
        overlays."main" = { };
      };

      services.ca."main" = {
        subject = "SimpleCluster";
        domain = {
          zone = "main";
          name = "ca";
        };
        permittedDomains = [
          {
            zone = "main";
            name = "@";
          }
        ];
        acme.enable = true;
        overlays."main" = { };
        host = "iridium";
      };
    };
}
