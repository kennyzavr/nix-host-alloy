# Alloy Framework -- Agent Reference (AGENTS.md)

Dense technical guide for AI agents working on the Alloy codebase. Not a tutorial. Read fully before making any changes.

---

## What Alloy Is

Alloy is a Nix-based framework for declaring multi-host infrastructure as code. It provides:
- A custom module system (built on top of `lib.evalModules`, NOT the NixOS module system directly)
- Core abstractions: hosts, jails (systemd-nspawn), overlays (WireGuard mesh), endpoints, DNS, TLS, secrets, facts, generators, indexes, volumes, users, VMs
- Service modules that compose core abstractions into deployable services (DNS, HTTP edge, SMTP, CA, etc.)
- A Python CLI (`alloy-cli`) for imperative state management (secrets, facts, indexes, generators, VMs)

---

## Data Flow

```
User's flake.nix
  -> imports alloy.flakeModules.default (from parts.nix)
  -> defines flake.alloyModules.<name> = { alib, lib, config, ... }: { options = ...; config = ...; }
  -> alloy.lib.evalModule evaluates all modules into a single config
  -> config._internal.state is serialized to alloy-state.json in /nix/store
  -> alloy-cli is wrapped with ALLOY_STATE_FILE pointing to that JSON
  -> CLI reads JSON, operates on workspace (the Git repo)
```

Key: Nix side is purely declarative. CLI side is purely imperative. They communicate through `alloy-state.json`.

---

## Project Structure

```
flake.nix                     # Inputs: nixpkgs, flake-parts, agenix. Imports parts.nix, lib/, modules/
parts.nix                     # Defines flake.alloyModules option (lazyAttrsOf deferredModule)
lib/
  default.nix                 # evalModules, evalModule, mkCli, resolveZoneNode, mkArpaIpv6, types
  types.nix                   # Parallel type definitions (ageKeyPair, assertion, permissions, dns.*, ip.*, zoneNode, netMatchOpts)
modules/
  core/
    default.nix               # Imports all core modules, defines workspace + assertions options
    hosts.nix                 # Host entity: idx, system, nixosModule, nixosConfiguration, tags
    jails.nix                 # Jail entity: idx, host, uplink, nixosModule, tags. Bridge networking, NAT, containers
    overlays.nix              # WireGuard mesh: links, ipv6Prefix. Babeld routing, GRE tunnels
    endpoints.nix             # Service endpoints: targets (ipv6+overlay), loadBalancing, port
    dns.nix                   # Zones, records (all BIND types), CoreDNS per-node, internalDomain, resolveNode
    tls/
      default.nix             # Cert/CA options, cert lifecycle (wait/reload services), indexes
      acme.nix                # ACME cert source (DNS-01 challenge via dnsupdate)
      static.nix              # Static cert source (fact + secret references)
      generators.nix          # x509 CA + leaf cert generators (Python/cryptography, ECDSA P-256)
    secrets.nix               # 3-tier: master (global), host (agenix rekeyed), jail (bind-mounted). Secret templates with placeholder substitution
    facts.nix                 # Plain-text versioned data in workspace
    generators.nix            # Script orchestration: templates (reusable), instances (concrete). DAG ordering
    indexes.nix               # Unique integer allocation backed by fact files. Range-checked, gap-filled
    mtls.nix                  # Auto mTLS: root CA + per-node leaf certs. SAN from overlays/endpoints/domains
    volumes.nix               # Persistent jail storage: directory driver, bind-mounts, tmpfiles permissions
    users.nix                 # Per-host users: isAdmin, hashedPasswd (secret+generator). Immutable users
    nets.nix                  # Host network interfaces: static systemd-networkd config, primary/default net
    ssh.nix                   # SSH server config: listen on specific nets, per-user authorized keys from facts
    vm.nix                    # VM testing: QEMU multicast networking, port forwarding, per-host enable/config
    state.nix                 # _internal.state option: functionTo (attrsOf anything)
    cli.nix                   # CLI package: wraps alloy-cli with ALLOY_STATE_FILE
  services/
    default.nix               # Imports all 10 service modules
    ca.nix                    # Certificate Authority (step-ca + nginx)
    dns-auth.nix              # Authoritative DNS (Knot)
    dns-acme.nix              # ACME DNS challenge server (Knot + TSIG)
    dns-edge.nix              # DNS edge proxy (dnsdist)
    dns-resolver.nix          # Recursive resolver (knot-resolver)
    http-edge.nix             # HTTP reverse proxy (nginx)
    tls-edge.nix              # TCP/TLS L4 proxy (HAProxy)
    smtp-edge.nix             # SMTP relay (Postfix + rspamd + ClamAV)
    postbox.nix               # Mailbox server (Postfix + Dovecot + nginx)
    xhttp-proxy.nix           # Xray VLESS-over-XHTTP tunnel (censorship circumvention)
packages/
  alloy-cli/
    pyproject.toml            # Entry: alloy_cli.main:main, deps: rich, build: setuptools
    alloy_cli/
      main.py                 # Argparse CLI entry, state loading, command dispatch
      cli.py                  # CLI class: workspace root detection, rich output (step/ok/skip/info/error/abort)
      di.py                   # Dependency injection container: lazy singleton properties
      commands/               # Presentation layer: thin handlers (parse args -> call service -> format output)
        facts.py generators.py hosts.py indexes.py jails.py overlays.py secrets.py state.py vms.py
        utils.py views.py
      domain/                 # Business logic: services with typed exceptions
        exceptions.py facts.py generators.py indexes.py secrets.py vms.py
      data/                   # Data access: repository classes reading from alloy-state.json dict
        models.py state.py
      infrastructure/         # External system adapters
        fs.py git.py crypto.py editor.py script_runner.py qemu.py
```

