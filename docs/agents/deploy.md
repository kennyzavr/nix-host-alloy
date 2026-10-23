# Deploy

Deploy builds a selected NixOS toplevel locally, signs its runtime closure,
copies it to one host over SSH, and activates it remotely.

```sh
alloy-cli deploy gallium
alloy-cli deploy gallium --connection public -i ~/.ssh/id_ed25519
ALLOY_SSHOPTS='-o ProxyJump=bastion -o "IdentityFile=/home/user/key with spaces"' \
  alloy-cli deploy gallium
```

The command currently accepts one host. Orchestration is in
`alloy-core::domain::deploy`, process execution is in `alloy-core::infra::deploy`,
and `alloy-cli` owns arguments and progress presentation. `Deploy::new` resolves
the host, connection, and signing keys. The domain passes connection, identity,
SSH options, and activation settings explicitly to `DeployRunner`. The runner
builds, signs, copies, and activates the prepared host deployment. Multi-host
deployment and dependency ordering are planned in [TODO](../../TODO.md).

## Motivation and scope

The original use case is an infrastructure repository alongside this one, with
VPS hosts such as `iridium` and `gallium`. Evaluating and building a system on a
small VPS caused memory pressure and an OOM kill. Deploy moves evaluation and
builds to the machine running the CLI while leaving store-path delivery and
activation on the target.

The SSH user should not need to be a Nix `trusted-user`. Alloy signs the locally
built closure and configures the target to trust the public signing key. The
private key is decrypted only on the machine running deploy and is never sent to
the host. Remote activation privilege is separate; the default is sudo with an
interactive password.

The first version deploys one host per invocation. It supports local builds,
closure signing, SSH delivery, system-profile update, and activation. Automatic
rollback, post-activation reachability checks, confirmation timers, a remote
agent, and parallel multi-host execution are not implemented.

## Configuration

The core module is [modules/core/deploy.nix](../../modules/core/deploy.nix).
`deploy.signingKeys.<name>` registers the logical secret, fact, and generator
names:

| Option | Default |
| --- | --- |
| `privateKeySecret` | `deploy/signing-keys/<name>/private` |
| `publicKeyFact` | `deploy/signing-keys/<name>/public` |
| `generator` | `deploy/signing-keys/<name>` |

These are Alloy entity names, not filesystem paths. Workspace configuration
determines their backing files. The registry name is also the Nix signing-key
name. For key rotation, add a new registry entry and temporarily trust both keys;
Git history alone does not provide overlapping trust during rotation.

Each registry entry creates a `deploy/signing-key` generator. It runs
`nix key generate-secret` and `nix key convert-secret-to-public`, then writes the
private key through `ALLOY_BIN secrets set` and public key through
`ALLOY_BIN facts set`. Plaintext key material is not embedded in Nix evaluation
or store outputs.

Example:

```nix
deploy.signingKeys."home-1" = { };

hosts.gallium.deploy = {
  enable = true;
  signingKeys = [ "home-1" ];
  defaultConnection = "public";
  connections = {
    public = {
      address = "gallium.example.org";
      user = "admin";
      port = 22;
    };
    overlay.address = "gallium.internal";
  };
  activation = {
    method = "sudo";
    askPassword = true;
    policy = "strict";
  };
};
```

`deploy.enable` defaults to false. A sole connection is selected as the default;
multiple connections require `defaultConnection`. `signingKeys` selects keys
from the registry. `trustedSigningKeys` defaults to that list and may also
contain previous keys during rotation. Every signing key must also be trusted by
the target.

Public keys are added to the target's `nix.settings.extra-trusted-public-keys`.
The module does not change `trusted-users`, Nix signature requirements, or SSH
server configuration, and it never deploys the private signing key.

### Deployment target

`deploy.target` selects the NixOS configuration whose toplevel will be deployed:

```nix
deploy.target.host = { };
# or
deploy.target.qemu.variant = "full-boot";
```

The default is `host`. For a QEMU target, Alloy resolves the selected variant's
`nixosConfig.system.build.toplevel`; it does not deploy the VM image derivation.
The read-only `deploy.targetToplevel` option resolves the target to the NixOS
system toplevel. The runner builds this option through Alloy evaluation, so a
public flake output named `nixosConfigurations` is not required.

### Activation

`activation.method` is `sudo` or `direct`. The default is `sudo`; its
`askPassword` defaults to true. With `direct`, `askPassword` defaults to false
and must remain false. `direct` requires the SSH session to already have the
privileges needed to update the system profile and activate NixOS.

`activation.policy` is `strict` or `warn`, defaulting to `strict`. Under
`strict`, any non-zero `switch-to-configuration` exit fails deployment. Under
`warn`, a non-zero exit produces an `Alloy: warning` and deployment succeeds
only when `/run/current-system` resolves to the requested toplevel. Otherwise,
deployment fails. This check confirms that the target toplevel became current;
it does not prove that every activation script or systemd unit succeeded. The
warning remains visible in SSH output.

To keep only the public key locally, disable the generated private secret:

