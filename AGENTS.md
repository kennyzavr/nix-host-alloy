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

## Snapshot Through 435f25c

Reviewed through `435f25c`, covering changes since the previous AGENTS.md update at `ab45dec`:

- Core build callbacks, generator packages, and QEMU launch hooks now receive `{ system, ... }` instead of `{ pkgs, ... }`. Resolve packages through flake-parts `withSystem` where needed.
- Generators expose `fingerprintFact`; state adds `fingerprintFact` and optional `fingerprint`, gated by `build.spec.generators.calcFingerprint`. `gens list/show` report staleness; `gens exec --force-stale` reruns stale generators.
- `load_state` takes `check_assertions`. QEMU launch enables checks; current facts, secrets, indexes, generators, and QEMU list/show operations disable them. Index/generator failures request targeted Nix diagnostics instead of triggering all assertions.
- Global, host, and jail `warnings` use `alib.types.warning`; `evalModules` reports failed conditions when `checkAssertions` is enabled. `mkEndpointOverlaysWarn` replaces `checkEndpointOverlays`.
- ACME was reorganized into host/jail DNS-update builders. `src.acme.acceptTerms` defaults to false; order/renew delay is now `host.idx * 10` seconds.
- HTTP edge strips the DNS trailing dot from nginx `serverName` and adds a default TLS rejection vhost. TLS edge always terminates downstream TLS; its former `downstream.tls.enable` option was removed.
- `postbox` was removed; 8 service modules remain. `test.nix` was also removed.
- Host secret template setup now uses `alloy-secrets-and-templates-setup.service`, matching the jail setup service name.
- `facts edit` and `secrets edit` can start with empty content when a declared entity's file cannot be read, including when it does not yet exist.
- The simple cluster declares host state versions, accepts ACME terms, and exports `simpleCluster-alloy-cli` with `alloyInputAttr = ""` (use this flake's own library).
- The repository now includes an MIT `LICENSE`.

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
- `generators.calcFingerprint = true` — include each evaluable generator package's output store path as `fingerprint`; this flag is independent of whether `scriptPath` and script symlinks are emitted.
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
  default.nix                 # evalModules (assertions + warnings), evalModule, mkCli, resolveZoneNode, extendZoneNode, mkArpaIpv6, types (all declared here)
modules/
  core/
    default.nix               # Imports all core modules, defines workspace + name + assertions + warnings options
    build.nix                 # build.{spec,state,script,package}; writes state.json and optional script symlinks
    hosts.nix                 # Host entity: idx, system, stateVersion, nixosModule, nixosConfiguration, tags
    jails.nix                 # Jail entity: idx, host, uplink, nixosModule, tags. Bridge networking, NAT, containers
    overlays.nix              # WireGuard mesh: links, ipv6Prefix. Babeld routing, GRE tunnels
    endpoints.nix             # Service endpoints: targets (ip.v4/ip.v6 + optional overlay), loadBalancing, port
    dns.nix                   # Zones, records (all BIND types), systemd-resolved + CoreDNS per-node, internalDomain, resolveNode
    tls/
      default.nix             # Cert/CA options, cert lifecycle (wait/reload services), indexes
      acme.nix                # ACME source: acceptTerms, host-side DNS-01 via dnsupdate, jail cert bind-mounts
      static.nix              # Static cert source (fact + secret references)
      generators.nix          # x509 CA + leaf cert generators (Python/cryptography, ECDSA P-256)
    secrets.nix               # 3-tier: master (global), host (agenix rekeyed), jail (bind-mounted). Secret templates with placeholder substitution
    facts.nix                 # Plain-text versioned data in workspace
    generators.nix            # Script orchestration: templates, instances, fingerprint facts, conditional script/fingerprint state
    indexes.nix               # Unique integer allocation backed by fact files. Range-checked, gap-filled
    mtls.nix                  # Auto mTLS: root CA + per-node leaf certs. SAN from overlays/endpoints/domains
    volumes.nix               # Persistent jail storage: directory driver, bind-mounts, tmpfiles permissions
    users.nix                 # Per-host users: name, dir, isAdmin, passwd source/value/secret+generator. Immutable users
    nets.nix                  # Host network interfaces: static systemd-networkd config, primary/default net
    ssh.nix                   # SSH server config: listen on specific nets, per-user authorized keys from facts
    boot.nix                  # Boot options: initrd facts (secrets embedded into initrd via boot.initrd.secrets)
    qemu.nix                  # QEMU VM testing: nets, variants (direct-boot, full-boot), extraPreScript, forwardPorts, vde_switch
  services/
    default.nix               # Imports all 8 service modules
    ca.nix                    # Certificate Authority (step-ca + nginx)
    dns-auth.nix              # Authoritative DNS (Knot)
    dns-acme.nix              # ACME DNS challenge server (Knot + TSIG)
    dns-edge.nix              # DNS edge proxy (dnsdist)
    dns-resolver.nix          # Recursive resolver (knot-resolver)
    http-edge.nix             # HTTP reverse proxy (nginx)
    tls-edge.nix              # TLS-terminating L4 proxy (HAProxy); downstream cert required per route
    smtp-edge.nix             # SMTP relay (Postfix + rspamd + ClamAV)
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
        facts.rs              # alloy facts {list,show,get,set,edit}
        gens.rs               # alloy gens {list,show,exec}; IsStale output, --force-stale
        indexes.rs            # alloy indexes {list,show,get,alloc}
        secrets.rs            # alloy secrets {list,show,get,set,edit,rekey}
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
        state.rs              # load_state(spec, check_assertions, ctx) -> State; reset_state
        facts.rs              # domain logic: list/show/get/set facts
        gens.rs               # domain logic: list/show/exec generators, is_stale, fingerprint writes, DAG via petgraph
        hosts.rs              # Host<'s> wrapper + FindHostError
        indexes.rs            # Index<'s> wrapper, read/write index fact file
        jails.rs              # Jail<'s> wrapper + FindJailError
        secrets.rs            # Secret, SecretRef: find/read/write/rekey; all secret domain operations
        qemu.rs               # QemuOpts, QemuGuest: find; launch_qemu_guests, list_qemu_guests, show_qemu_guest
      infra/
        mod.rs                # pub struct System {}; ExecError; pub use nix::*; pub use qemu::*
        nix.rs                # System impl Nix: build, eval_index_keys, build_gen_package (targeted diagnostics)
        qemu.rs               # System impl QemuRunner: launch_guest (vde socket env injection), create_vde (vde_switch process)
        age.rs                # System impl Age: encrypt/decrypt via age crate
        fs.rs                 # System impl Fs: exists, mk_parent_dirs, read, write (force flag)
        git.rs                # System impl Git: check (is tracked), add (git add)
        gens.rs               # System impl GenRunner: exec_gen (subprocess, env injection)
    Cargo.toml                # deps: serde, petgraph, itertools, either, chrono, tempfile, thiserror, log
  default.nix                 # Nix package build for both crates (used by flake), Rust 1.98.1 via crane/rust-overlay
Cargo.toml                    # Workspace: members = [packages/alloy-cli, packages/alloy-core], edition=2024
examples/simple-cluster/
  default.nix                 # Defines alloyModules.simpleCluster, nixosConfigurations, and simpleCluster-alloy-cli wrapper
LICENSE                       # MIT license
```

---

## Core Entities -- Quick Reference

| Entity | Option Path | Index Range | Key Fields |
|--------|------------|-------------|------------|
| Host | `hosts.<name>` | 1-99 | `system`, `stateVersion`, `nixosModule`, `tags`, `idx` (auto) |
| Jail | `jails.<name>` | 1-999 | `host`, `nixosModule`, `tags`, `uplink.{allowEgress,forwards}` |
| Overlay | `overlays.<name>` | 1-99 | `links[].{a.host, b.host}`, `ipv6Prefix` (auto) |
| Endpoint | `endpoints.<name>` | -- | `port`, `targets[].{ip, overlay}`, `loadBalancing.policy` (`ip = { v4 = ...; }` or `{ v6 = ...; }`; `overlay` defaults to null) |
| DNS Zone | `dns.zones.<name>` | -- | `apex`, `parentZone`, `rname`, `ttl` |
| TLS Cert | `tls.certs.<name>` | 1-999 | `domains[]`, `ca`, `src.{acme,static}`; ACME includes `acceptTerms`, `email`, `challenge.dns.dnsupdate` |
| TLS CA | `tls.ca.<name>` | -- | `certFact` |
| Secret (master) | `secrets.<name>` | -- | `file`, `tags`, `exists` (readOnly) |
| Fact | `facts.<name>` | -- | `file`, `value`, `tags` |
| Generator | `generators.instances.<name>` | -- | `enable`, `package`, `wants`, `after`, `facts`, `secrets`, `tags`, `fingerprintFact` (readOnly) |
| Index | `indexes.<name>` | -- | `keys`, `minValue`, `maxValue`, `factName` |
| Volume | `jails.<name>.volumes.<name>` | -- | `path`, `driver.directory`, `permissions` |
| User | `hosts.<name>.users.<name>` | -- | `name`, `dir`, `isAdmin`, `passwd.{source,value,secret}` |
| QEMU nets | `qemu.nets.<name>` | 1-99 | `idx` (auto via `qemu-nets` index) |
| QEMU guest | `hosts.<name>.qemu` | -- | `memory`, `cores`, `graphics`, `nets`, `forwardPorts`, `extraPreScript`, `variants`, `variant`, `nixosModule` |

### Cross-module extensions

The complete option tree for a host (contributions from all modules):

```
hosts.<name>.{
  idx, system, stateVersion, nixosModule, nixosConfiguration, tags, assertions, warnings,
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

Both `hosts.<name>` and `jails.<name>` expose `assertions` and `warnings`; core modules aggregate these into the global lists. See the validation contract below.

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
| `generators` | `State.gens: HashMap<String, Gen>` | `generators.nix` | `{wants, after, tags, secrets, facts, scriptPath?, fingerprintFact, fingerprint?}`; nullable fields depend on build spec and package evaluation |
| `indexes` | `State.indexes: HashMap<String, Index>` | `indexes.nix` | `{keys?, minValue, maxValue, factName}`; `keys = null` when evaluation fails; no `evaluated` flag |
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
  - `state.rs` — `load_state(spec, check_assertions, ctx)` → `State`; `reset_state`
  - `hosts.rs`, `jails.rs`, `secrets.rs`, `facts.rs`, `gens.rs`, `indexes.rs`, `qemu.rs` — domain operations

- **`infra/`** — concrete implementations of port traits, all behind `System` struct
  - `nix.rs` — `System impl Nix`: builds eval expression from `flake_url`, `input_attr`, `module_attr`, optional `NixBuildSpec`, and `check_assertions`; state builds use `nix build --impure --expr`; `eval_index_keys` / `build_gen_package` expose individual index/generator errors
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

**State loading**: CLI calls `load_state(spec, check_assertions, ctx)`, where `spec` is `NixBuildSpec`. A default spec builds ordinary metadata. Generator list/show/exec all set `generators.{buildScripts,calcFingerprint} = true`. QEMU list/show set `qemu.build = true` and no scripts. QEMU launch sets `qemu.build = true` and `qemu.buildScripts = Some(hosts)`. Only QEMU launch currently requests assertion/warning checks; other domain operations pass false.

The built directory and spec are cached in `ctx.env().state_source`. A default-spec request can reuse any cached state; a non-default request requires the same spec. The cache does not track `check_assertions`, so reusing state does not rerun validation. `reset_state` clears the cached source.

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
where `<inner-expr>` is `res.config.build.package { inherit system; }` for state builds. When `input_attr` is empty, use `flake.lib` instead of `flake.<input-attr>.lib`. Targeted diagnostics omit the spec override and disable checks: `res.config.indexes."<name>".keys` for `eval_index_keys`, `res.config.generators.instances."<name>".package { inherit system; }` for `build_gen_package`. The old `trigger_assertions` port no longer exists.

**Editing missing files**: `facts edit` and `secrets edit` still require a declared entity, but start the editor with empty content on `Read*Error::FsRead` (including a missing file). Lookup and secret decryption errors still abort. Saving nonempty content writes through the domain operation; unchanged or empty editor output is skipped.

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
  let pkgs = withSystem system ({ pkgs, ... }: pkgs);
  in pkgs.runCommand "alloy-${alloy.name}-state" {} ''
    mkdir -p $out/bin
    cat > $out/state.json <<'EOF'
    ${builtins.toJSON (alloy.build.state { inherit system; })}
    EOF
    ${alloy.build.script { inherit system; }}
  '';
```

Each module that contributes to state does so by merging into `build.state`:
```nix
config.build.state = { system, ... }: { ... };
```
And optionally into `build.script` for binary artifacts (generator scripts, QEMU scripts). Use `build.spec` to avoid evaluating/building expensive artifacts unless the CLI requested them.

Core `build.state`, `build.script`, generator `package`, QEMU `extraPreScript`, and QEMU variant `package` callbacks are invoked with `{ inherit system; }`. Capture `withSystem` in the enclosing flake-parts module to obtain `pkgs`:

```nix
{ withSystem, ... }: {
  flake.alloyModules.core = { ... }: {
    generators.instances.example.package = { system, ... }:
      withSystem system ({ pkgs, ... }:
        pkgs.writeShellScriptBin "example" "echo example");
  };
}
```

This does not change NixOS module arguments or `alloyCli.instances.<name>.runtimeInputs { inherit pkgs; }`. The disko extension's `settings` also still receives `pkgs`; its current `disko-boot` package callback still declares a required `pkgs` argument despite the core caller passing `system`, so that extension has not fully adopted the new callback contract.

---

## Generator Fingerprints and Execution

- Every enabled generator registers a readOnly `fingerprintFact = "generators/${name}/fingerprint"` and declares that fact automatically. It is separate from the generator's declared output `facts`.
- With `build.spec.generators.calcFingerprint = true`, `fingerprint` is `generator.package { inherit system; }.outPath`, a store path string, not a content digest of generated facts/secrets. `builtins.tryEval` leaves it null if package evaluation fails. `scriptPath` is similarly nullable and gated by `buildScripts`.
- `Gen::is_stale` compares the current fingerprint with the saved fingerprint fact. A missing fingerprint fact file means stale; a missing evaluated fingerprint is an error.
- `gens list` and `gens show <generator>` display `IsStale`. They request both script builds and fingerprints, so these inspection commands can build generator packages.
- `gens exec [generators...] [--tag ...]` follows the `wants`/`after` DAG. Without a per-command force, a generator is skipped when all its declared output files exist, even if it is stale. `--force-stale` (`-s`) forces stale generators; `--force` (`-f`) forces all selected generators. Missing outputs still cause ordinary execution.
- After a successful script run, the CLI overwrites the fingerprint fact with the current fingerprint and honors the effective `add_to_git` setting. Skipped or failed runs do not update it.
- Missing evaluated scripts trigger `Nix::build_gen_package` for focused diagnostics. During execution, state can be reset and rebuilt after earlier generators make previously unavailable scripts evaluable; processed generator names are cached across passes.

---

## Assertions, Warnings, and Overlay Checks

- `assertions` uses `alib.types.assertion = { assertion = <bool>; message = <str>; }`.
- `warnings` uses `alib.types.warning = { condition = <bool>; message = <str>; }`. A false condition is reported; true is silent. Hosts and jails contribute their lists to the global lists.
- `alib.evalModules` defaults `checkAssertions` to true. It throws on failed assertions; otherwise, it emits failed warnings with `builtins.warn` and returns the result. Both messages include the Alloy configuration name. `checkAssertions = false` skips both checks.
- `alloy.mkEndpointOverlaysWarn endpointName allowedOverlays contextMsg` returns a warning record; add it to `warnings`. The former `checkEndpointOverlays` option was removed. DNS/HTTP/SMTP/TLS edge modules use the new helper for route upstreams.
- Edge `allowedOverlays` remains nullable. A null value derives the actual jail overlays from upstream endpoint overlays; an explicit list supplies them directly. Do not expect reading `allowedOverlays` to produce an inferred list through an option `apply` function anymore.
- Endpoint overlay maps now exclude targets whose `overlay = null`, allowing targets with direct IP addresses.

Current helper caveat: `mkEndpointOverlaysWarn` computes `condition = allowedOverlays != null -> invalidTargets != [ ]`. Combined with the evaluator's false-condition convention, this currently reports an explicit allowed list with no invalid targets and stays silent when invalid targets exist. Check the actual predicate when working on these diagnostics.

---

## ACME Certificate Lifecycle

- `tls.certs.<name>.src.acme` exposes `acceptTerms` (default false), `email` (default empty), and `challenge.dns.dnsupdate.{server,tsigKey.{alg,name,secret,generator}}`. Set `acceptTerms = true` for certificates that should accept the CA terms; it feeds host-wide `security.acme.acceptTerms`.
- `mkHostDnsupdate` and `mkJailDnsupdate` build the host-side ACME configuration. DNS-update credentials use a host secret template at `tls/certs/${certName}/acme/dnsupdate/creds`; TSIG secret permissions are `acme:acme` / `0640`, template permissions `acme:acme` / `0400`.
- The host runs `acme-order-renew-tls-acme-${certName}` with a pre-start delay of `host.idx * 10` seconds. DNS-update propagation timeout and TTL are both 5 seconds.
- Host certificates live in `/var/lib/acme/tls-acme-${certName}`. Jail certificates are obtained on the host and mounted read-only at `/var/lib/alloy/certs/${certName}`. Local `certPath`, `keyPath`, and `fullPath` point to `fullchain.pem`, `key.pem`, and `full.pem` there.
- CA endpoint overlay checks now produce warning records instead of the former ACME overlay assertions. The jail builder returns them under `jailConfig.warnings`, but the current jail collector reads top-level `c.warnings`, so those jail warnings are not propagated.

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
- `extraPreScript = { system, ... }: "...";` is inserted before the selected QEMU variant executable in the generated launch wrapper; resolve `pkgs` through `withSystem` if needed
- VDE socket env: `ALLOY_VDE_SOCKET_<idx>` injected per net before launching the script
- Disk image: `$NIX_DISK_IMAGE` env var, stored at `<cache-dir>/<alloy-name>/qemu/<host-name>.qcow2`
- QEMU logs: `<cache-dir>/<alloy-name>/qemu/<host-name>_log_<timestamp>.log`

**CLI side** (`alloy qemu`):
- `qemu launch [hosts...] [--tag ...]` — builds QEMU state plus launch scripts for selected hosts with validation enabled, creates VDE switches for referenced nets, launches QEMU guest processes, waits for all to exit
- `qemu list [--tag ...]` — lists configured QEMU guests
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

The default service set is `ca`, `dns-auth`, `dns-acme`, `dns-edge`, `dns-resolver`, `http-edge`, `smtp-edge`, and `tls-edge`. `postbox` and `xhttp-proxy` are absent.

HTTP edge resolves route domains via `alloy.dns.resolveNode` and removes the trailing dot for nginx `serverName`. Its `reject-unknown` default vhost listens on IPv4/IPv6 port 443 with `rejectSSL = true` and `return 444`.

TLS edge requires a valid `routes.<name>.downstream.tls.cert` reference on every route and always binds with `ssl crt`. There is no `downstream.tls.enable` switch or plaintext downstream mode in this module.

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
      # Can also produce: warnings, dns.records, facts, secrets, generators.instances, tls.certs
    };
  in {
    options.services."my-service" = lib.mkOption { type = lib.types.attrsOf (lib.types.submodule serviceSubmodule); };
    config = let
      services = lib.pipe alloy.services."my-service" [ (lib.filterAttrs (_: s: s.enable)) (lib.mapAttrsToList mkService) ];
    in {
      jails = lib.mkMerge (map (s: s.jails or {}) services);
      endpoints = lib.mkMerge (map (s: s.endpoints or {}) services);
      assertions = lib.mkMerge (map (s: s.assertions or []) services);
      warnings = lib.mkMerge (map (s: s.warnings or []) services);
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

**`build.state` merge semantics**: each module uses `config.build.state = { system, ... }: { ... };`. Because `state` is `functionTo (attrsOf anything)`, multiple modules' contributions are deep-merged via `lib.mkMerge` (applied to the function results). Use `build.spec` checks inside the function body to gate expensive/full content.

**`build.script` for artifacts**: generator and QEMU launch script symlinks are emitted from `config.build.script = { system, ... }: "...";`. Keep `scriptPath` values relative to `$out` in `state.json` and join them with `state_source.dir_path` on the CLI side. Generator `fingerprint` deliberately stores an absolute package output path.

---

## Strict Rules

1. **NEVER modify files in `facts/`, `secrets/`** -- managed by CLI
2. **Services MUST produce core entities** (jails, endpoints, etc.), never raw NixOS config
3. **Use `alloy.dns.resolveNode`** for domain resolution, never manual concatenation
4. **Use `alib.types`** for custom types, never redefine
5. **NEVER `builtins.import <nixpkgs>`** -- use NixOS/per-system `pkgs`, or resolve it with `withSystem system ({ pkgs, ... }: pkgs)` in Alloy build/generator hooks that receive `system`
6. **Jail secrets use `config.secrets.<name>.path`**, never `config.age.secrets`
7. **ALWAYS define assertions** for cross-entity references
8. **ALWAYS check entity existence** with `builtins.hasAttr` before referencing
9. **`build.state` is the bridge** from Nix to CLI -- add keys here for new CLI features; update `models.rs` correspondingly
10. **Formatter: `nixfmt`** (nixfmt-tree). All Nix code must be formatted.
11. **`config` is aliased as `alloy`** in module let-bindings for readability
12. **CLI crates**: 2 crates only -- `alloy-cli` (presentation) and `alloy-core` (domain + infra). There is no separate `alloy-infra` crate; infra code lives in `alloy-core::infra`.
13. **`disko.nix`** is an explicit extension at `modules/disko.nix`, NOT part of `alloyModules.default`. Users must explicitly import `self.alloyModules.disko` to use it.
14. **`home-manager.nix`** is an explicit extension at `modules/home-manager.nix`, NOT part of `alloyModules.default`. Users must explicitly import `self.alloyModules.home-manager` to use it.
15. **Do not resurrect `xhttp-proxy` or `postbox`** unless intentionally reintroducing the service; both were removed from `modules/services/default.nix`.