---

## Core Entities -- Quick Reference

| Entity | Option Path | Index Range | Key Fields |
|--------|------------|-------------|------------|
| Host | `hosts.<name>` | 1-99 | `system`, `nixosModule`, `tags`, `idx` (auto) |
| Jail | `jails.<name>` | 1-999 | `host`, `nixosModule`, `tags`, `uplink.{allowEgress,forwards}` |
| Overlay | `overlays.<name>` | 1-99 | `links[].{a.host, b.host}`, `ipv6Prefix` (auto) |
| Endpoint | `endpoints.<name>` | -- | `port`, `targets[].{ipv6, overlay}`, `loadBalancing.policy` |
| DNS Zone | `dns.zones.<name>` | -- | `apex`, `parentZone`, `rname`, `ttl` |
| TLS Cert | `tls.certs.<name>` | 1-999 | `domains[]`, `ca`, `src.{acme,static}` |
| TLS CA | `tls.ca.<name>` | -- | `certFact` |
| Secret | `secrets.<name>` | -- | `file`, `path`, `tags` |
| Fact | `facts.<name>` | -- | `file`, `value`, `tags` |
| Generator | `generators.instances.<name>` | -- | `package`, `wants`, `wantedBy`, `before`, `after`, `facts`, `secrets` |
| Index | `indexes.<name>` | -- | `keys`, `minValue`, `maxValue`, `factName` |
| Volume | `jails.<name>.volumes.<name>` | -- | `path`, `driver.directory`, `permissions` |
| User | `hosts.<name>.users.<name>` | -- | `isAdmin`, `hashedPasswd` |
| VM | `hosts.<name>.vm` | -- | `enable`, `memory`, `cores`, `forwardPorts[]`, `mac`, `variants`, `defaultVariant`, `nixosModule` |

### Cross-module extensions

Multiple core modules extend the same entity types. The complete option tree for a host:

