# CLI architecture and the state contract

Read this when changing commands, generators, metadata, or Nix/Rust integration.
See [architecture](architecture.md) for the complete data flow and
[Nix module design](nix-modules.md) for callback and validation conventions.

## Ownership of effects

[alloy-core](../../packages/alloy-core/src) contains domain logic, typed errors,
serialization models, and infrastructure adapters. Domain code performs effects
through the traits in [ports.rs](../../packages/alloy-core/src/domain/ports.rs) and
`ports::Ctx`; it does not render terminal output. Adapters in `infra/` implement
Nix builds/evaluation, filesystem/Git operations, age encryption, generator
execution, and QEMU/VDE process management through `System`.

[alloy-cli](../../packages/alloy-cli/src) parses commands, constructs `Ctx`, and
renders reporter events through `TermUi`. It also owns editor interaction and
error-chain presentation. Keep behavior in domain operations and presentation in
command handlers. The command registry is
[commands/mod.rs](../../packages/alloy-cli/src/commands/mod.rs); use it and subcommand
help for exact flags rather than duplicating the whole CLI here.

Wrappers created by `mkCli` set `ALLOY_FLAKE_URL`, `ALLOY_MODULE_ATTR`, and
`ALLOY_INPUT_ATTR`. An empty input attribute selects `flake.lib`; otherwise the
adapter uses the configured library attribute inside the flake. Other environment
names and defaults live in [env.rs](../../packages/alloy-core/src/domain/env.rs).
The `simpleCluster` wrapper sets the input attribute to empty because it uses
this flake's own library.

The module attribute flag is `--module-attr`; the Alloy input attribute flag is
`--alloy-input-attr`. Their wrapper environment variables remain separate.
`ALLOY_SSHOPTS` is stored in `Env::ssh_options` and can be overridden with the
global `--ssh-options` flag, before or after a subcommand. `Env::inject_to_cmd`
exports the effective value to child Alloy processes, including CLI overrides.

## State package and serialization

[build.nix](../../modules/core/build.nix) writes `state.json` and optional executable
symlinks to a derivation. Nix modules contribute `build.state` and `build.script`.
The Nix adapter builds this package from a dynamically constructed evaluation
expression, passing `NixBuildSpec` and `checkAssertions` to Alloy evaluation.

Two files define the Rust side of the contract:

- [models.rs](../../packages/alloy-core/src/domain/models.rs): deserialized state.
- [ports.rs](../../packages/alloy-core/src/domain/ports.rs): serialized build request
  (`NixBuildSpec`) and adapter interfaces.

Top-level state contains the configuration name, master age key pairs, hosts,
jails, secrets, facts, generators, indexes, deploy metadata, and optional QEMU metadata. Each
producer remains in its core module: hosts/jails contribute identity metadata,
secrets contribute encrypted-file/runtime-path references, generators contribute
execution metadata, and QEMU contributes guest/launch metadata.

[deploy.nix](../../modules/core/deploy.nix) exports `deploy.signingKeys` with
only the `privateKeySecret`, `publicKeyFact`, and `generator` names.
The hosts module exports the required `hosts.<name>.system` string. The deploy
module exports `hosts.<name>.deploy` (enable, named connections with
address/user/port, default connection, signing/trusted key names, and activation
method/password/policy). Exporting these values does not evaluate the host's
NixOS configuration or build its system closure. The deploy runner separately
builds the selected `deploy.targetToplevel`, which resolves to the host's or a
QEMU variant's NixOS system toplevel.
The state contains secret names, never decrypted key material; the
existing `secrets` map supplies encrypted file references for declared secrets.
Disabled signing generators may leave that map without the private secret.
There is no `publicKey` registry option or exported key value. The deploy command
reads and trims the public fact through `Fact::find()` / `Fact::read()` using
`publicKeyFact` and the existing `state.facts` file metadata. The domain does not
validate public key syntax; the adapter compares it with the public key derived
by Nix from the decrypted secret. Exporting deploy metadata does
not read public fact contents, allowing generator bootstrap with assertion checks
disabled. Rust accepts states without deploy metadata, but every host must have
the `system` field.

Do not assume the Rust model exhausts the JSON output. For example,
[facts.nix](../../modules/core/facts.nix) emits host-local fact paths that the current
Rust `Host` model does not consume. When adding a CLI feature, inspect both the
producer and consumer rather than relying on an old schema table.

Path distinctions that must remain intact:

- Workspace fact and encrypted-secret `file` paths resolve against the CLI
  workspace root. A deployed secret's `path` identifies its runtime location.
- Generator and QEMU `scriptPath` values are relative to the built state package;
  domain code joins them to `state_source.dir_path` before execution.
- A generator `fingerprint` is the absolute output store path of its package,
  not a digest of the generated facts or secrets.
- Index `keys` can be null when evaluation fails. Generator `scriptPath` and
  `fingerprint` can be null when omitted by the spec or unavailable on evaluation.
  Null is not proof that the entity is valid or empty.

## Build-spec gates

