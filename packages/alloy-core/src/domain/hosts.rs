use crate::domain::models;

#[derive(Debug, Clone, Copy)]
pub struct Host<'s> {
    pub name: &'s str,
    pub data: &'s models::Host,
    _priv: (),
}

#[derive(thiserror::Error, Debug)]
pub enum FindHostError {
    #[error("Not found")]
    NotFound,
}

impl<'s> Host<'s> {
    pub fn find(name: &'s str, state: &'s models::State) -> Result<Host<'s>, FindHostError> {
        let data = state.hosts.get(name).ok_or(FindHostError::NotFound)?;
        Ok(Host {
            name,
            data,
            _priv: (),
        })
    }
}