```nix
generators.instances."deploy/signing-keys/home-1".enable = false;
```

The registry still declares the public fact, while the private secret is
declared only by the enabled generator. Do not require the private secret during
ordinary configuration evaluation: it is needed only when deploying with that
key.

## SSH authentication and transport

An Alloy connection contains `address`, nullable `user`, and nullable `port`.
Null user and port values inherit local OpenSSH configuration/defaults.
Identity files and extra SSH options are client-side settings, so they are not
stored in the Nix API. The CLI provides `-i`/`--identity-file` and accepts
`ALLOY_SSHOPTS`; the global `--ssh-options` flag overrides that environment
value. The effective SSH options are propagated to child Alloy processes.

The same address and SSH arguments are used for copying and activation.
`ALLOY_SSHOPTS` is parsed with shlex quoting, without shell evaluation, and the
resulting arguments are passed to OpenSSH without a custom flag allowlist.
Explicit connection `user` and `port` are placed before environment arguments,
so they take precedence. `-i` adds an identity without enabling
`IdentitiesOnly`. OpenSSH host-key verification remains enabled.

Delivery uses `nix copy --to ssh-ng://<address>` and passes quoted SSH options
through `NIX_SSHOPTS`. The implementation targets Nix 2.34.7, whose
[NIX_SSHOPTS parser supports shell quoting](https://github.com/NixOS/nix/blob/2.34.7/src/libstore/ssh.cc).
The literal `localhost` is rejected because Nix treats it as a local store;
use an IP address or SSH alias for local SSH. The remote SSH user must be able
to run `nix-daemon --stdio`; it does not need to be a `trusted-user`.

## State and implementation boundaries

`build.state` exports the signing-key registry names and each host's deploy
metadata: `enable`, named connections, `defaultConnection`, signing and trusted
key names, and activation settings. Public key contents and decrypted secrets
are not included. The existing `state.facts` and `state.secrets` maps provide
references to their files. The Rust host model also requires `hosts.<name>.system`.

The CLI reads the public key with `Fact::find()` and `Fact::read()`, trims
surrounding whitespace, and checks it against the public key derived from the
decrypted secret using `nix key convert-secret-to-public`. The secret is read
only after the target toplevel has built. State is reset before checked loading;
the build also requests assertions.

Important implementation points:

- [CLI command](../../packages/alloy-cli/src/commands/deploy.rs) parses
  `deploy <host>`, `--connection`/`-c`, and `--identity-file`/`-i`.
- [Domain deploy](../../packages/alloy-core/src/domain/deploy.rs) prepares the
  deployment and orchestrates build, sign, copy, and activation.
- [DeployRunner port](../../packages/alloy-core/src/domain/ports.rs) separates
  domain logic from process execution. `DeployBuild` retains a GC root through
  the operation.
- [Nix adapter](../../packages/alloy-core/src/infra/nix.rs) evaluates Alloy
  modules. [Deploy infra](../../packages/alloy-core/src/infra/deploy.rs) builds
  `res.config.hosts.<host>.deploy.targetToplevel`, signs, copies, and activates.
- The signing secret is passed to Nix through a Linux memfd on stdin. Decrypted
  buffers are zeroized; plaintext does not enter argv, environment variables,
  logs, workspace files, or the Nix store.

## Deployment sequence

1. Reset and load checked state. Verify deploy is enabled, select the requested
   or default connection, and resolve configured signing keys.
2. Build the selected host or QEMU variant's NixOS toplevel locally and retain a
   GC root until delivery finishes. Cross-compilation and remote builders are
   not configured automatically when local and target systems differ.
3. Decrypt signing secrets, read and trim public-key facts, and verify each
   secret against its public key.
4. Run local `nix store sign --recursive` for each selected key. This signs the
   closure; it does not sign the Git commit or grant activation privileges.
5. Copy the closure over Nix's SSH transport as the ordinary remote user.
6. After successful delivery, update `/nix/var/nix/profiles/system` and invoke
   `<toplevel>/bin/switch-to-configuration switch` in one remote SSH session.
   Sudo activation uses one privileged shell. Password prompts use `ssh -t`;
   non-interactive sudo uses `ssh -T` and `sudo -n`.
7. Release local roots and resources on success, failure, or Ctrl+C. A build,
   signing, or delivery error stops before the remote system profile changes.

The signing key is not a YubiKey key. A YubiKey may protect age decryption, after
which the signing key temporarily exists in CLI memory. The decrypted buffer is
zeroized and the memfd is closed after signing. The sudo password is entered in
the activation SSH session and is separate from the signing-key path.

Cancellation sends SIGINT to the foreground child and waits for cleanup. It does
not reverse remote changes already completed. Deployment failures return exit
code 1 and cancellation returns 130. There is no automatic rollback. In `warn`
mode, the target may be current even though a service or activation step failed;
the CLI reports completion only when the target-current check passes.

During a manual `iridium` deployment with `warn`, the ACME renewal unit remained
failed and visible as a warning while deploy reported completion. This is an
example of the policy's boundary: it checks that the requested toplevel is
current, not that every service is healthy.