| Request field | Meaning |
| --- | --- |
| `generators.buildScripts = true` | Build generator scripts and emit paths/symlinks |
| `generators.calcFingerprint = true` | Evaluate package output paths as fingerprints, independently of script emission |
| `qemu.build = true` | Include QEMU/guest metadata |
| `qemu.buildScripts = null` | Metadata only, no launch scripts |
| `qemu.buildScripts = []` | Launch scripts for hosts with a selected variant |
| `qemu.buildScripts = [ ... ]` | Launch scripts restricted to the named hosts with selected variants |

Generator list/show/exec request both script building and fingerprint calculation,
so even listing generators can trigger builds. QEMU list/show/console request
metadata only; launch requests selected scripts and enables validation. Facts,
secrets, indexes, generator operations, and QEMU inspection/console currently
load state without assertion/warning checks.

## Loading, caching, and diagnostics

[state.rs](../../packages/alloy-core/src/domain/state.rs) caches the built directory
and spec in `ctx.env().state_source`. A default-spec request may reuse any cached
state; a non-default request needs an equal spec. `reset_state` clears the source.
The cache does not include `check_assertions`, so a reused state does not gain
validation merely because the caller now requests it. Deploy explicitly resets
the cache before requesting checked state, and builds its toplevel with checks.

`deploy <host>` deploys one enabled host through `--connection` or its default.
Domain orchestration is in `domain/deploy.rs`; `DeployRunner` performs a rooted
build, validates/signs with decrypted keys, copies through Nix SSH, then updates
the profile and activates in one privileged SSH session. Linux memfd carries the
private key, and decrypted buffers are zeroized. CLI presentation stays in
`commands/deploy.rs`. See [Deploy](deploy.md) for configuration, SSH options,
activation behavior, and limitations.
`deploy_host` preserves typed source errors in `DeployError` and reports every
failure through `DeployEvent::Error` before returning it. Progress and completion
are also typed events; the CLI owns their presentation. SSH options are split
with shell quoting and passed through to OpenSSH without a flag allowlist.
`Deploy::new` resolves the host, checks that deployment is enabled, selects and
stores the connection, and resolves the selected keys. Its constructor accepts
the host name and optional connection name. The identity path stays in
`DeployOptions`, while SSH options come from `ctx.env().ssh_options`.
`DeployRunner` does not accept the `Deploy` entity: copy and
activation receive the selected `DeployConnection`, identity path and raw SSH
options explicitly, with `DeployActivation` also supplied for activation.
`infra/deploy.rs` assembles SSH arguments and normalizes the address through
shared helpers for both operations. Each
`DeployKey::new` resolves a registry entry, checks that its encrypted secret exists
and resolves the public `Fact` without reading its contents. Fields of `Deploy`
and `DeployKey` are private: they are only used within `domain/deploy.rs`, so no
getters or `_priv` marker are needed. Constructor
errors retain typed sources through `CreateDeployError` and `CreateDeployKeyError`.
`deploy_host` orchestrates operations on the prepared deployment; it reads the
public facts and decrypts private secrets only after the build succeeds.
The concrete `System` methods and fallible helpers in `infra/deploy.rs` return
`DeployRunnerError`; conversion to `DynError` happens in `impl DeployRunner`.

When generator package or index-key evaluation is unavailable, targeted adapter
operations produce diagnostics for that entity with global checks disabled.
This supports bootstrapping: unrelated missing facts should not prevent creating
the data needed to make the full configuration evaluable. See
[infra/nix.rs](../../packages/alloy-core/src/infra/nix.rs) before changing this policy.

## Generator lifecycle

Each enabled generator declares a read-only `fingerprintFact` under
`generators/<name>/fingerprint`. This fact is separate from its output facts.
The Nix module uses `builtins.tryEval` for optional package metadata. CLI staleness
compares the evaluated package path with the saved fingerprint: a missing saved
fact is stale; an unavailable evaluated fingerprint is an error.

`gens exec` follows the `wants`/`after` dependency graph. Existing output files
normally cause a skip even when the package is stale. Per-command `--force-stale`
forces stale generators; per-command `--force` forces selected generators.
The existence/skip decision occurs before the later fallback to the global force
setting in `Gen::exec`; do not assume these two flags have identical scope.
Missing output files cause ordinary execution.

Only successful execution writes the fingerprint fact, honoring the effective
`add_to_git` setting. Failed or skipped execution does not update it. The executor
can reset and rebuild state after earlier generators make new facts available;
a processed-name cache prevents rerunning already handled generators in those
passes. Sources: [generators.nix](../../modules/core/generators.nix) and
[domain/gens.rs](../../packages/alloy-core/src/domain/gens.rs).

## Workspace edits and secret selection

`facts edit` and `secrets edit` require a declared entity. A file read failure can
start the editor with empty contents, allowing creation of a missing backing
file; lookup and secret decryption failures still abort. Unchanged or empty
editor contents are skipped. Read the domain operations together with
[editor.rs](../../packages/alloy-cli/src/editor.rs) when changing this behavior.

Secret-reference listing selects all hosts and jails only when neither host nor
jail names were supplied. Selecting one category does not implicitly select every
entity in the other category. Rekeying and deployment references are implemented
in [domain/secrets.rs](../../packages/alloy-core/src/domain/secrets.rs); runtime secret
delivery is explained in [Nix module design](nix-modules.md).
