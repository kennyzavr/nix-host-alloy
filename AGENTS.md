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

## Current Since 4e08d7e

Major project changes after commit `4e08d7e`:
- Flake integration moved from `parts.nix` to `flakeModule.nix`. `parts.nix` was removed.
- CLI wrappers are now declared with `flake.alloyCli.instances`; wrappers export `ALLOY_FLAKE_URL`, `ALLOY_MODULE_ATTR`, and `ALLOY_INPUT_ATTR`.
- `_internal.{state,stateScript,statePackage}` was replaced by `build.{spec,state,script,package}` in `modules/core/build.nix`.
- State loading now uses a JSON `NixBuildSpec`, not the old `full`/`base` mode string. Expensive artifacts are gated by `build.spec.generators.buildScripts` and `build.spec.qemu.{build,buildScripts}`.
- CLI module evaluation now goes through the user's flake (`flake.<moduleAttr>`) and the configured Alloy input (`flake.<inputAttr>.lib`), not separate `--module-source`, `--alloy-url`, and `--nixpkgs-url` flags.
- `modules/home-manager.nix` was added as an explicit `self.alloyModules.home-manager` extension.
- `modules/services/xhttp-proxy.nix` was removed; service modules now total 9.
- Host users changed from `hashedPasswd` to `passwd.{source,value,secret.{secret,generator}}`; user `dir` and `name` are explicit options.
- Hosts gained `stateVersion`, which is fed into `system.stateVersion` by default.
- QEMU state now records `variants` as a list of variant names and `variant = { name, scriptPath? }` for the selected variant.
- The example cluster was folded into the main flake as `examples/simple-cluster/default.nix`; its separate `flake.nix` and `flake.lock` were removed.

---

## Data Flow

```
User's flake.nix
  -> imports alloy.flakeModules.default (from flakeModule.nix)
  -> defines flake.alloyModules.<name> = { alib, lib, config, ... }: { options = ...; config = ...; }
  -> optionally defines flake.alloyCli.instances.<name> for configured CLI wrapper packages
  -> alloy.lib.evalModules evaluates all modules into a single config
  -> config.build.package { inherit system; }
     builds a derivation containing:
       - state.json          (serialized build.state)
       - bin/generators/<name>          (when build.spec.generators.buildScripts = true)
       - bin/hosts/<h>/qemu/<variant>   (when build.spec.qemu.buildScripts includes the host or is [])
  -> alloy-cli reads state.json, operates on the workspace (the Git repo)
```

Key: Nix side is purely declarative. CLI side is purely imperative. They communicate through `state.json` inside the built package.

State is built from a JSON `NixBuildSpec`:
- `generators.buildScripts = true` — include generator script symlinks and `scriptPath` values.
- `qemu.build = true` — include global QEMU options and per-host QEMU state.
- `qemu.buildScripts = null` — include QEMU metadata only; no launch script paths.
- `qemu.buildScripts = []` — build launch scripts for all selected-default QEMU guests.
- `qemu.buildScripts = [ "host-a" ... ]` — build launch scripts only for listed hosts.

---

## Project Structure

