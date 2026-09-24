use crate::{NameMark, NotDefinedError, hosts, models};

#[derive(Debug, Clone, Copy)]
pub struct Entity<'s> {
    pub name: &'s str,
    pub data: &'s models::Jail,
    pub host: hosts::Entity<'s>,
    _priv: (),
}

#[derive(thiserror::Error, Debug)]
pub enum FindError<'s> {
    #[error(transparent)]
    NotDefined(#[from] NotDefinedError),

    #[error("Asociated host {} not found", NameMark(host_name))]
    HostNotDefined {
        host_name: &'s str,
        #[source]
        source: NotDefinedError,
    },
}

pub fn find<'s>(state: &'s models::State, name: &'s str) -> Result<Entity<'s>, FindError<'s>> {
    let data = state.jails.get(name).ok_or(NotDefinedError)?;
    let host = hosts::find(state, &data.host).map_err(|source| FindError::HostNotDefined {
        host_name: data.host.as_str(),
        source,
    })?;

    Ok(Entity {
        name,
        host,
        data,
        _priv: (),
    })
}

#[derive(thiserror::Error, Debug)]
pub enum FindAllError<'s> {
    #[error(
        "Asociated host {} not found found for jail {}",
        NameMark(host_name),
        NameMark(jail_name)
    )]
    HostNotDefined {
        jail_name: &'s str,
        host_name: &'s str,
        #[source]
        source: NotDefinedError,
    },
}

pub fn find_all<'s>(
    state: &'s models::State,
) -> impl Iterator<Item = Result<Entity<'s>, FindAllError<'s>>> {
    state.jails.iter().map(move |(name, data)| -> Result<_, _> {
        let host =
            hosts::find(state, &data.host).map_err(|source| FindAllError::HostNotDefined {
                jail_name: name.as_str(),
                host_name: data.host.as_str(),
                source,
            })?;

        Ok(Entity {
            name,
            data,
            host,
            _priv: (),
        })
    })
}
