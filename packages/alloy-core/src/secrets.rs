use crate::{DynError, NameMark, NotDefinedError, ctx::Ctx, hosts, jails, models};

#[derive(Debug, Clone, Copy)]
pub struct Entity<'s> {
    pub name: &'s str,
    pub data: &'s models::Secret,
    pub age_keys: &'s [models::AgeKeyPair],
    _priv: (),
}

#[derive(Debug, Clone, Copy)]
pub struct RefEntity<'s> {
    pub master: Entity<'s>,
    pub data: &'s models::SecretRef,
    pub age_keys: &'s [models::AgeKeyPair],
    _priv: (),
}

#[derive(thiserror::Error, Debug)]
pub enum FindError {
    #[error(transparent)]
    NotDefined(#[from] NotDefinedError),

    #[error("No master age keys defined")]
    NoKeys,
}

pub fn find<'s>(state: &'s models::State, name: &'s str) -> Result<Entity<'s>, FindError> {
    let data = state.secrets.get(name).ok_or(NotDefinedError)?;
    let age_keys = &state.secrets_age_key_pairs;

    if age_keys.is_empty() {
        return Err(FindError::NoKeys);
    }

    Ok(Entity {
        name,
        data,
        age_keys,
        _priv: (),
    })
}

#[derive(thiserror::Error, Debug)]
pub enum FindAllError {
    #[error("No master age keys defined")]
    NoKeys,
}

pub fn find_all<'s>(
    state: &'s models::State,
) -> impl IntoIterator<Item = Result<Entity<'s>, FindAllError>> {
    state
        .secrets
        .iter()
        .map(move |(name, data)| -> Result<_, _> {
            let age_keys = &state.secrets_age_key_pairs;
            if age_keys.is_empty() {
                return Err(FindAllError::NoKeys);
            }

            Ok(Entity {
                name,
                data,
                age_keys,
                _priv: (),
            })
        })
        .take_while(|r| !matches!(r, Err(FindAllError::NoKeys)))
}

#[derive(thiserror::Error, Debug)]
pub enum FindRefError<'s> {
    #[error(transparent)]
    NotDefined(#[from] NotDefinedError),

    #[error("No age keys defined for host {}", NameMark(host_name))]
    NoKeys { host_name: &'s str },
}

pub fn find_host_ref<'s>(
    host: hosts::Entity<'s>,
    master: Entity<'s>,
) -> Result<RefEntity<'s>, FindRefError<'s>> {
    let data = host.data.secrets.get(master.name).ok_or(NotDefinedError)?;
    let age_keys = &host.data.secrets_age_key_pairs;

    if age_keys.is_empty() {
        return Err(FindRefError::NoKeys {
            host_name: host.name,
        })?;
    }

    Ok(RefEntity {
        master,
        data,
        age_keys,
        _priv: (),
    })
}

pub fn find_jail_ref<'s>(
    jail: jails::Entity<'s>,
    master: Entity<'s>,
) -> Result<RefEntity<'s>, FindRefError<'s>> {
    let data = jail.data.secrets.get(master.name).ok_or(NotDefinedError)?;
    let age_keys = &jail.host.data.secrets_age_key_pairs;

    if age_keys.is_empty() {
        return Err(FindRefError::NoKeys {
            host_name: jail.data.host.as_str(),
        })?;
    }

    Ok(RefEntity {
        master,
        data,
        age_keys,
        _priv: (),
    })
}

pub fn exists_ref(ctx: &dyn Ctx, secret_ref: RefEntity<'_>) -> bool {
    ctx.fs().exists(&secret_ref.data.file)
}

pub fn exists(ctx: &dyn Ctx, secret: Entity<'_>) -> bool {
    ctx.fs().exists(&secret.data.file)
}

#[derive(thiserror::Error, Debug)]
pub enum ReadError {
    #[error("Failed to read master secret file")]
    FsRead(#[source] DynError),

    #[error("Failed to dencrypt master secret data")]
    AgeDecrypt(#[source] DynError),
}

pub fn read(ctx: &dyn Ctx, entity: Entity<'_>) -> Result<Vec<u8>, ReadError> {
    log::debug!("Reading secret file: {}", entity.data.file.display());
    let encrypted_data = ctx
        .fs()
        .read(&entity.data.file)
        .map_err(ReadError::FsRead)?;

    let mut identities = entity.age_keys.iter().map(|k| &k.identity);
    let data = ctx
        .age()
        .decrypt(&mut identities, &encrypted_data)
        .map_err(ReadError::AgeDecrypt)?;

    Ok(data)
}

#[derive(thiserror::Error, Debug)]
pub enum WriteError {
    #[error("Failed to write master secret file")]
    FsWrite(#[source] DynError),

    #[error("Failed to encrypt master secret data")]
    AgeEncrypt(#[source] DynError),
}

pub fn write(
    ctx: &dyn Ctx,
    entity: Entity<'_>,
    data: Vec<u8>,
    force: bool,
    add_to_git: bool,
) -> Result<Vec<u8>, WriteError> {
    log::debug!("Encrypting and writing secret file: {}", entity.data.file.display());
    let mut recipients = entity.age_keys.iter().map(|k| &k.recipient);
    let encrypted_data = ctx
        .age()
        .encrypt(&mut recipients, &data)
        .map_err(WriteError::AgeEncrypt)?;

    ctx.fs()
        .write(&entity.data.file, &encrypted_data, force, add_to_git)
        .map_err(WriteError::FsWrite)?;

    Ok(data)
}

#[derive(thiserror::Error, Debug)]
pub enum RekeyRefError {
    #[error(transparent)]
    MasterRead(#[from] ReadError),

    #[error("Failed to encrypt secret ref data")]
    AgeEncrypt(#[source] DynError),

    #[error("Failed to write secret file")]
    FsWrite(#[source] DynError),
}

pub fn rekey_ref(
    ctx: &dyn Ctx,
    ref_entity: RefEntity<'_>,
    force: bool,
    add_to_git: bool,
) -> Result<(), RekeyRefError> {
    let data = read(ctx, ref_entity.master)?;

    let mut recipients = ref_entity.age_keys.iter().map(|k| &k.recipient);
    let encrypted_data = ctx
        .age()
        .encrypt(&mut recipients, &data)
        .map_err(RekeyRefError::AgeEncrypt)?;

    ctx.fs()
        .write(&ref_entity.data.file, &encrypted_data, force, add_to_git)
        .map_err(RekeyRefError::FsWrite)?;

    Ok(())
}