```
flake.nix                     # Inputs: nixpkgs, flake-parts, agenix, disko, home-manager. Imports flakeModule.nix, lib/, modules/, packages/, examples/simple-cluster
flakeModule.nix               # Defines flake.alloyModules and flake.alloyCli.instances options
lib/
  default.nix                 # evalModules, evalModule, mkCli, resolveZoneNode, extendZoneNode, mkArpaIpv6, types
  types.nix                   # Parallel type definitions (ageKeyPair, assertion, permissions, dns.*, ip.*, zoneNode, netMatchOpts)
modules/
  core/
    default.nix               # Imports all core modules, defines workspace + name + assertions options
    build.nix                 # build.{spec,state,script,package}; writes state.json and optional script symlinks
    hosts.nix                 # Host entity: idx, system, stateVersion, nixosModule, nixosConfiguration, tags
    jails.nix                 # Jail entity: idx, host, uplink, nixosModule, tags. Bridge networking, NAT, containers
    overlays.nix              # WireGuard mesh: links, ipv6Prefix. Babeld routing, GRE tunnels
    endpoints.nix             # Service endpoints: targets (ipv6+overlay), loadBalancing, port
    dns.nix                   # Zones, records (all BIND types), systemd-resolved + CoreDNS per-node, internalDomain, resolveNode
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
    users.nix                 # Per-host users: name, dir, isAdmin, passwd source/value/secret+generator. Immutable users
    nets.nix                  # Host network interfaces: static systemd-networkd config, primary/default net
    ssh.nix                   # SSH server config: listen on specific nets, per-user authorized keys from facts
    boot.nix                  # Boot options: initrd facts (secrets embedded into initrd via boot.initrd.secrets)
    qemu.nix                  # QEMU VM testing: nets, variants (direct-boot, full-boot), extraPreScript, forwardPorts, vde_switch
  services/
    default.nix               # Imports all 9 service modules
    ca.nix                    # Certificate Authority (step-ca + nginx)
    dns-auth.nix              # Authoritative DNS (Knot)
    dns-acme.nix              # ACME DNS challenge server (Knot + TSIG)
    dns-edge.nix              # DNS edge proxy (dnsdist)
    dns-resolver.nix          # Recursive resolver (knot-resolver)
    http-edge.nix             # HTTP reverse proxy (nginx)
    tls-edge.nix              # TCP/TLS L4 proxy (HAProxy)
    smtp-edge.nix             # SMTP relay (Postfix + rspamd + ClamAV)
    postbox.nix               # Mailbox server (Postfix + Dovecot + nginx)
  disko.nix                   # Explicit extension module: hosts.<name>.disko.{enable,settings}, adds "disko-boot" QEMU variant
  home-manager.nix            # Explicit extension module: hosts.<name>.home + users.<name>.home wrappers
  default.nix                 # Defines alloyModules.default = core + services; exports disko/home-manager as separate modules
packages/
  alloy-cli/                  # Presentation layer (Rust binary)
    src/
      main.rs                 # Entry point: parse Args, dispatch to commands::handle_args
      ctx.rs                  # Ctx struct: binds Env + System, implements domain::ports::Ctx
      term_ui.rs              # TermUi: rich terminal output (ok/skip/info/error/step/table/data)
      editor.rs               # $EDITOR integration for secret editing
      error.rs                # Error rendering: chain display with source indentation
      commands/
        mod.rs                # Args (Clap): workspace-root, state-source, flake-url, flake-attr/module attr, input attr, depth, force, add-to-git, show-nix-trace, cache-dir
        facts.rs              # alloy facts {list,get,set,edit,delete}
        gens.rs               # alloy gens {list,run}
        indexes.rs            # alloy indexes {list,show}
        secrets.rs            # alloy secrets {list,show,get,set,edit,rekey,refs}
        qemu.rs               # alloy qemu {launch,list,show}
    Cargo.toml                # deps: clap, serde, color-eyre, owo-colors, comfy-table, age, petgraph, alloy-core
  alloy-core/                 # Domain + infrastructure (Rust library)
    src/
      lib.rs                  # pub mod domain; pub mod infra;
      domain/
        mod.rs                # NameMarker, PathMarker, DynError; re-exports submodules
        env.rs                # Env struct + env var constants; EnvStateSource JSON {spec,dir_path}
        models.rs             # Serde-deserialized State, Host, Jail, Secret, Fact, Gen, Index, Qemu, QemuGuest, AgeKeyPair, ...
        ports.rs              # Traits: Ctx, Nix, Fs, Git, Age, GenRunner, QemuRunner, VdeSwitchProc, QemuGuestProc, Reporter; NixBuildSpec
        state.rs              # load_state(spec, ctx) -> State; reset_state
        facts.rs              # domain logic: list/get/set/delete facts
        gens.rs               # domain logic: list/run generators (DAG via petgraph)
        hosts.rs              # Host<'s> wrapper + FindHostError
        indexes.rs            # Index<'s> wrapper, read/write index fact file
        jails.rs              # Jail<'s> wrapper + FindJailError
        secrets.rs            # Secret, SecretRef: find/read/write/rekey; all secret domain operations
        qemu.rs               # QemuOpts, QemuGuest: find; launch_qemu_guests, list_qemu_guests, show_qemu_guest
      infra/
        mod.rs                # pub struct System {}; ExecError; pub use nix::*; pub use qemu::*
        nix.rs                # System impl Nix: trigger_assertions, build (nix build --impure --expr)
        qemu.rs               # System impl QemuRunner: launch_guest (vde socket env injection), launch_vde (vde_switch process)
        age.rs                # System impl Age: encrypt/decrypt via age crate
        fs.rs                 # System impl Fs: exists, mk_parent_dirs, read, write (force flag)
        git.rs                # System impl Git: check (is tracked), add (git add)
        gens.rs               # System impl GenRunner: exec_gen (subprocess, env injection)
    Cargo.toml                # deps: serde, petgraph, itertools, either, chrono, tempfile, thiserror, log
  default.nix                 # Nix package build for both crates (used by flake), Rust 1.98.1 via crane/rust-overlay
Cargo.toml                    # Workspace: members = [packages/alloy-cli, packages/alloy-core], edition=2024
examples/simple-cluster/
  default.nix                 # Example flake-parts module defining alloyModules.simpleCluster and nixosConfigurations
test.nix                      # Manual Nix expression that builds config.build.package for the simple cluster
```

