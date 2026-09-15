{ inputs, ... }: {
  flake.alloyModules.disko = { alib, lib, config, ... }:
  let
    alloy = config;
    hostSubmodule = { name, config, ... }: let 
      host = config;
    in {
      options.disko = lib.mkOption {
        type = lib.types.lazyAttrsOf lib.types.raw;
        default = {};
        description = "Instantiated Disko configuration for this host. Used by `disko` and `disko-install`.";
      };
      
      config = lib.mkIf (host.disko != {}) {
        nixosModule = {
          imports = [ inputs.disko.nixosModules.disko ];
          disko = host.disko;
        };

        qemu.variants.disko = {
          package = { pkgs, ... }: let
            # We build the disko images via the host's NixOS config (guest's pkgs are used inside this derivation).
            diskoImages = host.nixosConfiguration.config.system.build.diskoImages;
            
            # The runner script itself is built using the CLI host's pkgs!
            qemu = pkgs.qemu_kvm;
          in pkgs.writeShellScriptBin "run-${name}-qemu-disko" ''
            set -e

            if [ -z "$ALLOY_VMS_DIR" ]; then
              echo "ALLOY_VMS_DIR is not set. This script should be run via 'alloy qemu run'." >&2
              exit 1
            fi

            echo "Preparing Disko disk images in $ALLOY_VMS_DIR..."
            cd "$ALLOY_VMS_DIR"

            # Create writable overlays for every qcow2/raw image produced by disko
            for img in ${diskoImages}/*; do
              img_name=$(basename "$img")
              target_img="$ALLOY_VMS_DIR/overlay-$img_name.qcow2"
              if [ ! -e "$target_img" ]; then
                echo "Creating writable overlay for $img_name..."
                if [[ "$img_name" == *.qcow2 ]]; then
                  fmt="qcow2"
                else
                  fmt="raw"
                fi
                ${qemu}/bin/qemu-img create -f qcow2 -b "$img" -F "$fmt" "$target_img"
              fi
            done

            echo "Starting QEMU with Disko layout..."
            exec ${qemu}/bin/qemu-kvm \
              -name ${name} \
              -m ${toString host.qemu.memory} \
              -smp ${toString host.qemu.cores} \
              $(for img in "$ALLOY_VMS_DIR"/overlay-*.qcow2; do
                  echo "-drive file=$img,format=qcow2,if=virtio,cache=writeback,werror=report"
              done) \
              ${builtins.concatStringsSep " " host.qemu.qemuOptions} \
              "$@"
          '';
        };
      };
    };
  in {
    options.hosts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule hostSubmodule);
    };
  };
}
