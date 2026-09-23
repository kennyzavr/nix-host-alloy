use std::sync::Arc;

use crate::domain::{
    models::{JailRecord, State},
    ports::{self, NixEvaluator},
};

#[derive(Debug, thiserror::Error)]
pub enum GetError {
    #[error("Failed to load state")]
    Nix(#[from] ports::NixError),

    #[error(transparent)]
    NotFound(#[from] NotFoundError),
}

#[derive(thiserror::Error, Debug)]
#[error("Jail `{name}` not found")]
pub struct NotFoundError {
    pub name: String,
}

pub struct Service {
    pub nix: Arc<dyn NixEvaluator>,
}

impl Service {
    pub fn find(&self, name: String) -> Result<JailRecord, GetError> {
        let mut state = self.nix.load_state()?;

        let host = state
            .jails
            .remove(&name)
            .map(|state| JailRecord {
                name: name.clone(),
                state,
            })
            .ok_or_else(|| NotFoundError { name: name })?;

        Ok(host)
    }
}