---

## Core Entities -- Quick Reference

| Entity | Option Path | Index Range | Key Fields |
|--------|------------|-------------|------------|
| Host | `hosts.<name>` | 1-99 | `system`, `stateVersion`, `nixosModule`, `tags`, `idx` (auto) |
| Jail | `jails.<name>` | 1-999 | `host`, `nixosModule`, `tags`, `uplink.{allowEgress,forwards}` |
| Overlay | `overlays.<name>` | 1-99 | `links[].{a.host, b.host}`, `ipv6Prefix` (auto) |
| Endpoint | `endpoints.<name>` | -- | `port`, `targets[].{ipv6, overlay}`, `loadBalancing.policy` |
| DNS Zone | `dns.zones.<name>` | -- | `apex`, `parentZone`, `rname`, `ttl` |
| TLS Cert | `tls.certs.<name>` | 1-999 | `domains[]`, `ca`, `src.{acme,static}` |
| TLS CA | `tls.ca.<name>` | -- | `certFact` |
| Secret (master) | `secrets.<name>` | -- | `file`, `tags`, `exists` (readOnly) |
| Fact | `facts.<name>` | -- | `file`, `value`, `tags` |
| Generator | `generators.instances.<name>` | -- | `enable`, `package`, `wants`, `after`, `facts`, `secrets`, `tags` |
| Index | `indexes.<name>` | -- | `keys`, `minValue`, `maxValue`, `factName` |
| Volume | `jails.<name>.volumes.<name>` | -- | `path`, `driver.directory`, `permissions` |
| User | `hosts.<name>.users.<name>` | -- | `name`, `dir`, `isAdmin`, `passwd.{source,value,secret}` |
| QEMU nets | `qemu.nets.<name>` | 1-99 | `idx` (auto via `qemu-nets` index) |
| QEMU guest | `hosts.<name>.qemu` | -- | `memory`, `cores`, `graphics`, `nets`, `forwardPorts`, `extraPreScript`, `variants`, `variant`, `nixosModule` |

### Cross-module extensions

The complete option tree for a host (contributions from all modules):

