# TODO and ideas

This file tracks planned work and less-defined ideas. The current deploy design
and behavior are documented in [docs/agents/deploy.md](docs/agents/deploy.md).
The items below describe future work; proposed commands and options are not yet
part of the supported interface.

## Planned: coordinated updates from configuration to deployment

After infrastructure code changes, Alloy should determine what needs updating
and guide the user through the work. The user should not have to guess which
generators to rerun, which secrets to rekey, or which hosts to deploy.

The workflow should connect three stages:

1. Refresh missing or outdated generator outputs, including their dependencies.
2. Update the encrypted deployment copies of secrets affected by those changes
   or by changes to their recipients.
3. Identify hosts affected by configuration or secret changes, including changes
   to their jails, and deploy them in dependency order.

Provide an inspectable plan that explains why each action is needed. Planning
should not run generators, rewrite secrets, or activate hosts. Where the result
depends on data that has not been generated yet, show that uncertainty and refine
the remaining plan after generation rather than presenting guesses as final.

Execution should skip work that is already current and report completed, failed,
and pending actions so an interrupted operation can be continued. Track prepared
workspace changes separately from successful deployment: generating or rekeying
a secret does not mean its host has received it. Define how the last successful
deployment is recorded and how an unknown deployment state is reported.

This workflow depends on the generator and secret changes below, and on
[deployment ordering](#planned-sequential-multi-host-deployment-with-ordering).
The exact CLI and state-tracking design remain open.

## Planned: refresh generators together with their dependencies

Refreshing an outdated generator should bring its required inputs up to date
and identify any downstream outputs that also need refreshing. The current
generator fingerprint records the generator package; the update workflow also
needs to account for changes in the data generators consume.

- Inspect the transitive prerequisites of a selected generator and refresh
  missing or outdated prerequisites before running it.
- When a generator changes facts or secrets used by other generators, reconsider
  those dependent generators even if their own package fingerprints have not
  changed. Define how these data dependencies are declared or tracked.
- Preserve the distinction between dependencies and ordering: `wants` selects
  prerequisites, while `after` only orders generators already selected. An
  ordering constraint alone should not imply that outputs need regenerating.
- Re-evaluate configuration after upstream outputs change before deciding which
  downstream work is still needed.
- Distinguish missing, outdated, and current outputs. Avoid forcing every
  generator or rotating unrelated keys simply to refresh one part of the graph.
  Record successful refreshes only after execution completes.

The existing execution and fingerprint behavior is described in
[CLI and state](docs/agents/cli-state.md#generator-lifecycle).

## Planned: selective secret rekeying and deployment impact

When a generator or a manual edit changes a master secret, its encrypted copies
for hosts and jails must also be updated. Currently, rekeying skips an existing
deployment copy unless forced; its existence does not establish that it is
current.

- Track which source secret revision and recipient configuration were used to
  create each deployment copy. Refresh copies when the source changes, recipients
  change, or a copy is missing, and skip copies that are already current.
- Connect generator results to this tracking so refreshing a generator can
  identify the secrets that need rekeying. Regenerating a fact alone should not
  automatically force every secret to be rekeyed.
- Report affected hosts and jails, the secrets that changed, and the reason for
  each update. Include this information in the deployment plan and retain pending
  deployment status until the affected host is successfully updated.
- Provide a way to rekey a host together with all jails assigned to it, without
  listing every jail manually. Keep explicit selection of individual jails
  available, and process overlapping selections only once. Decide whether host
  selection includes its jails by default or through an explicit option, and use
  consistent selection rules for listing, planning, and rekeying.
- Attribute a jail's changed secrets to its owning host when reporting required
  deployments, even if the host itself has no changed secrets.

## Planned: sequential multi-host deployment with ordering

Allow one CLI invocation to deploy several hosts sequentially and in a
deterministic order. This is a batch orchestration feature; parallel execution
is a separate follow-up and is not part of this item.

The host deployment graph should follow the existing generator dependency model:

- `deploy.wants` adds the named host and its transitive prerequisites to the
  selected deployment set, and requires each prerequisite to complete before
  dependent hosts run.
- `deploy.after` adds an ordering edge only when both hosts are already selected;
  it does not select the referenced host.
- Reject unknown or disabled references and dependency cycles before starting
  any build, signing, copy, or activation work.
- Topologically order the selected hosts deterministically. Preserve the user's
  argument order where dependencies do not constrain the order.
- Run one host at a time. Stop after the first failure and report which hosts
  completed, which failed, and which were not started. Do not imply rollback of
  already activated hosts.

An initial CLI shape could accept an explicit host list, such as
`alloy-cli deploy host-a host-b`. Whether to add `--all` or tag-based selection
can be decided with the CLI design. Do not deploy every enabled host implicitly.

## Planned: reliable and less repetitive YubiKey interaction

Missed YubiKey touches currently cause age decryption to fail during generators
or secret rekeying. Deployment also requires repeated confirmations in the
reported workflow. Improve both recovery from timeouts and the number of prompts
needed to complete an operation.

### Recover from touch timeouts

- Clearly indicate when an operation is waiting for the hardware token and which
  step needs it. Distinguish a touch timeout from cancellation or another
  decryption failure where the age/plugin interface makes that possible.
- Allow retrying the failed decryption without restarting completed work or
  regenerating credentials that were already created successfully.
- Preserve valid outputs and report partial progress. A timeout must not leave
  an incomplete operation recorded as successfully refreshed or rekeyed.
- Define bounded retry behavior for noninteractive use and let the user cancel
  an interactive retry.

### Reduce repeated confirmations

- Trace repeated decryption requests during deploy, generator execution, and
  rekeying to identify where the same secret is being opened more than once.
- Reuse a successful decryption within one operation where possible. In
  particular, rekeying one master secret for several hosts or jails should not
  require decrypting it separately for every destination.
- Investigate how to share this work across generator subprocesses and the
  coordinated update workflow while respecting the token's touch policy. Do not
  assume that one confirmation can unlock all unrelated encrypted secrets.
- If decrypted material is reused, keep it only in memory for the operation and
  clear it afterwards. Avoid persistent plaintext caches.

## Planned: certificate hostname checks with wildcard support

Fix certificate coverage validation, starting with the currently commented-out
check in `smtp-edge`. A service hostname must be checked against the names the
certificate actually covers, including wildcard names.

- Resolve Alloy DNS nodes to domain names and account for certificate source
  settings such as `src.acme.wildcard`. Comparing the raw `domains` entries with
  the service's DNS node is insufficient.
- Support exact names and wildcard coverage. For example, `*.example.org` covers
  `mail.example.org`; it does not cover `example.org` or `a.mail.example.org`
  unless those names are covered separately.
- Put the matching logic in a shared helper and use it in `smtp-edge`. Review
  HTTP and TLS edge validation for the same requirement so services use
  consistent rules.
- Restore the SMTP assertion with a useful error naming the service, hostname,
  and selected certificate. Verify exact matches, wildcard matches, the zone
  apex, deeper subdomains, and unrelated domains.

## Planned: locally generated SSH host keys for installation

Generate declared host SSH keys on the machine running Alloy and make them
available during first installation, so users can install with `nixos-anywhere`
or `nixos-install` without manually creating and placing each key first. This
targets keys declared under `hosts.<host>.ssh.keys`; it is separate from Nix
store signing keys used by deploy.

- Reuse the existing key declarations and their path, algorithm, and size
  settings. Provide an opt-in generator/bootstrap flow that creates each key
  locally, publishes its public half as a fact, and stores its private half only
  as an encrypted secret.
- Integrate with installation workflows to place the decrypted private key at
  the declared persistent path on the target before the system's
  `alloy-ssh-keygen.service` runs. The existing runtime generator should then
  validate and preserve the supplied key instead of creating a different one.
- Support both remote `nixos-anywhere` installs and local `nixos-install` from
  mounted target filesystems. Keep the installer-specific delivery mechanism
  explicit; neither flow should require putting private material in a Nix
  derivation, store path, command argument, or log.
- Keep generated private material encrypted in the workspace and expose only
  public keys through facts. Do not silently replace an existing key; rotation
  should use an explicit new key/name or an explicit replacement operation.
- Define behavior for partial installs, retries, existing target keys, and
  interruption so a retry does not accidentally rotate the host identity.

The exact CLI and configuration API remain open. The key lifecycle and runtime
validation behavior are documented in [SSH and boot](docs/agents/ssh-boot.md).

## Idea: service monitoring and notifications

Explore optional observability for Alloy infrastructure, with a shared dashboard
for service health, operational errors, and authentication activity. Automatic
IP blocking is not a goal.

Potential components include Grafana for dashboards and alerting, Loki for
searchable logs (initially SSH, Postfix, and Dovecot/IMAP), Prometheus and service
exporters as needed, and availability probes for public endpoints. Collectors
could run on hosts and inside selected jails, read local journals, and send logs
over the internal overlay. Host access to jail journals should not be a
prerequisite. Grafana Alloy is one collector candidate and is a separate project
from nix-host-alloy.

Useful views could cover successful and failed SSH logins, SMTP/IMAP
authentication failures, mail delivery errors and queue size, service
availability, and host disk usage. Verify client-address reporting through edge
proxies, including PROXY protocol where applicable.

Later, consider email and Telegram notifications for sustained outages, growing
mail queues, authentication-failure spikes, and low disk space. Include recovery
notifications, grouping, and delays to reduce noise. Telegram would provide a
notification path independent of the monitored mail service. Credentials should
use the existing secret pipeline.

If pursued, expose monitoring through optional Alloy modules: central components
in dedicated jails, and collectors/exporters attached to the hosts or jails they
observe. Decide the stack, resource limits, retention, and dashboard access when
implementation becomes relevant.

## Longer-term ideas: service and network abstractions

These are architectural directions for later development. The entity model,
interfaces, and migration approach need further design before implementation.

### Services as first-class entities, with host roles

Introduce a common service entity that gives every service an identity and a
shared set of capabilities. A service could own several components or jails,
declare its requirements, and expose interfaces for other services to consume.

- Let infrastructure assign roles to hosts, such as `edge` or `storage`, and
  place service components through those roles. Keep the mapping from roles to
  concrete hosts in the infrastructure configuration so reusable service modules
  do not need to name particular machines.
- Define how placement resolves when a role matches one or several hosts, how
  services express their placement requirements, and how missing or incompatible
  assignments are reported during evaluation.
- Provide common behavior through the service entity. Features such as monitoring,
  dependency reporting, secret handling, and deployment planning could then be
  integrated once and made available to services through the shared model.
- Reduce the repetitive work needed to write a service: declaring its components
  and requirements should let common modules derive the necessary host and jail
  configuration and collect diagnostics.

The goal is to make services easier to write, reuse, and extend while allowing
their placement to change independently of their implementation.

### Typed service interfaces through exports

Explore an `exports` mechanism, or a similar abstraction, for declaring the
interfaces a service makes available to consumers. Exports should describe a
public contract that consumers can use without knowing the service's internal
jail names, host placement, or configuration structure.

- Give interfaces explicit types using the Nix module system. Validate both the
  producer's declaration and the consumer's requirements during evaluation, with
  useful errors for incompatible connections.
- Support richer contracts than an address and port. Depending on the interface
  type, these could include protocol, network membership, TLS or authentication
  requirements, and the information needed to configure a client or proxy.
- Let consumers reference a service and its named interface. Resolve the concrete
  targets from the service's placement and network attachments.
- Investigate whether these typed exports can cover and extend the existing
  endpoint model. If so, they could eventually replace `endpoints`; define how
  current routing and service consumers would migrate before removing that API.

The name `exports`, the set of interface types, and the relationship to existing
endpoints are provisional.

### Networks with interchangeable implementations

Introduce a separate `networks` entity that describes a logical network through
a common interface. Hosts, jails, and service exports should refer to that
network without depending on its particular transport or routing implementation.

- Define the shared contract for network membership, addressing, and connectivity,
  and separate it from settings specific to a network implementation.
- Move the current overlay functionality into one implementation of this
  abstraction, based on WireGuard, GRE, and babeld. This preserves the existing
  networking approach while making room for other implementations later.
- Keep transport and routing details within the selected implementation. Define
  how implementations expose their capabilities and how incompatible requirements
  are rejected, rather than assuming every network has the same properties.
- Integrate the network abstraction with service placement and typed exports so
  services can declare which networks they use through the common model.
- Plan a migration for existing overlay declarations and their consumers,
  including address allocation, DNS, and service routing.
