use crate::domain::{DynError, env::EnvStateSource, models, ports::Ctx};

#[derive(thiserror::Error, Debug)]
pub enum LoadStateError {
    #[error("Failed to load state from nix alloy config")]
    Nix(#[source] DynError),

    #[error("Failed to read state file")]
    FsRead(#[source] DynError),

    #[error("Failed to parse state")]
    Parse(#[from] serde_json::Error),
}

pub fn load_state(full: bool, ctx: &mut dyn Ctx) -> Result<models::State, LoadStateError> {
    let env = ctx.env();

    let path = match &ctx.env().state_source {
        Some(EnvStateSource::Full(path)) if full => path.clone(),
        Some(EnvStateSource::Base(path)) if !full => path.clone(),
        _ => ctx
            .nix()
            .eval_state(full, env.into())
            .map_err(LoadStateError::Nix)?,
    };

    let data = ctx
        .fs()
        .read(&path.join("state.json"))
        .map_err(LoadStateError::FsRead)?;
    let state = serde_json::from_slice(&data)?;

    ctx.env_mut().state_source = Some(if full {
        EnvStateSource::Full(path)
    } else {
        EnvStateSource::Base(path)
    });

    Ok(state)
}

pub fn reset_state(ctx: &mut dyn Ctx) {
    ctx.env_mut().state_source = None;
}