```
hosts.<name>.{
  idx, system, stateVersion, nixosModule, nixosConfiguration, tags, assertions,
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
  users.<name>.{ name, dir, isAdmin, passwd.{ source, value, secret.{ secret, generator } } },
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
  qemu.{ memory, cores, graphics, nets.<name>.{mac,iface}, forwardPorts[], extraPreScript, nixosModule, variants.<name>.package, variant },
  # From disko.nix (explicit extension, not in alloyModules.default):
  disko.{ enable, settings },
  # From home-manager.nix (explicit extension, not in alloyModules.default):
  home.{ enable, sharedModule },
  users.<name>.home.{ enable, stateVersion, module },
}
```

Top-level (not per-host): `name` -- unique identifier for this Alloy configuration (required, no default). Namespaces CLI runtime state (cache dir subdirectory).

Global workspace options:
- `workspace.root` -- path to workspace root (required)
- `workspace.baseDir` -- relative base dir (default: `"."`)
- `workspace.secrets.baseDir` -- master secrets dir (default: `"./secrets/masters"`)
- `workspace.secrets.age.keyPairs` -- global age key pairs for master secrets

---

## state.json Keys (models.rs State struct)

Modules contribute to `build.state`, which becomes the JSON the CLI reads. The Rust `State` struct in `alloy-core/src/domain/models.rs` defines the deserialization schema:

| JSON key | Rust field | Contributed by | Notes |
|----------|-----------|----------------|-------|
| `name` | `State.name` | `core/default.nix` | Plain string |
| `secretsAgeKeyPairs` | `State.secrets_age_key_pairs: Vec<AgeKeyPair>` | `secrets.nix` | Global master age key pairs |
| `secrets` | `State.secrets: HashMap<String, Secret>` | `secrets.nix` | Master secrets: `{file, tags}` |
| `hosts` | `State.hosts: HashMap<String, Host>` | `hosts.nix`, `secrets.nix`, `qemu.nix` | Host records |
| `hosts.<h>.tags` | `Host.tags` | `hosts.nix` | |
| `hosts.<h>.secrets` | `Host.secrets: HashMap<String, SecretRef>` | `secrets.nix` | `{file, path}` per secret |
| `hosts.<h>.secretsAgeKeyPairs` | `Host.secrets_age_key_pairs` | `secrets.nix` | Host-specific age key pairs |
| `hosts.<h>.qemu` | `Host.qemu: Option<QemuGuest>` | `qemu.nix` | Null unless `build.spec.qemu.build = true` |
| `jails` | `State.jails: HashMap<String, Jail>` | `jails.nix`, `secrets.nix` | `{host, tags, secrets}` |
| `facts` | `State.facts: HashMap<String, Fact>` | `facts.nix` | `{file, tags}` |
| `generators` | `State.gens: HashMap<String, Gen>` | `generators.nix` | `{wants, after, tags, secrets, facts, scriptPath?}` |
| `indexes` | `State.indexes: HashMap<String, Index>` | `indexes.nix` | `{keys?, evaluated, minValue, maxValue, factName}` (`models.rs` currently consumes `keys`, `minValue`, `maxValue`, `factName`) |
| `qemu` | `State.qemu: Option<Qemu>` | `qemu.nix` | Global QEMU nets; null unless `build.spec.qemu.build = true` |

`QemuGuest` fields: `nets: HashMap<name, QemuNetRef{iface, mac}>`, `portForwards: Vec<QemuPortForward{name, proto, hypervisor, guest}>`, `variants: Vec<String>`, `variant: Option<QemuVariant{name, scriptPath?}>`.

---

## CLI Architecture (Rust, 2 crates)

The Alloy CLI is written in Rust and split into two crates:

### `alloy-core` (library)

Pure domain logic and infrastructure adapters. No terminal I/O.

