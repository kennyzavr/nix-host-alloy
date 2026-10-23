use std::{
    path::PathBuf,
    sync::atomic::{AtomicBool, Ordering},
};

use zeroize::Zeroizing;

use crate::domain::{
    DynError, NameMarker,
    facts::{Fact, FindFactError, ReadFactError},
    hosts::{FindHostError, Host},
    models,
    ports::{Ctx, Reporter},
    secrets::{FindSecretError, ReadSecretError, Secret},
    state::{LoadStateError, load_state, reset_state},
};

#[derive(Debug, Clone)]
pub struct DeployOptions {
    pub host: String,
    pub connection: Option<String>,
    pub identity_file: Option<PathBuf>,
}

/// A resolved signing key. The private secret stays encrypted until signing.
#[derive(Debug, Clone)]
pub struct DeployKey<'s> {
    name: &'s str,
    secret: Secret<'s>,
    public_key: Fact<'s>,
}

#[derive(Debug, thiserror::Error)]
pub enum CreateDeployKeyError {
    #[error("Signing key is not registered")]
    NotFound,

    #[error("Failed to find signing secret {}", NameMarker(secret_name))]
    FindSecret {
        secret_name: String,
        #[source]
        source: FindSecretError,
    },

    #[error("Encrypted signing secret {} is missing", NameMarker(secret_name))]
    MissingSecret { secret_name: String },

    #[error("Failed to find public key fact {}", NameMarker(fact_name))]
    FindFact {
        fact_name: String,
        #[source]
        source: FindFactError,
    },
}

impl<'s> DeployKey<'s> {
    pub fn new(
        name: &'s str,
        state: &'s models::State,
        ctx: &dyn Ctx,
    ) -> Result<Self, CreateDeployKeyError> {
        let data = state
            .deploy
            .signing_keys
            .get(name)
            .ok_or(CreateDeployKeyError::NotFound)?;
        let secret = Secret::find(&data.private_key_secret, state).map_err(|source| {
            CreateDeployKeyError::FindSecret {
                secret_name: data.private_key_secret.clone(),
                source,
            }
        })?;
        if !secret.exists(ctx) {
            return Err(CreateDeployKeyError::MissingSecret {
                secret_name: secret.name.to_owned(),
            });
        }
        let public_key = Fact::find(&data.public_key_fact, state).map_err(|source| {
            CreateDeployKeyError::FindFact {
                fact_name: data.public_key_fact.clone(),
                source,
            }
        })?;
        Ok(Self {
            name,
            secret,
            public_key,
        })
    }
}

/// A prepared deployment with an enabled host, selected connection and resolved keys.
#[derive(Debug, Clone)]
pub struct Deploy<'s> {
    host: Host<'s>,
    data: &'s models::HostDeploy,
    connection_name: &'s str,
    connection: &'s models::DeployConnection,
    keys: Vec<DeployKey<'s>>,
}

#[derive(Debug, thiserror::Error)]
pub enum CreateDeployError {
    #[error("Failed to find host {}", NameMarker(host_name))]
    FindHost {
        host_name: String,
        #[source]
        source: FindHostError,
    },

    #[error("Deploy is disabled for host {}", NameMarker(host_name))]
    Disabled { host_name: String },

    #[error(
        "No default connection for host {}; select one with --connection",
        NameMarker(host_name)
    )]
    NoDefaultConnection { host_name: String },

    #[error(
        "Connection {} is not defined for host {}",
        NameMarker(connection_name),
        NameMarker(host_name)
    )]
    FindConnection {
        host_name: String,
        connection_name: String,
    },

    #[error("Failed to prepare signing key {}", NameMarker(key_name))]
    Key {
        key_name: String,
        #[source]
        source: CreateDeployKeyError,
    },
}

impl<'s> Deploy<'s> {
    pub fn new(
        host_name: &'s str,
        connection_name: Option<&'s str>,
        state: &'s models::State,
        ctx: &dyn Ctx,
    ) -> Result<Self, CreateDeployError> {
        let host = Host::find(host_name, state).map_err(|source| CreateDeployError::FindHost {
            host_name: host_name.to_owned(),
            source,
        })?;
        let data = host
            .data
            .deploy
            .as_ref()
            .filter(|deploy| deploy.enable)
            .ok_or_else(|| CreateDeployError::Disabled {
                host_name: host.name.to_owned(),
            })?;
        let connection_name = connection_name
            .or(data.default_connection.as_deref())
            .ok_or_else(|| CreateDeployError::NoDefaultConnection {
                host_name: host.name.to_owned(),
            })?;
        let connection = data.connections.get(connection_name).ok_or_else(|| {
            CreateDeployError::FindConnection {
                host_name: host.name.to_owned(),
                connection_name: connection_name.to_owned(),
            }
        })?;
        let keys = data
            .signing_keys
            .iter()
            .map(|name| {
                DeployKey::new(name, state, ctx).map_err(|source| CreateDeployError::Key {
                    key_name: name.clone(),
                    source,
                })
            })
            .collect::<Result<_, _>>()?;
        Ok(Self {
            host,
            data,
            connection_name,
            connection,
            keys,
        })
    }
}

