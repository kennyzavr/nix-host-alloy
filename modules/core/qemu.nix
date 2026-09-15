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
            # default = alloy.indexes."qemu-nets".get name;
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
          };
          proto = lib.mkOption {
            type = lib.types.enum [
              "tcp"
              "udp"
            ];
            default = "tcp";
          };
          host = lib.mkOption {
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

      mkHostfwdArgs =
        forwardPorts:
        lib.concatMapStringsSep "" (
          pf: ",hostfwd=${pf.proto}::${toString pf.host}-:${toString pf.guest}"
        ) forwardPorts;

      hostQemuSubmodule =
        hostName: hostIdx:
        { config, ... }:
        let
          qemuCfg = config;
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
              type = lib.types.attrsOf (lib.types.submodule (hostNetSubmodule hostIdx));
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
            extraQemuOptions = lib.mkOption {
              default = [ ];
              type = lib.types.listOf lib.types.str;
              description = "Additional raw QEMU command-line options.";
            };
            qemuOptions = lib.mkOption {
              readOnly = true;
              type = lib.types.listOf lib.types.str;
              description = "Fully-assembled QEMU options: user-mode NIC + one VDE NIC per attached net + extraQemuOptions.";
            };
            nixosModule = lib.mkOption {
              type = lib.types.deferredModule;
              default = { };
              apply = module: {
                _class = "nixos";
                _file = "hosts.${lib.strings.escapeNixIdentifier hostName}.vm.nixosModule";
                imports = [ module ];
              };
            };
          };

          config = {
            qemuOptions =
              # eth0: user-mode NAT with port-forwards (replaces NixOS default NIC)
              [
                "-netdev user,id=net0${mkHostfwdArgs qemuCfg.forwardPorts}"
                "-device virtio-net-pci,netdev=net0"
              ]
              # eth<net.idx>: one VDE NIC per attached qemu.nets entry.
              # ALLOY_VDE_SOCKET_<idx> is injected by the CLI at launch time.
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
                ) qemuCfg.nets
              )
              ++ lib.optionals (!qemuCfg.graphics) [
                "-display"
                "none"
                # We use file:/dev/stdout instead of stdio so QEMU doesn't try to read from stdin,
                # which causes it to freeze when run in detached mode (stdin closed).
                "-serial"
                "file:/dev/stdout"
              ]
              ++ qemuCfg.extraQemuOptions;
          };
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
            type = lib.types.submodule (hostQemuSubmodule name host.idx);
          };

          config = {
            qemu.variants.qemu-vm.package = { pkgs, ... }: host.nixosConfiguration.config.system.build.vm;

            assertions = [
              {
                assertion = lib.allUnique (lib.map (pf: "${pf.proto}:${toString pf.host}") qemuCfg.forwardPorts);
                message = "[Alloy] VM '${name}': duplicate host port in forwardPorts.";
              }
            ];

            # NixOS module applied to the default qemu-vm variant.
            nixosModule = lib.mkIf (qemuCfg.variant != null) {
              virtualisation.vmVariant = {
                imports = [
                  qemuCfg.nixosModule
                  # Workaround: OVMFFull (default efi.OVMF) has systemManagementModeRequired=true,
                  # which unconditionally appends "-machine q35,smm=on" and
                  # "-global driver=cfi.pflash01,property=secure,value=on" to the QEMU command
                  # even when useEFIBoot=false (no firmware is loaded).  QEMU then crashes with a
                  # glibc buffer overflow during q35 SMM initialisation without the pflash image.
                  # Switch to pkgs.OVMF (no Secure Boot) which sets systemManagementModeRequired=false
                  # so those flags are never appended.
                  # (
                  #   { pkgs, ... }:
                  #   {
                  #     virtualisation.efi.OVMF = pkgs.OVMF;
                  #   }
                  # )
                ];


                # Force to true so NixOS doesn't inject '-nographic' which breaks CLI detach mode
                # by attaching the serial console to stdin and freezing on EOF.
                # We handle headless mode manually in qemuOptions instead.
                # virtualisation.graphics = true;
                # virtualisation.memorySize = qemuCfg.memory;
                # virtualisation.cores = qemuCfg.cores;

                # Our hand-assembled networking flags replace NixOS's defaults.
                # virtualisation.qemu.options = qemuCfg.qemuOptions;
                # virtualisation.qemu.networkingOptions = [ ];

                # Workaround: virtiofsd 1.14.0 crashes with a glibc buffer overflow on
                # --translate-uid=host:65534:0:1 (hardcoded in NixOS qemu-vm.nix) for
                # every vhost-user-fs connection, regardless of the shared directory size.
                # There is no NixOS option to remove the flag, so we eliminate virtiofsd
                # entirely:
                #   - useNixStoreImage: build an erofs image for /nix/store (no virtiofsd)
                #   - sharedDirectories = {}: drop the xchg/shared virtiofs shares too
                # The xchg/shared mounts are only used by NixOS activation script helpers
                # and are not required for normal VM boot.
                # virtualisation.useNixStoreImage = true;
                # virtualisation.sharedDirectories = lib.mkForce { };
              };
            };
          };
        };

      allPortKeys = lib.concatLists (
        lib.mapAttrsToList (
          hostName: host:
          lib.map (fwr: {
            inherit (fwr) proto;
            hostPort = fwr.host;
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
            assertion = lib.allUnique (lib.map (p: "${p.proto}:${toString p.hostPort}") allPortKeys);
            message = "[Alloy] VM port conflict: multiple VMs forward the same hypervisor port.";
          }
          {
            assertion = lib.allUnique (lib.mapAttrsToList (_: n: n.idx) alloy.qemu.nets);
            message = "[Alloy] qemu.nets: idx values must be globally unique.";
          }
        ];

        # indexes."qemu-nets" = {
        #   minValue = 1;
        #   maxValue = 99;
        #   keys = builtins.attrNames alloy.qemu.nets;
        # };

        _internal.state =
          { pkgs, ... }:
          {
            qemuNets = lib.mapAttrsToList (name: net: {
              inherit name;
              idx = net.idx;
            }) alloy.qemu.nets;
            qemuQuests = lib.pipe alloy.hosts [
              (lib.filterAttrs (_: host: host.qemu.variant != null))
              (lib.mapAttrsToList (
                hostName: host: {
                  host = hostName;
                  variant = host.qemu.variant;
                  path = lib.getExe (host.qemu.variants.${host.qemu.variant}.package { inherit pkgs; });
                  nets = lib.mapAttrsToList (netName: netHost: {
                    name = netName;
                    idx = alloy.qemu.nets.${netName}.idx;
                    iface = netHost.iface;
                    mac = netHost.mac;
                  }) host.qemu.nets;
                  forwardPorts = lib.map (fp: {
                    proto = fp.proto;
                    hostPort = fp.host;
                    guestPort = fp.guest;
                    name = fp.name;
                  }) host.qemu.forwardPorts;
                }
              ))
            ];
          };
      };
    };
}
