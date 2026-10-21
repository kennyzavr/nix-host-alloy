# QEMU development and guest updates

Read this for VM launch, serial consoles, persistent images, and boot tests.
[CLI and state](cli-state.md) describes metadata/build gates;
[SSH and boot](ssh-boot.md) describes local keys and initrd delivery.

## Configuration versus launcher

[qemu.nix](../../modules/core/qemu.nix) extends hosts with VM settings and registers
variant package callbacks. Each built-in variant evaluates `host.nixosModule`
together with `host.qemu.nixosModule`; the latter imports NixOS `qemu-vm.nix` and
adds networking, forwarding, memory, CPU, and console configuration.

- `direct-boot` uses the NixOS VM runner's external kernel/initrd boot path.
- `full-boot` adds `virtualisation.useBootLoader = true` by default. EFI is selected
  according to the systemd-boot / EFI configuration, not unconditionally.
- `disko-boot` is contributed by the explicit [disko](../../modules/disko.nix)
  extension and uses `system.build.vmWithDisko` when enabled.

`qemu.variant = null` means no default selected variant. The current CLI uses the
configured variant; there is no implemented `--variant` launch argument.
`extraPreScript { system; }` runs before the variant executable.

Known limitation: the disko variant callback currently requires `pkgs`, while the
core launcher calls variant packages with `{ system; }`. This callback has not
adopted the common interface; do not claim the variant is validated without
resolving or testing that mismatch.

The ordinary `host.nixosConfiguration` only evaluates the host module. It does
not inherit QEMU filesystems or bootloader overrides. A working VM launcher is
not evidence that an ordinary `nixosConfigurations` export can update that VM.
There is currently no core `qemu.variants.<name>.nixosConfiguration` option.

## Launch and runtime ownership

Use the configured CLI wrapper. For this example, enter the workspace directory
first so CLI fact paths and cache storage resolve consistently:

```sh
cd examples/simple-cluster
nix run ../..#simpleCluster-alloy-cli -- qemu list
nix run ../..#simpleCluster-alloy-cli -- qemu show iridium
nix run ../..#simpleCluster-alloy-cli -- qemu launch iridium
```

Launch is a runtime action: it builds scripts with Alloy validation enabled,
creates VDE networks, starts guests, and waits for them to exit. Host/tag selection
is implemented in [domain/qemu.rs](../../packages/alloy-core/src/domain/qemu.rs).
Process and socket ownership live in
[infra/qemu.rs](../../packages/alloy-core/src/infra/qemu.rs).

Global QEMU nets receive stable indexes from the `qemu-nets` index. Guest
attachments expose computed MAC/iface options; read those options rather than
reconstructing them. VDE socket locations are passed via
`ALLOY_VDE_SOCKET_<idx>`. VDE socket directories are temporary and owned by their
process handles.

Under `<cache-dir>/<alloy-name>/qemu/`, the runner maintains:

- `<host>.qcow2`, passed as `NIX_DISK_IMAGE`;
- `<host>-serial.sock`, passed as `ALLOY_SERIAL_SOCKET`;
- timestamped guest logs and VDE logs.

The CLI defaults `cache-dir` to `<CLI workspace root>/.alloy`. Supply the same
workspace/cache settings when launching and connecting. Disk names are keyed by
host, not by variant: do not assume changing variants creates a fresh disk.
Use a separate cache for experiments that require a different disk layout.

## Serial console

For guests launched with the serial socket enabled (`qemu.graphics = false`),
from the same example workspace directory:

```sh
nix run ../..#simpleCluster-alloy-cli -- qemu console iridium
```

This connects to an existing guest; it does not launch one. The adapter switches
the local terminal into raw mode and restores it on exit. **Ctrl+]** (byte `0x1d`)
disconnects; Ctrl+C is sent to the guest. Console metadata is loaded without
building launch scripts or running full assertions.

For diagnosis, a direct equivalent is:

```sh
socat STDIO,raw,echo=0,escape=0x1d UNIX-CONNECT:/path/to/iridium-serial.sock
```

## Updating an existing guest

To exercise host-local initrd secrets, use a guest with a bootloader and a
persistent disk. Direct boot takes its initrd from the external runner, so a
rebuild of `/boot` inside that guest does not test the next runner-supplied initrd.

For a `full-boot` update, build a system toplevel using the same host module,
QEMU module, and boot-mode settings used for the initial guest. Export that
configuration separately for `nixos-rebuild`. Do not hand-copy a guessed root
filesystem into an unrelated host export merely to satisfy an assertion.

You can build outside the guest and deploy the closure by SSH; the source flake
need not be installed in the guest. Select the VM-specific export and the main
system's SSH port. Installation of boot artifacts runs in the guest, where local
source keys exist. Building a new disk image on the development machine cannot
read a key generated inside an existing guest disk.

The integration example is editable infrastructure, not a guaranteed boot-test
fixture: inspect its current exports and local changes before using it. In
particular, a source key required by `boot.files` may exist only on the current
guest. Follow the two-stage procedure in [SSH and boot](ssh-boot.md).

When verifying a VM change, distinguish evaluation of a toplevel, construction of
a launcher/image, and actual boot of the intended persistent disk. Only the last
step validates the complete guest boot path.