- **`domain/`** — business logic, typed errors, no side effects except through `ports::Ctx`
  - `env.rs` — `Env` struct (all CLI configuration), env var name constants, `EnvStateSource` as JSON `{spec,dir_path}`
  - `models.rs` — Serde structs deserializing `state.json`
  - `ports.rs` — Traits: `Ctx`, `Nix`, `Fs`, `Git`, `Age`, `GenRunner`, `QemuRunner`, `VdeSwitchProc`, `QemuGuestProc`, `Reporter<C, T>`; `NixBuildSpec` structs
  - `state.rs` — `load_state(spec, ctx)` → `State`; `reset_state`
  - `hosts.rs`, `jails.rs`, `secrets.rs`, `facts.rs`, `gens.rs`, `indexes.rs`, `qemu.rs` — domain operations

- **`infra/`** — concrete implementations of port traits, all behind `System` struct
  - `nix.rs` — `System impl Nix`: builds eval expression from `flake_url`, `input_attr`, `module_attr`, and `NixBuildSpec`; calls `nix build --impure --expr`, `nix eval` for assertions
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
- `commands/mod.rs` — top-level `Args` (Clap): `--workspace-root`, `--state-source`, `--flake-url`, `--flake-attr`/module attr, input attr, `--depth`, `--force`, `--add-to-git`, `--cache-dir`, `--show-nix-trace`; subcommands: `Facts`, `Gens`, `Indexes`, `Secrets`, `Qemu`

**State loading**: CLI calls `load_state(spec, ctx)`, where `spec` is `NixBuildSpec`. A default spec builds ordinary metadata. Generator execution sets `generators.buildScripts = true`. QEMU list/show set `qemu.build = true` and no scripts. QEMU launch sets `qemu.build = true` and `qemu.buildScripts = Some(hosts)`. The built directory and spec are cached in `ctx.env().state_source` after first load.

**Nix eval expression** (from `infra/nix.rs`): dynamically builds a Nix expression that:
```nix
let
  system = builtins.currentSystem;
  flake = builtins.getFlake "<flake-url>";
  alloyLib = flake.<input-attr>.lib;
  alloyModule = flake.<module-attr>;
  res = alloyLib.evalModules {
    modules = [
      alloyModule
      { build.spec = builtins.fromJSON ''<serialized NixBuildSpec>''; }
    ];
    checkAssertions = <bool>;
  };
in
  <inner-expr>
```
where `<inner-expr>` is `res.config.build.package { inherit system; }` for state builds and `res.config.name` for assertion checks.

---

## `build.state` and `build.package`

Defined in `modules/core/build.nix`:

```nix
options.build = {
  spec = lib.mkOption { type = submodule {}; };
  state = lib.mkOption { type = functionTo (attrsOf anything); };
  script = lib.mkOption { type = functionTo lines; };
  package = lib.mkOption { type = functionTo package; readOnly = true; };
};

config.build.package = { system, ... }:
  let pkgs = inputs.nixpkgs.legacyPackages.${system};
  in pkgs.runCommand "alloy-${alloy.name}-state" {} ''
    mkdir -p $out/bin
    cat > $out/state.json <<'EOF'
    ${builtins.toJSON (alloy.build.state { inherit pkgs; })}
    EOF
    ${alloy.build.script { inherit pkgs; }}
  '';
```

Each module that contributes to state does so by merging into `build.state`:
```nix
config.build.state = { pkgs, ... }: { ... };
```
And optionally into `build.script` for binary artifacts (generator scripts, QEMU scripts). Use `build.spec` to avoid evaluating/building expensive artifacts unless the CLI requested them.

---

## VM / QEMU Subsystem

QEMU-based testing without root privileges. Inter-VM networking via `vde_switch` L2 bridges.

**Nix side** (`modules/core/qemu.nix`):
- `qemu.nets.<name>` — global network definitions; `idx` is auto-allocated via `qemu-nets` index (range 1-99)
- `hosts.<name>.qemu.{memory, cores, graphics, forwardPorts[], extraPreScript, nixosModule, variants, variant}`
- `hosts.<name>.qemu.nets.<name>` — per-host net attachment; `mac` and `iface` are `readOnly` computed options
  - `mac = "52:54:00:00:<hIdx>:<nIdx>"` (host idx + net idx, hex)
  - `iface = "eth<net.idx>"`
