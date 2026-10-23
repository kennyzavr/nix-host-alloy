# Plan: Nix option descriptions and diagnostics

This document records the proposed scope and investigation points for a future
refactor. It is a working plan, not a record of completed changes.

## Scope

- Refine descriptions of existing Alloy options without reorganizing the option
  tree or refactoring module structure solely to add descriptions.
- Standardize Alloy assertion and warning messages, and verify that nested
  diagnostics reach the top-level evaluation result.
- Investigate how Alloy uses Nix module `_file` and `key` metadata, and whether
  generated/wrapped modules preserve useful source and identity context.
- Keep Rust `alloy-cli` and `alloy-core` diagnostics out of this phase.

Do not change option structure as part of this work. If investigation finds a
structural issue that cannot be fixed without changing the public option API,
describe it and agree on a separate change first.

## Findings to retain

### Option descriptions

The initial source scan found roughly 489 `mkOption` declarations and 46
explicit `description` attributes in the Alloy Nix modules and flake module.
The descriptions are unevenly distributed. This is an inventory signal, not a
target to add a description mechanically to every option.

Descriptions should be concise prose, not a rigid format. Prioritize public
options whose purpose, null behavior, default, reference semantics, or
interaction with another option is not clear from the name and type. Do not
duplicate type/name information or reorganize options to document them.

### Assertion and warning message policy

Use Alloy's existing `assertions` and `warnings` channels for configuration
diagnostics. A message should stand on its own and, where relevant, include:

1. The entity context (component, entity kind and name; nested route or field
   when useful).
2. The failed condition or observed problem, naming the relevant option or
   reference.
3. A concrete correction or a useful next check.

Assertions describe a condition that makes the configuration invalid. Warnings
describe a concern that does not by itself invalidate configuration; explain
the likely consequence or recommended check and avoid wording it as a hard
requirement. Keep terms, capitalization, punctuation, quoting of option paths,
and the `[Alloy]` prefix consistent. The evaluator currently adds an outer
`Alloy '<name>': Failed assertions` or `Warnings` heading, so consider that
when deciding whether individual messages need a prefix.

Known message cleanup includes inconsistent `[Alloy]` / `alloy:` prefixes,
some grammar errors, and an incorrect `smtp-relay` label in a `tls-edge`
assertion. Fix wording without changing the underlying validation unless the
behavior change is separately agreed.

### `trace` is not diagnostic context propagation

`builtins.trace` writes a debugging message to stderr when its value is forced;
it does not attach context to an Alloy assertion or warning. Due to lazy
evaluation, the point at which a trace appears depends on which value is
evaluated. Keep it out of normal user-facing validation. `traceVerbose` can be
used temporarily for developer debugging.

`builtins.addErrorContext` can add context to an evaluation exception or stack
trace when the wrapped expression fails. It does not enrich the separately
collected `{ assertion, message }` or `{ condition, message }` records. Use it
selectively for raw evaluation failures; for user configuration mistakes,
prefer guarded lookups and Alloy assertions with actionable messages.

References: [Nix built-ins: `trace` and `addErrorContext`](https://nix.dev/manual/nix/2.35/language/builtins.html),
[NixOS warnings and assertions](https://nixos.org/manual/nixos/stable/).

### Required warning propagation fix

`modules/core/tls/acme.nix`: `mkJailDnsupdate` returns its warning under
`jailConfig.warnings`, but the jail submodule's collector reads
`c.warnings or [ ]` from each returned `cfg`. The warning is therefore not
propagated. Fix this as a required part of the diagnostics work, and check the
resulting aggregation path so the jail name and certificate context survive.
The host-side ACME warning path is collected separately and should remain
working.

## `_file` and `key` investigation

This is a first-class part of the planned refactor. The question is whether
Alloy's module wrappers provide useful and correct source/identity metadata,
not whether user-facing messages can simply omit their entity context.

Nix module-system semantics to preserve:

- `_file` identifies the source/location used for option definition locations
  and module errors. It can provide context for ordinary module-system errors.
- `key` identifies a module for deduplication and `disabledModules`; it should
  be unique where distinct modules must remain distinct.
- These attributes solve different problems. Do not assume that setting
  `_file` also establishes a suitable identity, or that setting `key` gives a
  useful display location.
- The module system also has `_prefix` context for option paths and submodules,
  but modules should not assume a fixed location in the overall configuration.

Current Alloy uses to review:

- `flakeModule.nix` sets both `_file` and `key` to
  `${self.outPath}#alloyModules.${name}` on the wrapper for each registered
  Alloy module.
- `modules/core/hosts.nix`, `modules/core/jails.nix`, and
  `modules/core/qemu.nix` set synthetic `_file` values on generated NixOS
  modules. The first metadata pass now also sets each wrapper's `key` to the
  same entity path, so identity does not depend on its anonymous import
  position.
- `modules/home-manager.nix` now does the same for generated shared and
  per-user Home Manager modules.
- The custom `alib.evalModules` calls `lib.evalModules` with the Alloy default
  module and consumer modules. It does not set an explicit `prefix`.

The generic module-system probe confirmed that a repeated wrapper with an
explicit key contributes its definitions once, while its `_file` appears as the
definition origin. This was a small isolated probe, not a full host/jail/Home
Manager integration evaluation. Review the affected wrapper behavior in
representative generated configurations as part of follow-up validation.

Questions for the implementation pass:

1. Do synthetic `_file` values in generated host/jail/QEMU/Home Manager modules
   show sufficiently precise and readable locations in real option conflict
   and evaluation errors?
2. Are module `key`s stable and distinct for Alloy module wrappers, repeated
   imports, aliases, and generated modules? Is any current default key
   accidentally sensitive to import ordering, or does it intentionally allow
   deduplication?
3. Should generated modules set explicit keys, or is the module system's
   parent-derived key correct? Add explicit keys only after confirming desired
   deduplication/disable behavior; do not make them unique merely for display.
4. Do all imports that wrap user-supplied deferred modules give errors a useful
   source label, without replacing the user's actual file location with a
   misleading synthetic one?
5. Which problems are better addressed through `_file` / `key`, which through
   guarded lookups and `addErrorContext`, and which still require explicit
   entity context in assertion/warning messages?

Nix references: [Nixpkgs module-system manual](https://nixos.org/manual/nixpkgs/stable/#module-system-lib-evalModules),
[NixOS module replacement and `key`](https://nixos.org/manual/nixos/stable/#sec-replace-modules).

## Suggested implementation order

1. Inspect module graphs and representative failures for Alloy, generated
   NixOS, and Home Manager evaluations; confirm the new explicit keys preserve
   intended repeated-import and disable behavior.
2. Fix ACME jail warning propagation and verify that this diagnostic reaches
   the top-level warning list with useful context.
3. Agree on the message conventions above, including prefix and quoting style.
4. Inventory and normalize assertions/warnings by core module and service,
   preserving validation conditions unless a separate behavior change is
   approved.
5. Review option descriptions in the same module pass, prioritizing public and
   semantically non-obvious options without moving declarations.
6. Make only justified `_file` / `key` changes, then evaluate representative
   conflict, unknown-reference, warning, and generated-module cases to confirm
   source locations, deduplication, and diagnostic propagation.
7. Keep Rust CLI/core messages for a separate future effort.