```
hosts.<name>.{
  idx, system, nixosModule, nixosConfiguration, tags, assertions,
  # From jails.nix:  (bridge network generated on host side)
  # From overlays.nix:
  overlays.<overlay>.{ ipv6Prefix, ipv6, firewall, babeld.localPort, wg.{port, endpoint} },
  # From secrets.nix:
  secrets.<name>.{ file, path, permissions, placeholder },
  secretTemplates.<name>.{ template, path, permissions },
  workspace.secrets.{ baseDir, basePath, age.keyPairs },
  # From dns.nix:
  domain,  # readOnly: "<name>.host.<internalDomain>"
  # From nets.nix:
  nets.<iface>.{ static, primary, default, iface, v4, v6 },
  primaryNet,  # readOnly
  # From users.nix:
  users.<name>.{ isAdmin, hashedPasswd.{secret, generator} },
  # From ssh.nix:
  ssh.{ enable, listen[].{net, port} },
  users.<name>.ssh.{ allowPasswdAuth, authKeyFacts },
  # From endpoints.nix:
  endpoints.<name>,
  # From tls/:
  tls.certs.<name>.{ reloadServices, restartServices, group, gid, certPath, keyPath, fullPath },
  # From mtls.nix:
  mtls.{ certPath, keyPath, fullPath, permissions },
  # From vm.nix:
  vm.{ enable, memory, cores, graphics, forwardPorts[], extraQemuOptions, nixosModule, mac, networkQemuOptions, variants, defaultVariant },
}
```

Top-level (not per-host): `name` -- unique identifier for this Alloy configuration (required, no default). Used by the CLI to namespace local runtime state (see VM Subsystem below) when a single flake evaluates multiple Alloy configurations against the same workspace.

---

## alloy-state.json Keys

Modules contribute to `_internal.state` which becomes the JSON the CLI reads:

| Key | Contributed By | Python Model |
|-----|---------------|--------------|
| `name` | `modules/core/default.nix` | plain `str`, read via `Container.db.get("name")` |
| `hosts` | hosts.nix | `HostRecord(name, tags)` |
| `jails` | jails.nix | `JailRecord(name, host, tags)` |
| `overlays` | overlays.nix | `OverlayRecord(name, ipv6Prefix, tags, links)` |
| `hostOverlays` | overlays.nix | `HostOverlayRecord(name, host, ipv6)` |
| `jailOverlays` | overlays.nix | `JailOverlayRecord(name, jail, ipv6)` |
| `facts` | facts.nix | `FactRecord(name, file, tags)` |
| `indexes` | indexes.nix | `IndexRecord(name, factName, keys, minValue, maxValue)` |
| `generators` | generators.nix | `GeneratorRecord(name, bin, wants, wantedBy, before, after, tags, secrets, facts)` |
| `masterSecrets` | secrets.nix | `MasterSecretRecord(name, file, tags)` |
| `masterSecretRecipients` | secrets.nix | `RecipientRecord(key)` |
| `masterSecretIdentities` | secrets.nix | `IdentityRecord(path)` |
| `hostSecrets` | secrets.nix | `HostSecretRecord(name, host, file)` |
| `hostSecretRecipients` | secrets.nix | `RecipientRecord(key)` per host |
| `jailSecrets` | secrets.nix | `JailSecretRecord(name, jail, file)` |
| `jailSecretRecipients` | secrets.nix | `RecipientRecord(key)` per jail |
| `vms` | vm.nix | `VmRecord(name, tags, mac, variants, defaultVariant, forwardPorts)` |

---

## CLI Architecture (Rust)

The Alloy CLI has been rewritten in Rust for speed, strict typing, and separation of concerns. It is divided into three crates:

1. **`alloy-cli`**: Presentation layer (Clap arguments, rich terminal output, error rendering).
2. **`alloy-core`**: Pure business logic (domain models, interfaces/ports, flat data search).
3. **`alloy-infra`**: Adapters for external systems (Nix eval, Git, Rage, QEMU, VDE, FileSystem).

