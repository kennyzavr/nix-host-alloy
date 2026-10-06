# Alloy Framework -- Agent Reference (AGENTS.md)

Dense technical guide for AI agents working on the Alloy codebase. Not a tutorial. Read fully before making any changes.

---

## What Alloy Is

Alloy is a Nix-based framework for declaring multi-host infrastructure as code. It provides:
- A custom module system (built on top of `lib.evalModules`, NOT the NixOS module system directly)
- Core abstractions: hosts, jails (systemd-nspawn), overlays (WireGuard mesh), endpoints, DNS, TLS, secrets, facts, generators, indexes, volumes, users, VMs
- Service modules that compose core abstractions into deployable services (DNS, HTTP edge, SMTP, CA, etc.)
- A Rust CLI (`alloy-cli`) for imperative state management (secrets, facts, indexes, generators, QEMU VMs)

---

## Data Flow

```
User's flake.nix
  -> imports alloy.flakeModules.default (from parts.nix)
  -> defines flake.alloyModules.<name> = { alib, lib, config, ... }: { options = ...; config = ...; }
  -> alloy.lib.evalModules evaluates all modules into a single config
  -> config._internal.statePackage { inherit pkgs; mode = "full"|"base"; }
     builds a derivation containing:
       - state.json          (serialized _internal.state)
       - bin/hosts/<h>/qemu/<variant>  (symlinks to QEMU launch scripts, "full" mode only)
  -> alloy-cli reads state.json, operates on the workspace (the Git repo)
```

Key: Nix side is purely declarative. CLI side is purely imperative. They communicate through `state.json` inside the built package.

State is built in two modes:
- **`base`** — secrets, facts, generators, indexes only. No QEMU scripts. Fast for most CLI operations.
- **`full`** — includes QEMU guest variants and all script symlinks. Required for `alloy qemu run`.

---

## Project Structure

