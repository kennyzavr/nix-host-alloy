# Nix module design and runtime relationships

Read this when extending Alloy options or composing services. For the overall
flow see [architecture](architecture.md); for serialization see
[CLI and state](cli-state.md).

## Evaluation and composition

Alloy modules receive `alib`, `lib`, and their own `config`. Hosts and jails are
extensible submodules: core modules contribute options and deferred NixOS modules
to the same entities. This allows a service to declare a jail, attach endpoints,
request secrets/certificates, and let core modules handle their deployment.

Follow an existing service such as [dns-auth.nix](../../modules/services/dns-auth.nix):
filter enabled instances, expand each into core entities, then merge every
produced category. Register new modules in
[services/default.nix](../../modules/services/default.nix). Do not forget diagnostics
when a builder returns nested host/jail results.

Derived values belong to read-only options with inline defaults: consumers can
read one evaluated value instead of importing a duplicate computation. Helpers
are appropriate for transformations used with different inputs, not for
recomputing one entity's address or path.

Avoid a recursive dependency between an enclosing `config`, a submodule's type,
and a `mkIf` that gates writes to that same submodule. Prefer declarations free
of that dependency, unconditional assignments in the enclosing module, and
conditions on leaf values. A whole-attrset `mkIf` can force the condition while
Nix is still determining the option structure.

## Callback and build contracts

Alloy `build.state`, `build.script`, `build.package`, generator `package`, QEMU
`extraPreScript`, and variant `package` callbacks are called with `{ system, ... }`.
Resolve packages through the flake-parts `withSystem` argument:

```nix
{ withSystem, ... }: {
  flake.alloyModules.core = { ... }: {
    generators.instances.example.package = { system, ... }:
      withSystem system ({ pkgs, ... }:
        pkgs.writeShellScriptBin "example" "echo example");
  };
}
```

NixOS modules still receive `pkgs` normally. CLI wrapper `runtimeInputs` and disko
`settings` also receive `pkgs`; they are different interfaces. The existing
`disko-boot` callback mismatch is documented in [QEMU](qemu.md).

`build.state` is a `functionTo (attrsOf anything)` option: contributions are merged
when the functions are applied. `build.script` similarly merges script text.
Preserve build-spec gating so metadata operations do not unnecessarily force
full systems or generator packages. Exact flags and path semantics belong to
[CLI and state](cli-state.md).

## Assertions and warnings

[lib/default.nix](../../lib/default.nix) defines:

- `alib.types.assertion`: `{ assertion = <bool>; message = <str>; }`.
- `alib.types.warning`: `{ condition = <bool>; message = <str>; }`.

False assertions fail evaluation; false warning conditions emit warnings.
Hosts and jails aggregate their diagnostics into the global lists.
`evalModules` defaults `checkAssertions` to true; setting it false skips both
assertions and warnings. CLI operations intentionally differ in validation policy
(see the state guide). A successful unchecked metadata read is not validation.

`alloy.mkEndpointOverlaysWarn endpointName allowedOverlays contextMsg` checks
non-null overlay references against an explicit allowed set. With a null set,
this check is silent. The predicate is now `invalidTargets == [ ]`, so valid sets
are silent and invalid references warn. Direct-IP targets (`overlay = null`) are
excluded from overlay maps/checks. Edge services infer their jail overlay set
when `allowedOverlays = null`; the option value itself remains null.

ACME DNS-update reachability warnings for jail certificates are collected from
`jailConfig.warnings` and propagated through the jail's global warning list.

## Network addresses and DNS

[nets.nix](../../modules/core/nets.nix) separates address acquisition from publication:
IPv4 supports `mode.static` or `mode.dhcp`; IPv6 supports `mode.static` or
`mode.auto`. `managed` controls generated systemd-networkd interface entries in
both the main system and initrd. The module enables networkd and disables the
NixOS global DHCP default.

`advertiseAddress` is used for published service DNS addresses; binding and
forwarding use local static addresses. Its default reads `mode.static.address`,
so dynamic-address configurations need an explicit advertised address if a
consumer demands it. Several service forwarding paths and SSH listeners tied to
a named net still read static addresses; dynamic acquisition does not imply all
consumers support dynamic binding. SSH `listen[].net = null` provides a listener
without a named interface address (the nullable option has no implicit default).

A host can omit a primary network if no consumer needs it. **`primaryNet` is not
nullable**: its implementation still takes the head of the primary network list,
so evaluating it with no primary network fails. The current assertions enforce
at most one default network, not exactly one primary network.

[dns.nix](../../modules/core/dns.nix) owns zone resolution and the internal CoreDNS /
systemd-resolved integration. `dns.zones.<name>.nameservers` contains
`alib.types.serverEndpoint` values (literal addresses or Alloy endpoint
references), not bare strings. CoreDNS forwards declared zones to these upstreams;
systemd-resolved routes those zones and the internal domain through local CoreDNS.
[dns-auth](../../modules/services/dns-auth.nix) and
[dns-acme](../../modules/services/dns-acme.nix) contribute their endpoints as zone
nameservers. This is separate from public delegation records managed by DNS edge.

## Deployment configuration

[deploy.nix](../../modules/core/deploy.nix) defines `deploy.signingKeys` and
`hosts.<name>.deploy`. It provides the Nix API, target public-key trust,
signing-key generator, and CLI metadata in `build.state`. The single-host deploy
CLI, runner, activation policies, and limitations are documented in
[Deploy](deploy.md). Automatic rollback and multi-host ordering are not
implemented.

