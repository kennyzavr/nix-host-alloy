use crate::ctx::Ctx;
use crate::{DynError, NotDefinedError, models};

#[derive(Debug, Clone, Copy)]
pub struct Entity<'s> {
    pub name: &'s str,
    pub data: &'s models::Fact,
    _priv: (),
}

#[derive(thiserror::Error, Debug)]
pub enum FindError {
    #[error(transparent)]
    NotDefined(#[from] NotDefinedError),
}

pub fn find<'s>(state: &'s models::State, name: &'s str) -> Result<Entity<'s>, FindError> {
    let data = state.facts.get(name).ok_or(NotDefinedError)?;
    Ok(Entity {
        name,
        data,
        _priv: (),
    })
}

pub fn find_all<'s>(state: &'s models::State) -> impl Iterator<Item = Entity<'s>> {
    state.facts.iter().map(|(name, data)| Entity {
        name,
        data,
        _priv: (),
    })
}

pub fn exists(ctx: &dyn Ctx, fact: Entity<'_>) -> bool {
    ctx.fs().exists(&fact.data.file)
}

#[derive(Debug, thiserror::Error)]
pub enum ReadError {
    #[error("Failed to read fact file")]
    FsRead(#[source] DynError),

    #[error("Fact file contains invalid UTF-8")]
    Utf8(#[source] std::string::FromUtf8Error),
}

pub fn read(ctx: &dyn Ctx, fact: Entity<'_>) -> Result<String, ReadError> {
    let data = ctx.fs().read(&fact.data.file).map_err(ReadError::FsRead)?;
    String::from_utf8(data).map_err(ReadError::Utf8)
}

#[derive(Debug, thiserror::Error)]
pub enum WriteError {
    #[error("Failed to write to fact file")]
    FsWrite(#[source] DynError),
}

pub fn write(
    ctx: &dyn Ctx,
    fact: Entity<'_>,
    value: String,
    force: bool,
    add_to_git: bool,
) -> Result<(), WriteError> {
    ctx.fs()
        .write(&fact.data.file, value.as_bytes(), force, add_to_git)
        .map_err(WriteError::FsWrite)?;

    Ok(())
}