```
flake.nix                     # Inputs: nixpkgs, flake-parts, agenix, disko. Imports parts.nix, lib/, modules/
parts.nix                     # Defines flake.alloyModules option (lazyAttrsOf deferredModule)
lib/
  default.nix                 # evalModules, evalModule, resolveZoneNode, mkArpaIpv6, types
  types.nix                   # Parallel type definitions (ageKeyPair, assertion, permissions, dns.*, ip.*, zoneNode, netMatchOpts)
modules/
  core/
    default.nix               # Imports all core modules, defines workspace + name + assertions options
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
    boot.nix                  # Boot options: initrd facts (secrets embedded into initrd via boot.initrd.secrets)
    qemu.nix                  # QEMU VM testing: nets, variants (direct-boot, full-boot), forwardPorts, vde_switch
    state.nix                 # _internal.{state,stateScript,statePackage} options
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
  disko.nix                   # Optional disko module: hosts.<name>.disko.{enable,settings}, adds "disko-boot" QEMU variant
  default.nix                 # Assembles alloyModules.default = core + services (disko is opt-in)
packages/
  alloy-cli/                  # Presentation layer (Rust binary)
    src/
      main.rs                 # Entry point: parse Args, dispatch to commands::handle_args
      ctx.rs                  # Ctx struct: binds Env + System, implements domain::ports::Ctx
      term_ui.rs              # TermUi: rich terminal output (ok/skip/info/error/step/table/data)
      editor.rs               # $EDITOR integration for secret editing
      error.rs                # Error rendering: chain display with source indentation
      commands/
        mod.rs                # Args (Clap): workspace-root, state-source, module-source, alloy-url, nixpkgs-url, flake-url, depth, force, add-to-git, show-nix-trace, cache-dir
        facts.rs              # alloy facts {list,get,set,edit,delete}
        gens.rs               # alloy gens {list,run}
        indexes.rs            # alloy indexes {list,show}
        secrets.rs            # alloy secrets {list,show,get,set,edit,rekey,refs}
        qemu.rs               # alloy qemu {run,list,show}
    Cargo.toml                # deps: clap, serde, color-eyre, owo-colors, comfy-table, age, petgraph, alloy-core
  alloy-core/                 # Domain + infrastructure (Rust library)
    src/
      lib.rs                  # pub mod domain; pub mod infra;
      domain/
        mod.rs                # NameMarker, PathMarker, DynError; re-exports submodules
        env.rs                # Env struct + env var constants; EnvStateSource (full|base=path); EnvModuleSource (file|flake-attr)
        models.rs             # Serde-deserialized State, Host, Jail, Secret, Fact, Gen, Index, Qemu, QemuGuest, AgeKeyPair, ...
        ports.rs              # Traits: Ctx, Nix, Fs, Git, Age, GenRunner, QemuRunner, VdeSwitchProc, QemuGuestProc, Reporter
        state.rs              # load_state(full, ctx) -> State; reset_state
        facts.rs              # domain logic: list/get/set/delete facts
        gens.rs               # domain logic: list/run generators (DAG via petgraph)
        hosts.rs              # Host<'s> wrapper + FindHostError
        indexes.rs            # Index<'s> wrapper, read/write index fact file
        jails.rs              # Jail<'s> wrapper + FindJailError
        secrets.rs            # Secret, SecretRef: find/read/write/rekey; all secret domain operations
        qemu.rs               # QemuOpts, QemuGuest: find; launch_qemu_guests, list_qemu_guests, show_qemu_guest
      infra/
        mod.rs                # pub struct System {}; ExecError; pub use nix::*; pub use qemu::*
        nix.rs                # System impl Nix: trigger_assertions, eval_state (nix build --impure --expr)
        qemu.rs               # System impl QemuRunner: launch_guest (vde socket env injection), launch_vde (vde_switch process)
        age.rs                # System impl Age: encrypt/decrypt via age crate
        fs.rs                 # System impl Fs: exists, mk_parent_dirs, read, write (force flag)
        git.rs                # System impl Git: check (is tracked), add (git add)
        gens.rs               # System impl GenRunner: exec_gen (subprocess, env injection)
    Cargo.toml                # deps: serde, petgraph, itertools, either, chrono, tempfile, thiserror, log
  rust.nix                    # Nix package build for both crates (used by flake)
Cargo.toml                    # Workspace: members = [packages/alloy-cli, packages/alloy-core], edition=2024
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
| Secret (master) | `secrets.<name>` | -- | `file`, `tags`, `exists` (readOnly) |
| Fact | `facts.<name>` | -- | `file`, `value`, `tags` |
| Generator | `generators.instances.<name>` | -- | `package`, `wants`, `wantedBy`, `before`, `after`, `facts`, `secrets` |
| Index | `indexes.<name>` | -- | `keys`, `minValue`, `maxValue`, `factName` |
| Volume | `jails.<name>.volumes.<name>` | -- | `path`, `driver.directory`, `permissions` |
| User | `hosts.<name>.users.<name>` | -- | `isAdmin`, `hashedPasswd` |
| QEMU nets | `qemu.nets.<name>` | 1-99 | `idx` (auto via `qemu-nets` index) |
| QEMU guest | `hosts.<name>.qemu` | -- | `memory`, `cores`, `graphics`, `nets`, `forwardPorts`, `variants`, `variant`, `nixosModule` |

### Cross-module extensions

The complete option tree for a host (contributions from all modules):

```
hosts.<name>.{
  idx, system, nixosModule, nixosConfiguration, tags, assertions,
  # From secrets.nix:
  secrets.<name>.{ file, path, permissions, placeholder },
  secretTemplates.<name>.{ template, path, permissions },
  workspace.secrets.{ baseDir, basePath, age.keyPairs },
  workspace.secretTemplates.basePath,
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
  tls.certs.<name>.{ reloadServices, restartServices, group, gid, certPath, keyPath, fullPath, waitService, reloadService },
  # From mtls.nix:
  mtls.{ certPath, keyPath, fullPath, permissions },
  # From boot.nix:
  boot.{ facts.<name>.path, factsBasePath },
  # From qemu.nix:
  qemu.{ memory, cores, graphics, nets.<name>.{mac,iface}, forwardPorts[], nixosModule, variants.<name>.package, variant },
  # From disko.nix (opt-in, not in alloyModules.default):
  disko.{ enable, settings },
}
```

Top-level (not per-host): `name` -- unique identifier for this Alloy configuration (required, no default). Namespaces CLI runtime state (cache dir subdirectory).

Global workspace options:
- `workspace.root` -- path to workspace root (required)
- `workspace.baseDir` -- relative base dir (default: `"."`)
- `workspace.secrets.baseDir` -- master secrets dir (default: `"./secrets/masters"`)
- `workspace.secrets.age.keyPairs` -- global age key pairs for master secrets

---

## alloy-state.json Keys (models.rs State struct)

Modules contribute to `_internal.state` which becomes the JSON the CLI reads. The Rust `State` struct in `alloy-core/src/domain/models.rs` defines the deserialization schema:

| JSON key | Rust field | Contributed by | Notes |
|----------|-----------|----------------|-------|
| `name` | `State.name` | `core/default.nix` | Plain string |
| `secretsAgeKeyPairs` | `State.secrets_age_key_pairs: Vec<AgeKeyPair>` | `secrets.nix` | Global master age key pairs |
| `secrets` | `State.secrets: HashMap<String, Secret>` | `secrets.nix` | Master secrets: `{file, tags}` |
| `hosts` | `State.hosts: HashMap<String, Host>` | `hosts.nix`, `secrets.nix`, `qemu.nix` | Host records |
| `hosts.<h>.tags` | `Host.tags` | `hosts.nix` | |
| `hosts.<h>.secrets` | `Host.secrets: HashMap<String, SecretRef>` | `secrets.nix` | `{file, path}` per secret |
| `hosts.<h>.secretsAgeKeyPairs` | `Host.secrets_age_key_pairs` | `secrets.nix` | Host-specific age key pairs |
| `hosts.<h>.qemu` | `Host.qemu: Option<QemuGuest>` | `qemu.nix` | Null in base mode |
| `jails` | `State.jails: HashMap<String, Jail>` | `jails.nix`, `secrets.nix` | `{host, tags, secrets}` |
| `facts` | `State.facts: HashMap<String, Fact>` | `facts.nix` | `{file, tags}` |
| `generators` | `State.gens: HashMap<String, Gen>` | `generators.nix` | `{wants, after, tags, secrets, facts, scriptPath}` |
| `indexes` | `State.indexes: HashMap<String, Index>` | `indexes.nix` | `{keys, minValue, maxValue, factName}` |
| `qemu` | `State.qemu: Option<Qemu>` | `qemu.nix` | Global QEMU nets; null in base mode |

`QemuGuest` fields: `nets: HashMap<name, QemuNetRef{iface, mac}>`, `portForwards: Vec<QemuPortForward{name, proto, hypervisor, guest}>`, `variants: HashMap<name, QemuVariant{scriptPath}>`, `variant: Option<String>`.

---

## CLI Architecture (Rust, 2 crates)

The Alloy CLI is written in Rust and split into two crates:

### `alloy-core` (library)

Pure domain logic and infrastructure adapters. No terminal I/O.

- **`domain/`** — business logic, typed errors, no side effects except through `ports::Ctx`
  - `env.rs` — `Env` struct (all CLI configuration), env var name constants, `EnvStateSource`, `EnvModuleSource`
  - `models.rs` — Serde structs deserializing `state.json`
  - `ports.rs` — Traits: `Ctx` (aggregates all port traits), `Nix`, `Fs`, `Git`, `Age`, `GenRunner`, `QemuRunner`, `VdeSwitchProc`, `QemuGuestProc`, `Reporter<C, T>`
  - `state.rs` — `load_state(full, ctx)` → `State`; `reset_state`
  - `hosts.rs`, `jails.rs`, `secrets.rs`, `facts.rs`, `gens.rs`, `indexes.rs`, `qemu.rs` — domain operations

- **`infra/`** — concrete implementations of port traits, all behind `System` struct
  - `nix.rs` — `System impl Nix`: calls `nix build --impure --expr` to build state package, `nix eval` to trigger assertions
  - `qemu.rs` — `System impl QemuRunner`: spawns `vde_switch` (using `tempfile::TempDir` for socket), spawns QEMU script
  - `age.rs` — `System impl Age`: encrypt/decrypt via `age` crate
  - `fs.rs`, `git.rs`, `gens.rs` — filesystem, git, generator runner

### `alloy-cli` (binary)

Thin presentation layer. Parses args, calls domain functions, formats output.

- `main.rs` — reads `ALLOY_DEPTH` env, parses `Args`, calls `handle_args`
- `ctx.rs` — `Ctx` struct implementing `domain::ports::Ctx` (wraps `Env + System`)
- `term_ui.rs` — `TermUi`: `print_ok/skip/info/error/step/table/data/raw_data`; colorizes `` `name` `` and `'path'` markers in messages
- `error.rs` — renders full error chain with source indentation
- `editor.rs` — opens `$EDITOR` on a tempfile, returns edited bytes
- `commands/mod.rs` — top-level `Args` (Clap): `--workspace-root`, `--state-source`, `--module-source`, `--alloy-url`, `--nixpkgs-url`, `--flake-url`, `--depth`, `--force`, `--add-to-git`, `--cache-dir`, `--show-nix-trace`; subcommands: `Facts`, `Gens`, `Indexes`, `Secrets`, `Qemu`

**State loading**: CLI calls `load_state(full=false, ctx)` for most operations (fast), and `load_state(full=true, ctx)` for `qemu run` (builds full package with scripts). The path is cached in `ctx.env().state_source` after first load.

**Nix eval expression** (from `infra/nix.rs`): dynamically builds a Nix expression that:
```nix
let
  pkgs = (builtins.getFlake "<nixpkgs-url>").legacyPackages.${builtins.currentSystem};
  alloyLib = (builtins.getFlake "<alloy-url>").lib;
  alloyModule = <module-source>;
  res = alloyLib.evalModules { modules = [alloyModule]; checkAssertions = <bool>; };
