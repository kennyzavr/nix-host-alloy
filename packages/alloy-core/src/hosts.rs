use crate::{NotDefinedError, models};

#[derive(Debug, Clone, Copy)]
pub struct Entity<'s> {
    pub name: &'s str,
    pub data: &'s models::Host,
    _priv: (),
}

pub fn find<'s>(state: &'s models::State, name: &'s str) -> Result<Entity<'s>, NotDefinedError> {
    state
        .hosts
        .get(name)
        .map(|data| Entity {
            name,
            data,
            _priv: (),
        })
        .ok_or(NotDefinedError)
}

pub fn find_all<'s>(state: &'s models::State) -> impl IntoIterator<Item = Entity<'s>> {
    state.hosts.iter().map(|(name, data)| Entity {
        name,
        data,
        _priv: (),
    })
}
