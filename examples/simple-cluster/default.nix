{
  self,
  lib,
  ...
}:
{
  flake.nixosConfigurations =
    let
      hosts = (self.lib.evalModule self.alloyModules.simpleCluster).config.hosts;
    in
    lib.mapAttrs' (
      hostName: host: lib.nameValuePair "simpleCluster-${hostName}" host.nixosConfiguration
    ) hosts;

  flake.alloyCli.instances.simpleCluster = {
    alloyInputAttr = "";
  };

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

      deploy.signingKeys."test" = { };

      hosts.iridium = { config, ... }: {
        system = "x86_64-linux";
        stateVersion = "26.11";

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
            keyPaths = [
              config.boot.facts."test_ssh_key".path
            ];
            port = 2022;
          };
        };

        qemu.forwardPorts = [
          {
            name = "ssh";
            hypervisor = 5251;
            guest = 22;
            proto = "tcp";
          }
          {
            name = "initrd ssh";
            hypervisor = 5250;
            guest = 2022;
            proto = "tcp";
          }
        ];

        nets."slipr" = {
          default = true;
          managed = true;
          v4.mode.static.address = "10.0.2.15";
          v4.mode.static.prefixLength = 24;
          v4.mode.static.gateway = "10.0.2.2";
          iface = "eth0";
        };

        nets."public" = {
          primary = true;
          managed = true;
          iface = config.qemu.nets."main".iface;
          v4.mode.static = {
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

        qemu.nets."main" = { };
        # qemu.variant = "full-boot";
        qemu.variant = "direct-boot";

        deploy = {
          enable = true;
          activation.policy = "warn";
          defaultConnection = "localssh";
          connections."localssh" = {
            address = "127.0.0.1";
            port = 5251;
            user = "admin";
          };
          signingKeys = [
            "test"
          ];
          target.qemu.variant = "full-boot";
        };

        nixosModule = { pkgs, ... }: {
          environment.systemPackages = [ pkgs.dig ];
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

          nix.settings.trusted-users = [
            "root"
            "admin"
          ];

          # boot.initrd.systemd.emergencyAccess = true;
          # boot.kernelParams = [ "rd.systemd.break=pre-mount" ];
        };
      };

      hosts.gallium = { config, ... }: {
        system = "x86_64-linux";
        stateVersion = "26.11";

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
          managed = true;
          iface = config.qemu.nets."main".iface;
          v4.mode.static = {
            address = "192.168.100.${toString config.idx}";
            prefixLength = 24;
          };
        };

        nets."slipr" = {
          default = true;
          managed = true;
          v4.mode.static.address = "10.0.2.15";
          v4.mode.static.prefixLength = 24;
          v4.mode.static.gateway = "10.0.2.2";
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
            hypervisor = 5261;
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

        nixosModule = { pkgs, ... }: {
          environment.systemPackages = [ pkgs.dig ];
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

          nix.settings.trusted-users = [
            "root"
            "admin"
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
          acceptTerms = true;
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
          acceptTerms = true;
          email = "me@simple-cluster.internal";
          challenge.dns.dnsupdate = {
            server.endpoint = alloy.services.dns-acme."main".endpoint;
          };
        };
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
