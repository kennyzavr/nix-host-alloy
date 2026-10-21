# Architecture and source map

Read this for system boundaries and where to start investigating a task.
[Agent instructions](../../AGENTS.md) provide development rules and checks.

## Three layers

1. **Flake integration** registers deferred `alloyModules` and configured CLI
   wrappers. A consumer imports `alloy.flakeModules.default` and declares its
   infrastructure as an Alloy module. See [flakeModule.nix](../../flakeModule.nix).
2. **Alloy evaluation** uses `lib.evalModules` with Alloy options, then produces
   host/jail NixOS modules and a buildable state package. This is a separate
   evaluation layer from NixOS. [lib/default.nix](../../lib/default.nix) supplies
   `evalModules`, `evalModule`, custom types, DNS helpers, and `mkCli`.
3. **CLI execution** reads the state package and performs workspace operations
   through Rust adapters. Generated NixOS configurations also contain runtime
   services; “declarative Nix” does not mean every effect is performed by the CLI.

```text
consumer flake / alloyModules.<name>
        -> Alloy evalModules
             -> hosts/jails and their NixOS modules
             -> build.package { system; }
                  -> state.json + optional generator/VM scripts
                       -> alloy-cli -> workspace files / subprocesses
```

`name` identifies the Alloy configuration and namespaces VM runtime storage.
`workspace.root` identifies the workspace on the Nix side; the CLI separately
resolves its workspace root and cache directory. Relative state paths are
interpreted against the CLI workspace or state package, according to their
contract, not against arbitrary shell working directories. See
[CLI and state](cli-state.md).

## Sources by responsibility

| Responsibility | Entry points |
| --- | --- |
| Flake inputs, systems, formatter, development environment | [flake.nix](../../flake.nix), [packages/default.nix](../../packages/default.nix) |
| Default module composition and optional extensions | [modules/default.nix](../../modules/default.nix), [core/default.nix](../../modules/core/default.nix) |
| Hosts, NixOS evaluation, aggregate diagnostics | [hosts.nix](../../modules/core/hosts.nix) |
| systemd-nspawn jails, uplinks, forwarding, bind mounts | [jails.nix](../../modules/core/jails.nix), [volumes.nix](../../modules/core/volumes.nix) |
| Host networks, mesh and routes, service addresses | [nets.nix](../../modules/core/nets.nix), [overlays.nix](../../modules/core/overlays.nix), [endpoints.nix](../../modules/core/endpoints.nix) |
| Naming and certificate lifecycle | [dns.nix](../../modules/core/dns.nix), [tls/default.nix](../../modules/core/tls/default.nix), [mtls.nix](../../modules/core/mtls.nix) |
| Workspace data, encryption, allocation, generated artifacts | [facts.nix](../../modules/core/facts.nix), [secrets.nix](../../modules/core/secrets.nix), [indexes.nix](../../modules/core/indexes.nix), [generators.nix](../../modules/core/generators.nix) |
| Local accounts and access | [users.nix](../../modules/core/users.nix), [ssh.nix](../../modules/core/ssh.nix), [boot.nix](../../modules/core/boot.nix) |
| High-level service composition | [services/default.nix](../../modules/services/default.nix) |
| VM configuration and launch scripts | [qemu.nix](../../modules/core/qemu.nix) |
| Nix-to-CLI state assembly | [build.nix](../../modules/core/build.nix) |
| Rust domain, ports, serialization, adapters | [alloy-core/src](../../packages/alloy-core/src) |
| Arguments, reporting, editor, error rendering | [alloy-cli/src](../../packages/alloy-cli/src) |
| Integration example and CLI wrapper instance | [simple-cluster/default.nix](../../examples/simple-cluster/default.nix) |

The module and Rust source trees are the authoritative entity/field inventory.
Inspect option declarations rather than maintaining a second schema in prose.
The Rust workspace has two crates, defined in [Cargo.toml](../../Cargo.toml).
There is currently no checked-in `tests/` directory or explicit flake `checks`
suite; development commands and verification expectations are in
[AGENTS.md](../../AGENTS.md).

## Composition boundaries

`alloyModules.default` imports core and services. The explicit
[disko](../../modules/disko.nix) extension contributes host disk settings and a VM
variant. The explicit [home-manager](../../modules/home-manager.nix) extension wraps
host shared home configuration and per-user modules; the host enable flag gates
integration, and enabled users are selected within that host.

A host's `nixosConfiguration` evaluates its `nixosModule`. QEMU composes that
module with additional VM modules in a separate evaluation. A working VM launcher
therefore does not prove that the ordinary host export has a root filesystem or
that it can update the VM. See [QEMU configuration and deployment](qemu.md).

Service modules expand into core entities, which own deployment details. This
keeps networking, secrets, certificates, and container wiring reusable across
services. The composition and validation contracts are in
[Nix module design](nix-modules.md).
