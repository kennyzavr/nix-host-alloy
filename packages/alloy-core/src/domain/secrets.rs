use either::Either;

use crate::domain::NameMarker;
use crate::domain::hosts::{FindHostError, Host};
use crate::domain::jails::{FindJailError, Jail};
use crate::domain::ports::Ctx;
use crate::domain::state::{LoadStateError, load_state};
use crate::domain::{DynError, models, ports::Reporter};

#[derive(Debug, Clone, Copy)]
pub struct Secret<'s> {
    pub name: &'s str,
    pub data: &'s models::Secret,
    pub age_keys: &'s [models::AgeKeyPair],
    _priv: (),
}

#[derive(thiserror::Error, Debug)]
pub enum FindSecretError {
    #[error("Not found")]
    NotFound,

    #[error("No master age keys defined")]
    NoKeys,
}

#[derive(thiserror::Error, Debug)]
pub enum ReadSecretError {
    #[error("Failed to read master secret file")]
    FsRead(#[source] DynError),

    #[error("Failed to dencrypt master secret data")]
    AgeDecrypt(#[source] DynError),
}

#[derive(thiserror::Error, Debug)]
pub enum WriteSecretError {
    #[error("Failed to write master secret file")]
    FsWrite(#[source] DynError),

    #[error("File not in git repo")]
    GitCheck(#[source] DynError),

    #[error("Failed to add secret file to git index")]
    GitAdd(#[source] DynError),

    #[error("Failed to encrypt master secret data")]
    AgeEncrypt(#[source] DynError),
}

impl<'s> Secret<'s> {
    pub fn find(name: &'s str, state: &'s models::State) -> Result<Self, FindSecretError> {
        let data = state.secrets.get(name).ok_or(FindSecretError::NotFound)?;

        let age_keys = &state.secrets_age_key_pairs;
        if age_keys.is_empty() {
            return Err(FindSecretError::NoKeys);
        }

        Ok(Secret {
            name,
            data,
            age_keys,
            _priv: (),
        })
    }

    pub fn read(&self, ctx: &dyn Ctx) -> Result<Vec<u8>, ReadSecretError> {
        let path = ctx.env().workspace_root.join(&self.data.file);
        log::debug!("Reading secret file: {}", path.display());
        let encrypted_data = ctx.fs().read(&path).map_err(ReadSecretError::FsRead)?;

        let mut identities = self.age_keys.iter().map(|k| &k.identity);
        let data = ctx
            .age()
            .decrypt(&mut identities, &encrypted_data)
            .map_err(ReadSecretError::AgeDecrypt)?;

        Ok(data)
    }

    pub fn write(
        &self,
        data: &[u8],
        force: Option<bool>,
        add_to_git: Option<bool>,
        ctx: &dyn Ctx,
    ) -> Result<(), WriteSecretError> {
        let path = ctx.env().workspace_root.join(&self.data.file);

        let add_to_git = add_to_git.or(ctx.env().add_to_git).unwrap_or(false);
        let force = force.or(ctx.env().force).unwrap_or(false);

        ctx.fs()
            .mk_parent_dirs(&path)
            .map_err(WriteSecretError::FsWrite)?;

        if add_to_git {
            ctx.git().check(&path).map_err(WriteSecretError::GitCheck)?;
        }

        log::debug!(
            "Encrypting and writing secret file: {}",
            self.data.file.display()
        );
        let mut recipients = self.age_keys.iter().map(|k| &k.recipient);
        let encrypted_data = ctx
            .age()
            .encrypt(&mut recipients, &data)
            .map_err(WriteSecretError::AgeEncrypt)?;

        ctx.fs()
            .write(&path, &encrypted_data, force)
            .map_err(WriteSecretError::FsWrite)?;

        if add_to_git {
            ctx.git().add(&path).map_err(WriteSecretError::GitAdd)?;
        }

        Ok(())
    }

    pub fn exists(&self, ctx: &dyn Ctx) -> bool {
        let path = ctx.env().workspace_root.join(&self.data.file);
        ctx.fs().exists(&path)
    }
}

#[derive(Debug, Clone, Copy)]
pub struct SecretRef<'s> {
    pub master: &'s Secret<'s>,
    pub data: &'s models::SecretRef,
    pub age_keys: &'s [models::AgeKeyPair],
    _priv: (),
}

#[derive(thiserror::Error, Debug)]
pub enum FindSecretRefError {
    #[error("secret {} not found", NameMarker(&secret_name))]
    NotFound { secret_name: String },

    #[error("No age keys defined for host")]
    NoKeys { host_name: String },
}

#[derive(thiserror::Error, Debug)]
pub enum RekeySecretRefError {
    #[error(transparent)]
    MasterRead(#[from] ReadSecretError),

    #[error("Failed to encrypt secret ref data")]
    AgeEncrypt(#[source] DynError),

    #[error("Failed to write secret file")]
    FsWrite(#[source] DynError),

    #[error("File not in git repo")]
    GitCheck(#[source] DynError),

    #[error("Failed to add to git index")]
    GitAdd(#[source] DynError),
}

impl<'s> SecretRef<'s> {
    pub fn master(&self) -> &Secret<'s> {
        &self.master
    }

    fn build(
        data: &'s models::SecretRef,
        host: Host<'s>,
        master: &'s Secret<'s>,
    ) -> Result<Self, FindSecretRefError> {
        let age_keys = &host.data.secrets_age_key_pairs;

        if age_keys.is_empty() {
            return Err(FindSecretRefError::NoKeys {
                host_name: host.name.to_string(),
            })?;
        }

        Ok(SecretRef {
            master,
            data,
            age_keys,
            _priv: (),
        })
    }

    fn find_for_host(
        host: Host<'s>,
        master: &'s Secret<'s>,
    ) -> Result<SecretRef<'s>, FindSecretRefError> {
        let data = host
            .data
            .secrets
            .get(master.name)
            .ok_or(FindSecretRefError::NotFound {
                secret_name: master.name.to_string(),
            })?;
        let entity = Self::build(data, host, master)?;

        Ok(entity)
    }

    fn find_for_jail(jail: Jail<'s>, master: &'s Secret<'s>) -> Result<Self, FindSecretRefError> {
        let data = jail
            .data
            .secrets
            .get(master.name)
            .ok_or(FindSecretRefError::NotFound {
                secret_name: master.name.to_string(),
            })?;
        let entity = Self::build(data, jail.host, master)?;

        Ok(entity)
    }

    fn rekey(
        &self,
        force: Option<bool>,
        add_to_git: Option<bool>,
        ctx: &dyn Ctx,
    ) -> Result<bool, RekeySecretRefError> {
        let path = ctx.env().workspace_root.join(&self.data.file);

        let add_to_git = add_to_git.or(ctx.env().add_to_git).unwrap_or(false);
        let force = force.or(ctx.env().force).unwrap_or(false);

        if !force && self.exists(ctx) {
            return Ok(false);
        }

        ctx.fs()
            .mk_parent_dirs(&path)
            .map_err(RekeySecretRefError::FsWrite)?;

        if add_to_git {
            ctx.git()
                .check(&path)
                .map_err(RekeySecretRefError::GitCheck)?;
        }

        let data = self.master.read(ctx)?;

        let mut recipients = self.age_keys.iter().map(|k| &k.recipient);
        let encrypted_data = ctx
            .age()
            .encrypt(&mut recipients, &data)
            .map_err(RekeySecretRefError::AgeEncrypt)?;

        ctx.fs()
            .write(&path, &encrypted_data, force)
            .map_err(RekeySecretRefError::FsWrite)?;

        if add_to_git {
            ctx.git().add(&path).map_err(RekeySecretRefError::GitAdd)?;
        }

        Ok(true)
    }

    fn exists(&self, ctx: &dyn Ctx) -> bool {
        let path = ctx.env().workspace_root.join(&self.data.file);
        ctx.fs().exists(&path)
    }
}

#[derive(thiserror::Error, Debug)]
pub enum GetSecretValueError {
    #[error(transparent)]
    Load(#[from] LoadStateError),

    #[error(transparent)]
    Find(#[from] FindSecretError),

    #[error(transparent)]
    Read(#[from] ReadSecretError),
}

pub enum GetSecretValueEvent<'a> {
    ValueRead(&'a Secret<'a>),

    Error(&'a GetSecretValueError),
}

pub fn get_secret_value<C: Ctx>(
    name: &str,
    ctx: &mut C,
    mut reporter: impl for<'a> Reporter<C, GetSecretValueEvent<'a>>,
) -> Result<Vec<u8>, GetSecretValueError> {
    ((|| -> Result<_, _> {
        let state = load_state(false, ctx)?;
        let secret = Secret::find(name, &state)?;
        let data = secret.read(&*ctx)?;
        reporter.report(ctx, GetSecretValueEvent::ValueRead(&secret));

        Ok(data)
    })())
    .inspect_err(|err| {
        reporter.report(ctx, GetSecretValueEvent::Error(&err));
    })
}

#[derive(thiserror::Error, Debug)]
pub enum SetSecretValueError {
    #[error(transparent)]
    Load(#[from] LoadStateError),

    #[error(transparent)]
    Find(#[from] FindSecretError),

    #[error(transparent)]
    Write(#[from] WriteSecretError),
}

pub enum SetSecretValueEvent<'a> {
    ValueWritten(&'a Secret<'a>),

    Error(&'a SetSecretValueError),
}

pub fn set_secret_value<C: Ctx>(
    name: &str,
    data: &[u8],
    force: Option<bool>,
    add_to_git: Option<bool>,
    ctx: &mut C,
    mut reporter: impl for<'a> Reporter<C, SetSecretValueEvent<'a>>,
) -> Result<(), SetSecretValueError> {
    ((|| -> Result<_, _> {
        let state = load_state(false, ctx)?;
        let secret = Secret::find(name, &state)?;
        secret.write(data, force, add_to_git, &*ctx)?;
        reporter.report(ctx, SetSecretValueEvent::ValueWritten(&secret));

        Ok(())
    })())
    .inspect_err(|err| {
        reporter.report(ctx, SetSecretValueEvent::Error(&err));
    })
}

#[derive(thiserror::Error, Debug)]
pub enum ShowSecretError {
    #[error(transparent)]
    Load(#[from] LoadStateError),

    #[error("Failed to find secret {}", NameMarker(&secret_name))]
    FindSecret {
        secret_name: String,
        #[source]
        source: FindSecretError,
    },
}

pub enum ShowSecretEvent<'a> {
    Secret(&'a Secret<'a>),

    HostRef {
        host: &'a Host<'a>,
        secret_ref: &'a SecretRef<'a>,
    },

    JailRef {
        jail: &'a Jail<'a>,
        secret_ref: &'a SecretRef<'a>,
    },

    Error(&'a ShowSecretError),
}

pub fn show_secret<C: Ctx>(
    secret_name: &str,
    ctx: &mut C,
    mut reporter: impl for<'a> Reporter<C, ShowSecretEvent<'a>>,
) -> Result<(), ShowSecretError> {
    let state = load_state(false, ctx)
        .map_err(ShowSecretError::Load)
        .map_err(|err| {
            reporter.report(ctx, ShowSecretEvent::Error(&err));
            err
        })?;

    let secret =
        match Secret::find(secret_name, &state).map_err(|source| ShowSecretError::FindSecret {
            secret_name: secret_name.to_string(),
            source,
        }) {
            Ok(secret) => {
                reporter.report(ctx, ShowSecretEvent::Secret(&secret));
                secret
            }
            Err(err) => {
                reporter.report(ctx, ShowSecretEvent::Error(&err));
                return Err(err);
            }
        };

    let hosts = state
        .hosts
        .keys()
        .filter_map(|name| Host::find(name, &state).ok());
    for host in hosts {
        let Ok(secret_ref) = SecretRef::find_for_host(host, &secret) else {
            continue;
        };

        reporter.report(
            ctx,
            ShowSecretEvent::HostRef {
                host: &host,
                secret_ref: &secret_ref,
            },
        );
    }

    let jails = state
        .jails
        .keys()
        .filter_map(|name| Jail::find(name, &state).ok());
    for jail in jails {
        let Ok(secret_ref) = SecretRef::find_for_jail(jail, &secret) else {
            continue;
        };

        reporter.report(
            ctx,
            ShowSecretEvent::JailRef {
                jail: &jail,
                secret_ref: &secret_ref,
            },
        );
    }

    Ok(())
}

#[derive(thiserror::Error, Debug)]
pub enum ListSecretsError {
    #[error(transparent)]
    Load(#[from] LoadStateError),

    #[error("Failed to find secret {}", NameMarker(&secret_name))]
    FindSecret {
        secret_name: String,
        #[source]
        source: FindSecretError,
    },
}

pub enum ListSecretsEvent<'a> {
    Secret(&'a Secret<'a>),

    Error(&'a ListSecretsError),

    NoMatchingSecrets,
}

fn has_intersection(slice: &[impl AsRef<str>], vec: &Vec<String>) -> bool {
    slice
        .iter()
        .any(|slice_item| vec.iter().any(|vec_item| vec_item == slice_item.as_ref()))
}

pub fn list_secrets<C: Ctx>(
    secret_names: &[impl AsRef<str>],
    tags: &[impl AsRef<str>],
    ctx: &mut C,
    mut reporter: impl for<'a> Reporter<C, ListSecretsEvent<'a>>,
) -> Result<(), Vec<ListSecretsError>> {
    let state = load_state(false, ctx)
        .map_err(ListSecretsError::Load)
        .map_err(|err| {
            reporter.report(ctx, ListSecretsEvent::Error(&err));
            vec![err]
        })?;
    let mut errors = Vec::new();

    let secrets: Vec<_> = if secret_names.is_empty() {
        Either::Left(state.secrets.keys().map(String::as_str))
    } else {
        Either::Right(secret_names.into_iter().map(AsRef::as_ref))
    }
    .filter_map(|name| {
        Secret::find(name, &state)
            .map_err(|source| ListSecretsError::FindSecret {
                secret_name: name.to_string(),
                source,
            })
            .map_err(|err| {
                reporter.report(ctx, ListSecretsEvent::Error(&err));
                errors.push(err);
            })
            .ok()
    })
    .filter(|secret| tags.is_empty() || has_intersection(tags, &secret.data.tags))
    .collect();

    if !errors.is_empty() {
        return Err(errors);
    }

    if secrets.is_empty() {
        reporter.report(ctx, ListSecretsEvent::NoMatchingSecrets);
    }

    for secret in secrets {
        reporter.report(ctx, ListSecretsEvent::Secret(&secret));
    }

    Ok(())
}

#[derive(thiserror::Error, Debug)]
pub enum ListSecretRefsError {
    #[error(transparent)]
    Load(#[from] LoadStateError),

    #[error("Failed to find secret {}", NameMarker(&secret_name))]
    FindSecret {
        secret_name: String,
        #[source]
        source: FindSecretError,
    },

    #[error("Failed to find host {}", NameMarker(&host_name))]
    FindHost {
        host_name: String,
        #[source]
        source: FindHostError,
    },

    #[error("Failed to find jail {}", NameMarker(&jail_name))]
    FindJail {
        jail_name: String,
        #[source]
        source: FindJailError,
    },

    #[error("Failed to find secret reference for host {}", NameMarker(&host_name))]
    HostNoRef {
        host_name: String,
        #[source]
        source: FindSecretRefError,
    },

    #[error("Failed to find secret reference for jail {}", NameMarker(&jail_name))]
    JailNoRef {
        jail_name: String,
        #[source]
        source: FindSecretRefError,
    },
}

pub enum ListSecretRefsEvent<'a> {
    HostRef {
        host: &'a Host<'a>,
        secret_ref: &'a SecretRef<'a>,
    },

    JailRef {
        jail: &'a Jail<'a>,
        secret_ref: &'a SecretRef<'a>,
    },

    Error(&'a ListSecretRefsError),

    NoMatchingSecrets,
}

pub fn list_secret_refs<C: Ctx>(
    secret_names: &[impl AsRef<str>],
    host_names: &[impl AsRef<str>],
    jail_names: &[impl AsRef<str>],
    tags: &[impl AsRef<str>],
    ctx: &mut C,
    mut reporter: impl for<'a> Reporter<C, ListSecretRefsEvent<'a>>,
) -> Result<(), Vec<ListSecretRefsError>> {
    let state = load_state(false, ctx)
        .map_err(ListSecretRefsError::Load)
        .map_err(|err| {
            reporter.report(ctx, ListSecretRefsEvent::Error(&err));
            vec![err]
        })?;
    let mut errors = Vec::new();

    let secrets: Vec<_> = if secret_names.is_empty() {
        Either::Left(state.secrets.keys().map(String::as_str))
    } else {
        Either::Right(secret_names.into_iter().map(AsRef::as_ref))
    }
    .filter_map(|name| {
        Secret::find(name, &state)
            .map_err(|source| ListSecretRefsError::FindSecret {
                secret_name: name.to_string(),
                source,
            })
            .map_err(|err| {
                reporter.report(ctx, ListSecretRefsEvent::Error(&err));
                errors.push(err);
            })
            .ok()
    })
    .filter(|secret| tags.is_empty() || has_intersection(tags, &secret.data.tags))
    .collect();

    let hosts: Vec<_> = if host_names.is_empty() {
        Either::Left(state.hosts.keys().map(String::as_str))
    } else {
        Either::Right(host_names.into_iter().map(AsRef::as_ref))
    }
    .filter_map(|name| {
        Host::find(name, &state)
            .map_err(|source| ListSecretRefsError::FindHost {
                host_name: name.to_string(),
                source,
            })
            .map_err(|err| {
                reporter.report(ctx, ListSecretRefsEvent::Error(&err));
                errors.push(err);
            })
            .ok()
    })
    .collect();

    let jails: Vec<_> = if jail_names.is_empty() {
        Either::Left(state.jails.keys().map(String::as_str))
    } else {
        Either::Right(jail_names.into_iter().map(AsRef::as_ref))
    }
    .filter_map(|name| {
        Jail::find(name, &state)
            .map_err(|source| ListSecretRefsError::FindJail {
                jail_name: name.to_string(),
                source,
            })
            .map_err(|err| {
                reporter.report(ctx, ListSecretRefsEvent::Error(&err));
                errors.push(err);
            })
            .ok()
    })
    .collect();

    if !errors.is_empty() {
        return Err(errors);
    }

    let mut found_at_least_one = false;

    for host in hosts {
        for secret in &secrets {
            match SecretRef::find_for_host(host, secret) {
                Ok(secret_ref) => {
                    found_at_least_one = true;
                    reporter.report(
                        ctx,
                        ListSecretRefsEvent::HostRef {
                            host: &host,
                            secret_ref: &secret_ref,
                        },
                    );
                }
                Err(FindSecretRefError::NotFound { .. }) => {
                    continue;
                }
                Err(source) => {
                    let err = ListSecretRefsError::HostNoRef {
                        host_name: host.name.to_string(),
                        source,
                    };
                    reporter.report(ctx, ListSecretRefsEvent::Error(&err));
                    errors.push(err);
                    continue;
                }
            };
        }
    }

    for jail in jails {
        for secret in &secrets {
            match SecretRef::find_for_jail(jail, secret) {
                Ok(secret_ref) => {
                    found_at_least_one = true;
                    reporter.report(
                        ctx,
                        ListSecretRefsEvent::JailRef {
                            jail: &jail,
                            secret_ref: &secret_ref,
                        },
                    );
                }
                Err(FindSecretRefError::NotFound { .. }) => {
                    continue;
                }
                Err(source) => {
                    let err = ListSecretRefsError::JailNoRef {
                        jail_name: jail.name.to_string(),
                        source,
                    };
                    reporter.report(ctx, ListSecretRefsEvent::Error(&err));
                    errors.push(err);
                    continue;
                }
            };
        }
    }

    if !found_at_least_one {
        reporter.report(ctx, ListSecretRefsEvent::NoMatchingSecrets);
    }

    if !errors.is_empty() {
        Err(errors)
    } else {
        Ok(())
    }
}

#[derive(thiserror::Error, Debug)]
pub enum RekeySecretsError {
    #[error(transparent)]
    List(#[from] ListSecretRefsError),

    #[error("Failed to rekey secret for host {}", NameMarker(&host_name))]
    HostRekey {
        host_name: String,
        #[source]
        source: RekeySecretRefError,
    },

    #[error("Failed to rekey secret for jail {}", NameMarker(&jail_name))]
    JailRekey {
        jail_name: String,
        #[source]
        source: RekeySecretRefError,
    },

    #[error(transparent)]
    Write(#[from] WriteSecretError),
}

pub enum RekeySecretsEvent<'a> {
    NoMatchingSecrets,

    HostRefSkipped {
        host: &'a Host<'a>,
        secret_ref: &'a SecretRef<'a>,
    },

    HostRefRekeyed {
        host: &'a Host<'a>,
        secret_ref: &'a SecretRef<'a>,
    },

    JailRefSkipped {
        jail: &'a Jail<'a>,
        secret_ref: &'a SecretRef<'a>,
    },

    JailRefRekeyed {
        jail: &'a Jail<'a>,
        secret_ref: &'a SecretRef<'a>,
    },

    ListError(&'a ListSecretRefsError),

    Error(&'a RekeySecretsError),
}

pub fn rekey_secrets<C: Ctx>(
    secret_names: &[impl AsRef<str>],
    host_names: &[impl AsRef<str>],
    jail_names: &[impl AsRef<str>],
    tags: &[impl AsRef<str>],
    force: Option<bool>,
    add_to_git: Option<bool>,
    ctx: &mut C,
    mut reporter: impl for<'s> Reporter<C, RekeySecretsEvent<'s>>,
) -> Result<(), impl Iterator<Item = RekeySecretsError>> {
    let mut errors = Vec::new();

    let list_reporter = |ctx: &mut C, event: ListSecretRefsEvent<'_>| match event {
        ListSecretRefsEvent::HostRef { host, secret_ref } => {
            match secret_ref.rekey(force, add_to_git, ctx) {
                Ok(true) => reporter.report(
                    ctx,
                    RekeySecretsEvent::HostRefRekeyed {
                        host: &host,
                        secret_ref: &secret_ref,
                    },
                ),
                Ok(false) => reporter.report(
                    ctx,
                    RekeySecretsEvent::HostRefSkipped {
                        host: &host,
                        secret_ref: &secret_ref,
                    },
                ),
                Err(source) => {
                    let err = RekeySecretsError::HostRekey {
                        host_name: host.name.to_string(),
                        source,
                    };
                    reporter.report(ctx, RekeySecretsEvent::Error(&err));
                    errors.push(err);
                }
            }
        }
        ListSecretRefsEvent::JailRef { jail, secret_ref } => {
            match secret_ref.rekey(force, add_to_git, ctx) {
                Ok(true) => reporter.report(
                    ctx,
                    RekeySecretsEvent::JailRefRekeyed {
                        jail: &jail,
                        secret_ref: &secret_ref,
                    },
                ),
                Ok(false) => reporter.report(
                    ctx,
                    RekeySecretsEvent::JailRefSkipped {
                        jail: &jail,
                        secret_ref: &secret_ref,
                    },
                ),
                Err(source) => {
                    let err = RekeySecretsError::JailRekey {
                        jail_name: jail.name.to_string(),
                        source,
                    };
                    reporter.report(ctx, RekeySecretsEvent::Error(&err));
                    errors.push(err);
                }
            }
        }
        ListSecretRefsEvent::NoMatchingSecrets => {
            reporter.report(ctx, RekeySecretsEvent::NoMatchingSecrets);
        }
        ListSecretRefsEvent::Error(err) => {
            reporter.report(ctx, RekeySecretsEvent::ListError(err));
        }
    };

    let Err(list_errors) = list_secret_refs(
        secret_names,
        host_names,
        jail_names,
        tags,
        ctx,
        list_reporter,
    ) else {
        return Ok(());
    };

    Err(list_errors
        .into_iter()
        .map(RekeySecretsError::List)
        .chain(errors))
}