**For full details on the Rust CLI architecture, see [ARCHITECTURE.md](ARCHITECTURE.md).**

---

## Service Module Contract

Every service module follows this pattern:

```nix
{ flake.alloyModules.services = { alib, lib, config, ... }:
  let
    alloy = config;
    serviceSubmodule = { config, name, ... }: { options = { ... }; };
    mkService = srvName: srv: {
      jails."svc-${srvName}" = { host = srv.host; nixosModule = ...; };
      endpoints."svc-${srvName}" = { port = ...; targets = [...]; };
      assertions = [ ... ];
      # Can also produce: dns.records, facts, secrets, generators.instances, tls.certs
    };
  in {
    options.services."my-service" = lib.mkOption { type = lib.types.attrsOf (lib.types.submodule serviceSubmodule); };
    config = let
      services = lib.pipe alloy.services."my-service" [ (lib.filterAttrs (_: s: s.enable)) (lib.mapAttrsToList mkService) ];
    in {
      jails = lib.mkMerge (map (s: s.jails or {}) services);
      endpoints = lib.mkMerge (map (s: s.endpoints or {}) services);
      assertions = lib.mkMerge (map (s: s.assertions or []) services);
    };
  };
}
```

Register in `modules/services/default.nix`.

---

## Nix Patterns

**Computed/constant values -- `readOnly` option with inline `default`, not a shared `lib` function.**

When a value is deterministically derivable from other config (an address, a MAC, a generated port, a derived string) and is not meant to be set by the user, expose it as a `readOnly = true` option with the computation inlined in `default`, scoped to the submodule that owns the source data. Do NOT factor the computation out into a standalone `alib`/`lib` helper function "for reuse" -- reuse happens by *reading the resulting option value* from other modules, not by re-running the computation.

```nix
# modules/core/overlays.nix -- existing precedent
options.ipv6Prefix = lib.mkOption {
  type = lib.types.str;
  readOnly = true;
  default = "${overlay.ipv6Prefix}:${lib.fixedWidthString 4 "0" (lib.toLower (lib.toHexString host.idx))}";
};
```

Rationale:
- Other modules (e.g. a future `disko` module extending `hosts.<name>.vm`) read `host.vm.mac` / `host.vm.networkQemuOptions` directly instead of importing and re-invoking a helper -- one source of truth, no risk of two modules computing the same thing slightly differently.
- Keeps the value visible and inspectable via `nix eval`/`alloy state show` like any other option, instead of being buried in a `let`-bound function.
- Matches the existing convention (`overlays.nix` `ipv6`/`ipv6Prefix`, `secrets.nix` `path`/`file` defaults) -- stay consistent, don't introduce a second style for the same problem.

Only reach for a shared `lib`/`alib` function when the logic is a genuine multi-input *transformation* invoked with different arguments across call sites (e.g. `alib.types.*`, `resolveZoneNode`) -- not for "compute this one value once and let others read it".

**Pitfall: don't parametrize a submodule's own type by its enclosing module's `config`, then write into that submodule from a `mkIf` gated on a field of that same submodule.**

This produces a genuine infinite-recursion error, not just an ugly one. Concretely: `hostSubmodule = { config, ... }: let host = config; in { options.vm = lib.mkOption { type = lib.types.submodule (vmSubmodule host); }; config = lib.mkIf host.vm.enable { vm.foo = "..."; }; };` -- deciding whether the `mkIf`'s definition of `vm.foo` applies requires resolving `host.vm.enable`, but `host.vm`'s type was itself constructed from `host` (the same fixed point), which now also carries this very definition. `modules/core/vm.nix` hit exactly this when introducing `vm.variants`/`vm.mac`.