Each registry entry names a `privateKeySecret`, `publicKeyFact`, and `generator`.
For key `builder-1` these default to `deploy/signing-keys/builder-1/private`,
`deploy/signing-keys/builder-1/public`, and `deploy/signing-keys/builder-1`. The key registry name
also becomes the Nix signing key name. Use a new registry name when rotating keys.
The automatically created generator instance imports the `deploy/signing-key`
template. It generates an Ed25519 key with `nix key generate-secret` at execution
time and writes the private key through `ALLOY_BIN secrets set` and the public
key through `ALLOY_BIN facts set`. Plaintext private keys are never embedded in
Nix evaluation or store artifacts.

All three references are non-null strings. To retain trust without storing a
private key locally, disable `generators.instances.<generator>.enable` and keep
the public fact. The private secret is declared only by the enabled generator;
the public fact is always declared by the registry. Evaluation and state export
do not read the private secret. Deploy reports a missing secret when attempting
to sign. The registry does not attach master secrets to hosts or grant global
trust.

Enabled deployment hosts select `signingKeys`; `trustedSigningKeys` defaults to
that list and may additionally retain older keys. Public keys are added through
`nix.settings.extra-trusted-public-keys` without changing `trusted-users`,
signature requirements, or SSH server configuration. Public key contents are
read directly from the fact for host trust; there is no separate `publicKey`
option. State exports only reference names, and the CLI reads the public fact
through the existing fact API.

Connections contain an SSH address/alias and optional user and port. Client-side
authentication belongs to the machine running deployment. The CLI accepts `-i`
for an identity file and `ALLOY_SSHOPTS` for additional SSH flags. No identity
file, agent policy, or extra SSH flags
are stored in the Alloy connection configuration. OpenSSH configuration remains
available for local authentication settings.

A sole connection becomes the default automatically; multiple connections need
an explicit `defaultConnection`. Enabled hosts validate connection and registry
references through Alloy assertions. Activation settings distinguish `sudo`
(interactive password by default) from `direct` (already privileged session),
and `strict` from `warn` handling of a non-zero activation result. The Nix module
exports settings; the Rust runner performs activation.

An example inside an Alloy module:

```nix
deploy.signingKeys."builder-1" = { };
hosts.server.deploy = {
  enable = true;
  signingKeys = [ "builder-1" ];
  connections.public = {
    address = "server.example.org";
    user = "admin";
  };
};
```

The remaining multi-host deployment plan is tracked in [TODO](../../TODO.md).

## Facts, secrets, indexes, and accounts

Facts are plaintext workspace data, including index allocations and generator
fingerprints. A fact can be exposed on a host or jail through its local `.path`;
the implementation uses store-backed `/etc` content and tmpfiles links. File
permissions do not make a fact secret. Keep private data in the secret pipeline
or generate it locally as described in [SSH and boot](ssh-boot.md).

[secrets.nix](../../modules/core/secrets.nix) separates master encrypted secrets,
rekeyed deployment copies, and runtime paths. Host agenix processing decrypts
host/jail material; jail consumers receive bind-mounted files. Templates use
placeholders and are materialized by `alloy-secrets-and-templates-setup.service`
on hosts and jails. Consumers must use the entity's exported `.path`, not agenix
implementation paths. CLI selection/rekey behavior is in [CLI and state](cli-state.md).

[indexes.nix](../../modules/core/indexes.nix) declares stable numeric allocations
backed by facts; CLI allocation fills gaps within the declared range. Read each
index's `minValue`/`maxValue` rather than duplicating ranges in a new module.
[users.nix](../../modules/core/users.nix) defines immutable users and password sources;
[volumes.nix](../../modules/core/volumes.nix) owns persistent jail storage and mounts.

## Certificates and service behavior

[tls/default.nix](../../modules/core/tls/default.nix) provides certificate paths and
wait/reload/restart lifecycle hooks. Static sources use fact/secret references;
[tls/generators.nix](../../modules/core/tls/generators.nix) supplies CA/leaf generation.
[mtls.nix](../../modules/core/mtls.nix) composes CA and per-node certificates with SANs
from infrastructure identities.

ACME issuance runs on the host, including certificates consumed by jails.
DNS-update credentials are host secret templates: the TSIG secret uses
`acme:acme` / `0640`, the credential template `acme:acme` / `0400`.
`src.acme.acceptTerms` defaults false and feeds host-wide ACME acceptance; explicitly
opt in when appropriate. Order/renew services stagger by `host.idx * 20` seconds;
DNS-update propagation timeout and TTL are currently 5 seconds.

Host ACME certificates live under `/var/lib/acme/tls-acme-<name>` and jail copies
are mounted read-only under `/var/lib/alloy/certs/<name>`. Consumers read
`certPath`, `keyPath`, `fullPath` (fullchain, private key, combined PEM respectively)
instead of constructing filesystem paths.

The current service registry contains CA, authoritative DNS, ACME DNS, DNS edge,
HTTP edge, SMTP edge, and TLS edge. `dns-resolver`, `postbox`, and `xhttp-proxy` are
not registered services. HTTP edge resolves names via the DNS helper, strips the
DNS trailing dot for nginx, and has a default TLS rejection vhost. TLS edge
requires a downstream certificate and always terminates downstream TLS; there
is no plaintext mode controlled by `downstream.tls.enable`.
