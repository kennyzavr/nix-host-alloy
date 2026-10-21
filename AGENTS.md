# Working on Alloy

Alloy is a Nix infrastructure framework with a separate Alloy module evaluation
layer and a Rust CLI. Start with the document relevant to the task; do not load
all documentation by default. Commands below run from this repository root.

## Find the relevant context

Agent reference documents live in `docs/agents/`.

| Task | Read |
| --- | --- |
| Understand boundaries, data flow, or locate a subsystem | [Architecture](docs/agents/architecture.md) |
| Add/change core or service modules, networking, DNS, TLS, secrets | [Nix module design](docs/agents/nix-modules.md) |
| Change CLI behavior, serialization, generators, or state loading | [CLI and state contract](docs/agents/cli-state.md) |
| Work on VM launch, console, disk images, or guest updates | [QEMU](docs/agents/qemu.md) |
| Work on runtime SSH keys, initrd files, or first installation | [SSH and boot](docs/agents/ssh-boot.md) |

Use linked source files for exact option types/defaults and schemas. Documentation
explains contracts and decisions, not an exhaustive option inventory. Keep the
relevant document current when changing a contract; do not add commit diaries.

## Development constraints

- Do not hand-edit managed files in `facts/` or `secrets/`; use the CLI. Never put
  real private keys or plaintext secrets into facts or the Nix store.
- Services compose core entities (jails, endpoints, certificates, etc.). Put
  service-specific NixOS settings inside those entities' `nixosModule` fields,
  not directly into unrelated host configuration.
- Reuse `alib.types` for existing custom types. Resolve DNS nodes with
  `alloy.dns.resolveNode`, not manual name concatenation.
- Alias the outer Alloy `config` as `alloy`. Keep it distinct from host/jail and
  NixOS submodule configurations.
- Validate cross-entity references with assertions and guard lookups with
  `builtins.hasAttr`. A raw missing-attribute exception is not a useful validation
  message. Preserve both assertion and warning propagation when composing modules.
- Expose derived entity values as read-only options with inline defaults. Reuse
  those option values; do not create helpers just to recompute them elsewhere.
- Use NixOS/per-system `pkgs`, or `withSystem system` in Alloy build callbacks.
  Never use `builtins.import <nixpkgs>`. See the callback contract in the module guide.
- Jail consumers use `config.secrets.<name>.path`, not `config.age.secrets`.
- Keep CLI presentation in `alloy-cli`, domain logic and infrastructure adapters
  in `alloy-core`. Do not introduce a third infrastructure crate.
- For CLI-facing features, update Nix `build.state` producers and Rust consumers
  together. Preserve the build-spec gates and relative script path contract.
- `disko` and `home-manager` are explicit extensions, not default Alloy modules.
  Do not silently enable them or restore removed services as part of other work.
- Format changed Nix code with `nixfmt` (the flake formatter is `nixfmt-tree`).

## Verification

Choose checks for the changed behavior; report which actually ran and their
limits. Do not use state-mutating CLI operations against personal infrastructure
as a substitute for an isolated test fixture.

- Always: `git diff --check`.
- Nix: `nix fmt <changed.nix> ...`, then targeted evaluation/build of the changed
  configuration or generated artifact. `nix build .#alloy-cli --no-link` checks the
  packaged CLI. `nix flake check --no-build` is a broader evaluation check, not a
  VM boot test; examples can require workspace facts and machine configuration.
- Rust: `nix develop path:. --command cargo fmt --all -- --check` and
  `nix develop path:. --command cargo test --workspace`. Use the flake dev shell
  for the pinned toolchain. Check actual test coverage; compilation alone does
  not establish runtime correctness.
- Shell: `bash -n modules/core/ssh-keygen.sh` for syntax, plus isolated lifecycle
  checks when changing key handling (see the SSH guide).
- VM/initrd changes: follow the QEMU and SSH guides. Evaluation, image building,
  and booting an existing disk exercise different behavior.
- Documentation-only changes: validate relative links, compare claims to source,
  and confirm no non-documentation files changed. Application builds are not
  needed just to reorganize prose.

Check which test suites actually exist before choosing commands. Do not cite
missing test scripts or describe unrun checks as passing.
