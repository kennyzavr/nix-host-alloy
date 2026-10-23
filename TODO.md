# TODO and ideas

This file tracks planned work and less-defined ideas. The current deploy design
and behavior are documented in [docs/agents/deploy.md](docs/agents/deploy.md).

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