#[derive(Debug, thiserror::Error)]
pub enum DeployError {
    #[error(transparent)]
    Load(#[from] LoadStateError),

    #[error(transparent)]
    Create(#[from] CreateDeployError),

    #[error("Failed to read public key fact {}", NameMarker(fact_name))]
    ReadFact {
        fact_name: String,
        #[source]
        source: ReadFactError,
    },

    #[error("Failed to read signing secret {}", NameMarker(secret_name))]
    ReadSecret {
        secret_name: String,
        #[source]
        source: ReadSecretError,
    },

    #[error("Failed to build host {}", NameMarker(host_name))]
    Build {
        host_name: String,
        #[source]
        source: DynError,
    },

    #[error(
        "Failed to sign closure for host {} with key {}",
        NameMarker(host_name),
        NameMarker(key_name)
    )]
    Sign {
        host_name: String,
        key_name: String,
        #[source]
        source: DynError,
    },

    #[error("Failed to deliver signed closure to host {}", NameMarker(host_name))]
    Copy {
        host_name: String,
        #[source]
        source: DynError,
    },

    #[error(
        "Failed to activate host {}; closure was delivered, the system profile may have changed. No automatic rollback was performed",
        NameMarker(host_name)
    )]
    Activate {
        host_name: String,
        #[source]
        source: DynError,
    },

    #[error("Deployment cancelled")]
    Cancelled,
}

pub enum DeployEvent<'a> {
    Target {
        host: &'a Host<'a>,
        connection: &'a str,
    },
    Build(&'a Host<'a>),
    Sign {
        host: &'a Host<'a>,
        key_name: &'a str,
    },
    Copy(&'a Host<'a>),
    Activate(&'a Host<'a>),
    Completed(&'a Host<'a>),
    Error(&'a DeployError),
}

pub fn check_cancelled(cancelled: &AtomicBool) -> Result<(), DeployError> {
    if cancelled.load(Ordering::SeqCst) {
        Err(DeployError::Cancelled)
    } else {
        Ok(())
    }
}

pub fn deploy_host<C: Ctx>(
    options: &DeployOptions,
    cancelled: &AtomicBool,
    ctx: &mut C,
    mut reporter: impl for<'a> Reporter<C, DeployEvent<'a>>,
) -> Result<(), DeployError> {
    (|| -> Result<(), DeployError> {
        check_cancelled(cancelled)?;
        // An inherited or cached unchecked state must never authorize deployment.
        reset_state(ctx);
        let state = load_state(Default::default(), true, ctx)?;
        let deploy = Deploy::new(&options.host, options.connection.as_deref(), &state, ctx)?;
        let host = &deploy.host;
        reporter.report(
            ctx,
            DeployEvent::Target {
                host,
                connection: deploy.connection_name,
            },
        );
        check_cancelled(cancelled)?;
        reporter.report(ctx, DeployEvent::Build(host));
        let build = ctx
            .deploy_runner()
            .build_host(host.name, ctx.env().into(), cancelled)
            .map_err(|source| DeployError::Build {
                host_name: host.name.to_owned(),
                source,
            })?;
        for key in &deploy.keys {
            check_cancelled(cancelled)?;
            reporter.report(
                ctx,
                DeployEvent::Sign {
                    host,
                    key_name: key.name,
                },
            );
            let public = key
                .public_key
                .read(ctx)
                .map_err(|source| DeployError::ReadFact {
                    fact_name: key.public_key.name.to_owned(),
                    source,
                })?;
            let private =
                Zeroizing::new(
                    key.secret
                        .read(ctx)
                        .map_err(|source| DeployError::ReadSecret {
                            secret_name: key.secret.name.to_owned(),
                            source,
                        })?,
                );
            check_cancelled(cancelled)?;
            ctx.deploy_runner()
                .sign(build.toplevel(), &private, public.trim(), cancelled)
                .map_err(|source| DeployError::Sign {
                    host_name: host.name.to_owned(),
                    key_name: key.name.to_owned(),
                    source,
                })?;
        }
        reporter.report(ctx, DeployEvent::Copy(host));
        ctx.deploy_runner()
            .copy(
                build.toplevel(),
                deploy.connection,
                options.identity_file.as_deref(),
                &ctx.env().ssh_options,
                cancelled,
            )
            .map_err(|source| DeployError::Copy {
                host_name: host.name.to_owned(),
                source,
            })?;
        reporter.report(ctx, DeployEvent::Activate(host));
        ctx.deploy_runner()
            .activate(
                build.toplevel(),
                deploy.connection,
                options.identity_file.as_deref(),
                &ctx.env().ssh_options,
                &deploy.data.activation,
                cancelled,
            )
            .map_err(|source| DeployError::Activate {
                host_name: host.name.to_owned(),
                source,
            })?;
        reporter.report(ctx, DeployEvent::Completed(host));
        Ok(())
    })()
    .inspect_err(|err| {
        reporter.report(ctx, DeployEvent::Error(err));
    })
}
