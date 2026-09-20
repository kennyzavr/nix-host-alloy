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

      netSubmodule = { name, ... }: {
        options = {
          idx = lib.mkOption {
            default = alloy.indexes."qemu-nets".get name;
            readOnly = true;
            type = lib.types.ints.unsigned;
          };
        };
      };

      hostNetSubmodule =
        hostIdx:
        { name, ... }:
        let
          net = alloy.qemu.nets.${name};
          hIdx = lib.fixedWidthString 2 "0" (lib.toLower (lib.toHexString hostIdx));
          nIdx = lib.fixedWidthString 2 "0" (lib.toLower (lib.toHexString net.idx));
        in
        {
          options = {
            mac = lib.mkOption {
              default = "52:54:00:00:${hIdx}:${nIdx}";
              type = lib.types.str;
              readOnly = true;
            };
            iface = lib.mkOption {
              default = "eth${toString net.idx}";
              type = lib.types.str;
              readOnly = true;
            };
          };
        };

      fpSubmodule = {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            default = "";
          };
          proto = lib.mkOption {
            type = lib.types.enum [
              "tcp"
              "udp"
            ];
            default = "tcp";
          };
          hypervisor = lib.mkOption {
            type = lib.types.port;
          };
          guest = lib.mkOption {
            type = lib.types.port;
          };
        };
      };

      variantSubmodule = { config, name, ... }: {
        options = {
          package = lib.mkOption {
            type = lib.types.functionTo lib.types.package;
          };
        };
      };

      hostQemuSubmodule =
        hostName: host:
        { config, ... }:
        let
          commonModule = { modulesPath, ... }: {
            imports = [
              "${modulesPath}/virtualisation/qemu-vm.nix"
            ];

            virtualisation.forwardPorts = lib.map (fp: {
              proto = fp.proto;
              guest.port = fp.guest;
              host.port = fp.hypervisor;
            }) config.forwardPorts;

            virtualisation.graphics = true;
            virtualisation.memorySize = config.memory;
            virtualisation.cores = config.cores;
            virtualisation.qemu.options =
              [ ]
              ++ lib.optionals (!config.graphics) [
                "-display"
                "none"
                # We use file:/dev/stdout instead of stdio so QEMU doesn't try to read from stdin,
                # which causes it to freeze when run in detached mode (stdin closed).
                "-serial"
                "file:/dev/stdout"
              ]
              ++ lib.concatLists (
                lib.mapAttrsToList (
                  netName: netHost:
                  let
                    idx = toString alloy.qemu.nets.${netName}.idx;
                  in
                  [
                    "-netdev vde,id=net${idx},sock=$ALLOY_VDE_SOCKET_${idx}"
                    "-device virtio-net-pci,netdev=net${idx},mac=${netHost.mac}"
                  ]
                ) config.nets
              );
          };

        in
        {
          options = {
            memory = lib.mkOption {
              type = lib.types.ints.positive;
              default = 2048;
              description = "VM memory in MiB.";
            };
            cores = lib.mkOption {
              type = lib.types.ints.positive;
              default = 2;
              description = "Number of virtual CPU cores.";
            };
            graphics = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether to enable graphical output.";
            };
            nets = lib.mkOption {
              default = { };
              type = lib.types.attrsOf (lib.types.submodule (hostNetSubmodule host.idx));
            };
            forwardPorts = lib.mkOption {
              default = [ ];
              type = lib.types.listOf (lib.types.submodule fpSubmodule);
              description = "Ports to forward from hypervisor localhost into the VM guest via QEMU user-mode networking.";
            };
            variants = lib.mkOption {
              type = lib.types.attrsOf (lib.types.submodule variantSubmodule);
              default = { };
              description = "Registered VM launch-script variants for this host, keyed by variant name (e.g. \"qemu-vm\", \"disko\"). Each variant module contributes its own key.";
            };
            variant = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Which entry of `variants` the CLI runs when `--variant` is not given.";
            };
          };

          config.variants."direct-boot".package =
            { ... }:
            (lib.nixosSystem {
              inherit (host) system;
              modules = [
                host.nixosModule
                commonModule
              ];
            }).config.system.build.vm;

          config.variants."full-boot".package =
            { ... }:
            (lib.nixosSystem {
              inherit (host) system;
              modules = [
                host.nixosModule
                commonModule
                ({config, ...}: {
                  virtualisation.useBootLoader = true;
                  virtualisation.useEFIBoot =
                    config.boot.loader.systemd-boot.enable || config.boot.loader.efi.canTouchEfiVariables;
                })
              ];
            }).config.system.build.vm;
        };

      hostSubmodule =
        { name, config, ... }:
        let
          host = config;
          qemuCfg = host.qemu;
        in
        {
          options.qemu = lib.mkOption {
            default = { };
            type = lib.types.submodule (hostQemuSubmodule name host);
          };

          config = {
            assertions = [
              {
                assertion = lib.allUnique (
                  lib.map (pf: "${pf.proto}:${toString pf.hypervisor}") qemuCfg.forwardPorts
                );
                message = "[Alloy] VM '${name}': duplicate host port in forwardPorts.";
              }
            ];
          };
        };

      allPortKeys = lib.concatLists (
        lib.mapAttrsToList (
          hostName: host:
          lib.map (fwr: {
            inherit (fwr) proto;
            hypervisorPort = fwr.hypervisor;
            host = hostName;
          }) host.qemu.forwardPorts
        ) alloy.hosts
      );
    in
    {
      options.qemu.nets = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule netSubmodule);
      };
      options.hosts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
      };

      config = {
        assertions = [
          {
            assertion = lib.allUnique (lib.map (p: "${p.proto}:${toString p.hypervisorPort}") allPortKeys);
            message = "[Alloy] VM port conflict: multiple VMs forward the same hypervisor port.";
          }
          {
            assertion = lib.allUnique (lib.mapAttrsToList (_: n: n.idx) alloy.qemu.nets);
            message = "[Alloy] qemu.nets: idx values must be globally unique.";
          }
        ];

        indexes."qemu-nets" = {
          minValue = 1;
          maxValue = 99;
          keys = builtins.attrNames alloy.qemu.nets;
        };

        # _internal.state =
        #   { pkgs, ... }:
        #   {
        #     qemuNets = lib.mapAttrsToList (name: net: {
        #       inherit name;
        #       idx = net.idx;
        #     }) alloy.qemu.nets;
        #     qemuGuests = lib.pipe alloy.hosts [
        #       (lib.filterAttrs (_: host: host.qemu.variant != null))
        #       (lib.mapAttrsToList (
        #         hostName: host: {
        #           host = hostName;
        #           variant = host.qemu.variant;
        #           path = lib.getExe (host.qemu.variants.${host.qemu.variant}.package { inherit pkgs; });
        #           nets = lib.mapAttrsToList (netName: netHost: {
        #             name = netName;
        #             idx = alloy.qemu.nets.${netName}.idx;
        #             iface = netHost.iface;
        #             mac = netHost.mac;
        #           }) host.qemu.nets;
        #           forwardPorts = lib.map (fp: {
        #             proto = fp.proto;
        #             hypervisorPort = fp.hypervisor;
        #             guestPort = fp.guest;
        #             name = fp.name;
        #           }) host.qemu.forwardPorts;
        #         }
        #       ))
        #     ];
        #   };
      };
    };
}