in
  <inner-expr>
```
where `<inner-expr>` is `res.config._internal.statePackage { inherit pkgs; mode = "full"|"base"; }` for state build.

---

## `_internal.state` and `_internal.statePackage`

Defined in `modules/core/state.nix`:

```nix
options._internal = {
  state       = lib.mkOption { type = functionTo (attrsOf anything); };   # args -> attrset merged from all modules
  stateScript = lib.mkOption { type = functionTo lines; };                # args -> shell script (symlinks, etc.)
  statePackage = lib.mkOption { type = functionTo package; readOnly = true; };  # args -> derivation
};

config._internal.statePackage = { pkgs, ... }@args:
  pkgs.runCommand "alloy-state" {} ''
    mkdir -p $out/bin
    cat > $out/state.json <<'EOF'
    ${builtins.toJSON (alloy._internal.state args)}
    EOF
    ${alloy._internal.stateScript args}
  '';
```

Each module that contributes to state does so by merging into `_internal.state`:
```nix
config._internal.state = { pkgs, mode, ... }: { ... };
```
And optionally into `_internal.stateScript` for binary artifacts (QEMU scripts).

---

## VM / QEMU Subsystem

QEMU-based testing without root privileges. Inter-VM networking via `vde_switch` L2 bridges.

**Nix side** (`modules/core/qemu.nix`):
- `qemu.nets.<name>` — global network definitions; `idx` is auto-allocated via `qemu-nets` index (range 1-99)
- `hosts.<name>.qemu.{memory, cores, graphics, forwardPorts[], nixosModule, variants, variant}`
- `hosts.<name>.qemu.nets.<name>` — per-host net attachment; `mac` and `iface` are `readOnly` computed options
  - `mac = "52:54:00:00:<hIdx>:<nIdx>"` (host idx + net idx, hex)
  - `iface = "eth<net.idx>"`
- Built-in variants (contributed by `qemu.nix` via `config.variants`):
  - `"direct-boot"` — `nixosSystem { ... }.config.system.build.vm` (NixOS qemu-vm module)
  - `"full-boot"` — same + `virtualisation.useBootLoader = true` (EFI boot)
- Optional variant (contributed by `modules/disko.nix`):
  - `"disko-boot"` — `vmWithDisko` (requires `hosts.<name>.disko.enable = true`)
- `variant = null` means no default; set to e.g. `"direct-boot"` to make it the CLI default
- VDE socket env: `ALLOY_VDE_SOCKET_<idx>` injected per net before launching the script
- Disk image: `$NIX_DISK_IMAGE` env var, stored at `<cache-dir>/<alloy-name>/qemu/<host-name>.qcow2`
- QEMU logs: `<cache-dir>/<alloy-name>/qemu/<host-name>_log_<timestamp>.log`

**CLI side** (`alloy qemu`):
- `qemu run [hosts...] [--tags ...] [--variant <name>]` — builds full state, creates VDE switches for all referenced nets, launches QEMU guest processes, waits for all to exit
- `qemu list [hosts...] [--tags ...]` — lists configured QEMU guests
- `qemu show <host>` — shows QEMU config for a specific host
- VDE switch socket lives in a `TempDir` (auto-cleaned when `VdeSwitchProc` is dropped)
- VM runtime: cache dir at `<workspace-root>/.alloy/<alloy-name>/qemu/`

**`disko.nix`** (`modules/disko.nix`):
- Opt-in module, NOT included in `alloyModules.default`; user imports `self.alloyModules.disko` separately
- Extends `hosts.<name>` with `disko.{enable, settings}` options
- When `enable = true`: merges disko NixOS module into `host.nixosModule` and registers `"disko-boot"` variant

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
- Other modules read `host.qemu.nets.<n>.mac` / `host.qemu.nets.<n>.iface` directly instead of importing and re-invoking a helper -- one source of truth, no risk of two modules computing the same thing slightly differently.
- Keeps the value visible and inspectable via `nix eval` like any other option.
- Matches the existing convention (`overlays.nix` `ipv6`/`ipv6Prefix`, `secrets.nix` `path`/`file` defaults).

Only reach for a shared `lib`/`alib` function when the logic is a genuine multi-input *transformation* invoked with different arguments across call sites (e.g. `alib.types.*`, `resolveZoneNode`) -- not for "compute this one value once and let others read it".

**Pitfall: don't parametrize a submodule's own type by its enclosing module's `config`, then write into that submodule from a `mkIf` gated on a field of that same submodule.**

This produces infinite recursion. Fix: keep submodule option declarations free of self-references to the enclosing module. If a value needs outer context, assign it via an **unconditional** `config.qemu.xxx = ...;` in the enclosing module. Only wrap the *leaf value* -- not the surrounding attrset -- in `lib.mkIf` when needed.

**`_internal.state` merge semantics**: each module uses `config._internal.state = { pkgs, mode, ... }: { ... };`. Because `state` is `functionTo (attrsOf anything)`, multiple modules' contributions are deep-merged via `lib.mkMerge` (applied to the function results). Use `mode == "full"` checks inside the function body to gate expensive/full content.

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
9. **`_internal.state` is the bridge** from Nix to CLI -- add keys here for new CLI features; update `models.rs` correspondingly
10. **Formatter: `nixfmt`** (nixfmt-tree). All Nix code must be formatted.
11. **`config` is aliased as `alloy`** in module let-bindings for readability
12. **CLI crates**: 2 crates only -- `alloy-cli` (presentation) and `alloy-core` (domain + infra). There is no separate `alloy-infra` crate; infra code lives in `alloy-core::infra`.
13. **`disko.nix`** is an opt-in extension at `modules/disko.nix`, NOT part of `alloyModules.default`. Users must explicitly import `self.alloyModules.disko` to use it.