- Built-in variants (contributed by `qemu.nix` via `config.variants`):
  - `"direct-boot"` — `nixosSystem { ... }.config.system.build.vm` (NixOS qemu-vm module)
  - `"full-boot"` — same + `virtualisation.useBootLoader = true` (EFI boot)
- Optional variant (contributed by `modules/disko.nix`):
  - `"disko-boot"` — `vmWithDisko` (requires `hosts.<name>.disko.enable = true`)
- `variant = null` means no default; set to e.g. `"direct-boot"` to make it the CLI default
- `extraPreScript = { pkgs, ... }: "...";` is inserted before the selected QEMU variant executable in the generated launch wrapper
- VDE socket env: `ALLOY_VDE_SOCKET_<idx>` injected per net before launching the script
- Disk image: `$NIX_DISK_IMAGE` env var, stored at `<cache-dir>/<alloy-name>/qemu/<host-name>.qcow2`
- QEMU logs: `<cache-dir>/<alloy-name>/qemu/<host-name>_log_<timestamp>.log`

**CLI side** (`alloy qemu`):
- `qemu launch [hosts...] [--tags ...]` — builds QEMU state plus launch scripts for selected hosts, creates VDE switches for referenced nets, launches QEMU guest processes, waits for all to exit
- `qemu list [--tags ...]` — lists configured QEMU guests
- `qemu show <host>` — shows QEMU config for a specific host
- VDE switch socket lives in a `TempDir` (auto-cleaned when `VdeSwitchProc` is dropped)
- VM runtime: cache dir at `<workspace-root>/.alloy/<alloy-name>/qemu/`

**`disko.nix`** (`modules/disko.nix`):
- Explicit extension module, NOT included in `alloyModules.default`; user imports `self.alloyModules.disko` separately
- Extends `hosts.<name>` with `disko.{enable, settings}` options
- When `enable = true`: merges disko NixOS module into `host.nixosModule` and registers `"disko-boot"` variant

**`home-manager.nix`** (`modules/home-manager.nix`):
- Explicit extension module, NOT included in `alloyModules.default`; user imports `self.alloyModules.home-manager` separately
- Extends hosts with `home.{enable,sharedModule}` and users with `home.{enable,stateVersion,module}`
- When `hosts.<name>.home.enable = true`: imports `inputs.home-manager.nixosModules.home-manager` into the host NixOS module and wires enabled users into `home-manager.users`

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

**`build.state` merge semantics**: each module uses `config.build.state = { pkgs, ... }: { ... };`. Because `state` is `functionTo (attrsOf anything)`, multiple modules' contributions are deep-merged via `lib.mkMerge` (applied to the function results). Use `build.spec` checks inside the function body to gate expensive/full content.

**`build.script` for artifacts**: generator and QEMU launch script symlinks are emitted from `config.build.script = { pkgs, ... }: "...";`. Keep build-time paths relative to `$out` in `state.json` and join them with `state_source.dir_path` on the CLI side.

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
9. **`build.state` is the bridge** from Nix to CLI -- add keys here for new CLI features; update `models.rs` correspondingly
10. **Formatter: `nixfmt`** (nixfmt-tree). All Nix code must be formatted.
11. **`config` is aliased as `alloy`** in module let-bindings for readability
12. **CLI crates**: 2 crates only -- `alloy-cli` (presentation) and `alloy-core` (domain + infra). There is no separate `alloy-infra` crate; infra code lives in `alloy-core::infra`.
13. **`disko.nix`** is an explicit extension at `modules/disko.nix`, NOT part of `alloyModules.default`. Users must explicitly import `self.alloyModules.disko` to use it.
14. **`home-manager.nix`** is an explicit extension at `modules/home-manager.nix`, NOT part of `alloyModules.default`. Users must explicitly import `self.alloyModules.home-manager` to use it.
15. **Do not resurrect `xhttp-proxy`** unless intentionally reintroducing the service; it was removed from `modules/services/default.nix`.