Fix: keep the submodule's own option declarations free of self-references to the enclosing module. If a value legitimately needs outer context (e.g. `host.idx` for a MAC address), assign it via an **unconditional** `config.vm.xxx = ...;` in the enclosing module instead of a self-referential `default`, and only wrap the *leaf value* -- not the surrounding attrset -- in `lib.mkIf` when the assignment does need to be conditional (`vm.variants.qemu-vm = lib.mkIf vmCfg.enable "...";`, not `lib.mkIf vmCfg.enable { vm.variants.qemu-vm = "..."; }`).

---

## VM Subsystem

QEMU-based testing without root privileges. Inter-VM networking via a `vde_switch` L2 bridge (started by the CLI at `alloy qemu run` time), host access via port forwarding.

**Nix side** (`modules/core/vm.nix`):
- `hosts.<name>.vm.enable` -- opt-in per host
- `hosts.<name>.vm.{memory, cores, graphics, forwardPorts[], extraQemuOptions, nixosModule}`
- `hosts.<name>.vm.mac`, `hosts.<name>.vm.networkQemuOptions` -- `readOnly` options; values are assigned unconditionally in `hostSubmodule.config` (see the Nix Patterns pitfall above for why they can't use a self-referential `default` inside the `vm` submodule itself). Any variant module reads these instead of recomputing them.
- `networkQemuOptions` includes `-netdev vde,id=net1,sock=$ALLOY_VDE_SOCKET` -- the env var is set by the CLI before launching the VM script
- `hosts.<name>.vm.variants.<name>` (`attrsOf path`) -- each launch-script implementation registers its own key (e.g. `qemu-vm` from core, `disko` from an optional `disko` module), value = relative path to the launch script inside `state_path`; `hosts.<name>.vm.defaultVariant` (`nullOr str`) picks which key the CLI runs by default
- `nixosModule` -- extension point for injecting NixOS config into the default (`qemu-vm`) variant specifically
- Guest interface `eth1` always carries `192.168.100.<idx>/24` -- predictable, host-idx-derived, static

**CLI side** (`alloy qemu`):
- `alloy-infra::qemu` -- `LocalQemuHost` (foreground process launch, disk images) + `LocalVdeHost` (vde_switch lifecycle, waits for socket up to 5s)
- `alloy-core::qemu` -- `launch` function resolves dependencies (networks) and uses RAII to automatically clean up VDE sockets when done.
- `alloy-cli::commands::qemu` -- thin presentation layer; `run` finds hosts and calls core logic.
- VMs always run attached to the terminal (foreground only, single or multiple at once); there is no detached mode, no CLI-managed PID file -- process lifetime is tied 1:1 to the `alloy qemu run` invocation, cleanup happens via normal child-process signal propagation (Ctrl+C / terminal close) or `Drop` trait execution.
- VDE switch socket lives in a `std::fs::create_dir_all`-created directory under `/tmp/alloy/<name>`; no persistent socket across sessions.
- VM runtime state (disk images, per-VM logs) lives in `cache_dir` (default: `<workspace_root>/.alloy/vms/<name>/`).

---

## Strict Rules

1. **NEVER modify files in `facts/`, `secrets/`** -- managed by CLI
2. **Services MUST produce core entities** (jails, endpoints, etc.), never raw NixOS config
3. **Use `alloy.dns.resolveNode`** for domain resolution, never manual concatenation
4. **Use `alib.types`** for custom types, never redefine
5. **NEVER `builtins.import <nixpkgs>`** -- use the `pkgs` argument
6. **Jail secrets use `config.secrets.<name>.path`**, never `config.age.secrets`
7. **ALWAYS define assertions** for cross-entity references
8. **ALWAYS check entity existence** with `builtins.hasAttr` before referencing
9. **`_internal.state` is the bridge** from Nix to CLI -- add keys here for new CLI features
10. **Formatter: `nixfmt`** (nixfmt-tree). All Nix code must be formatted.
11. **`config` is aliased as `alloy`** in module let-bindings for readability
