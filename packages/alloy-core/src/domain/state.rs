use crate::domain::{
    DynError,
    env::EnvStateSource,
    models,
    ports::{Ctx, NixBuildSpec},
};

#[derive(thiserror::Error, Debug)]
pub enum LoadStateError {
    #[error("Failed to load state from nix alloy config")]
    Nix(#[source] DynError),

    #[error("Failed to read state file")]
    FsRead(#[source] DynError),

    #[error("Failed to parse state")]
    Parse(#[from] serde_json::Error),
}

pub fn load_state(spec: NixBuildSpec, ctx: &mut dyn Ctx) -> Result<models::State, LoadStateError> {
    let env = ctx.env();

    let dir_path = match &ctx.env().state_source {
        Some(EnvStateSource {
            spec: curr_spec,
            dir_path,
        }) if spec == NixBuildSpec::default() || &spec == curr_spec => dir_path.clone(),
        _ => ctx
            .nix()
            .build(&spec, env.into())
            .map_err(LoadStateError::Nix)?,
    };

    let state = ctx
        .fs()
        .read(&dir_path.join("state.json"))
        .map_err(LoadStateError::FsRead)?;
    let state = serde_json::from_slice(&state)?;

    ctx.env_mut().state_source = Some(EnvStateSource { spec, dir_path });

    Ok(state)
}

pub fn reset_state(ctx: &mut dyn Ctx) {
    ctx.env_mut().state_source = None;
}
