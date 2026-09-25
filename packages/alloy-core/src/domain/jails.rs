use crate::domain::{
    NameMarker,
    hosts::{FindHostError, Host},
    models,
};

#[derive(Debug, Clone, Copy)]
pub struct Jail<'s> {
    pub name: &'s str,
    pub data: &'s models::Jail,
    pub(crate) host: Host<'s>,
    _priv: (),
}

#[derive(thiserror::Error, Debug)]
pub enum FindJailError {
    #[error("Not found")]
    NotFound,

    #[error("Asociated host {} not found", NameMarker(&host_name))]
    HostNotFound {
        host_name: String,
        #[source]
        source: FindHostError,
    },
}

impl<'s> Jail<'s> {
    pub fn host(&self) -> &Host<'s> {
        &self.host
    }

    pub fn find(name: &'s str, state: &'s models::State) -> Result<Jail<'s>, FindJailError> {
        let data = state.jails.get(name).ok_or(FindJailError::NotFound)?;

        let host =
            Host::find(&data.host, &state).map_err(|source| FindJailError::HostNotFound {
                host_name: data.host.to_string(),
                source,
            })?;

        Ok(Jail {
            name,
            host,
            data,
            _priv: (),
        })
    }
}
