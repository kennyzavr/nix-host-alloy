use either::Either;

use crate::domain::{
    DynError, NameMarker, models,
    ports::{Ctx, Reporter},
    state::{LoadStateError, load_state},
};

#[derive(Debug, Clone, Copy)]
pub struct Fact<'s> {
    pub name: &'s str,
    pub data: &'s models::Fact,
    _priv: (),
}

#[derive(thiserror::Error, Debug)]
pub enum FindFactError {
    #[error("Not found")]
    NotFound,
}

#[derive(Debug, thiserror::Error)]
pub enum ReadFactError {
    #[error("Failed to read fact file")]
    FsRead(#[source] DynError),

    #[error("Fact file contains invalid UTF-8")]
    Utf8(#[source] std::string::FromUtf8Error),
}

#[derive(Debug, thiserror::Error)]
pub enum WriteFactError {
    #[error("Failed to write fact file")]
    FsWrite(#[source] DynError),

    #[error("Fact file not in git repo")]
    GitCheck(#[source] DynError),

    #[error("Failed to add fact file to git index")]
    GitAdd(#[source] DynError),
}

impl<'s> Fact<'s> {
    pub fn find(name: &'s str, state: &'s models::State) -> Result<Self, FindFactError> {
        let data = state.facts.get(name).ok_or(FindFactError::NotFound)?;
        Ok(Self {
            name,
            data,
            _priv: (),
        })
    }

    pub fn exists(&self, ctx: &dyn Ctx) -> bool {
        let path = ctx.env().workspace_root.join(&self.data.file);
        ctx.fs().exists(&path)
    }

    pub fn read(&self, ctx: &dyn Ctx) -> Result<String, ReadFactError> {
        let path = ctx.env().workspace_root.join(&self.data.file);

        let data = ctx.fs().read(&path).map_err(ReadFactError::FsRead)?;
        String::from_utf8(data).map_err(ReadFactError::Utf8)
    }

    pub fn write(
        &self,
        value: &str,
        force: Option<bool>,
        add_to_git: Option<bool>,
        ctx: &dyn Ctx,
    ) -> Result<(), WriteFactError> {
        let path = ctx.env().workspace_root.join(&self.data.file);
        let add_to_git = add_to_git.or(ctx.env().add_to_git).unwrap_or(false);
        let force = force.or(ctx.env().force).unwrap_or(false);

        ctx.fs()
            .mk_parent_dirs(&path)
            .map_err(WriteFactError::FsWrite)?;

        if add_to_git {
            ctx.git().check(&path).map_err(WriteFactError::GitCheck)?;
        }

        ctx.fs()
            .write(&path, &value.as_bytes(), force)
            .map_err(WriteFactError::FsWrite)?;

        if add_to_git {
            ctx.git().add(&path).map_err(WriteFactError::GitAdd)?;
        }

        Ok(())
    }
}

#[derive(thiserror::Error, Debug)]
pub enum GetFactValueError {
    #[error(transparent)]
    Load(#[from] LoadStateError),

    #[error(transparent)]
    Find(#[from] FindFactError),

    #[error(transparent)]
    Read(#[from] ReadFactError),
}

pub enum GetFactValueEvent<'a> {
    ValueRead(&'a Fact<'a>),

    Error(&'a GetFactValueError),
}

pub fn get_fact_value<C: Ctx>(
    name: &str,
    ctx: &mut C,
    mut reporter: impl for<'a> Reporter<C, GetFactValueEvent<'a>>,
) -> Result<String, GetFactValueError> {
    ((|| -> Result<_, _> {
        let state = load_state(false, ctx)?;
        let fact = Fact::find(name, &state)?;
        let data = fact.read(&*ctx)?;
        reporter.report(ctx, GetFactValueEvent::ValueRead(&fact));

        Ok(data)
    })())
    .inspect_err(|err| {
        reporter.report(ctx, GetFactValueEvent::Error(&err));
    })
}

#[derive(thiserror::Error, Debug)]
pub enum SetFactValueError {
    #[error(transparent)]
    Load(#[from] LoadStateError),

    #[error(transparent)]
    Find(#[from] FindFactError),

    #[error(transparent)]
    Write(#[from] WriteFactError),
}

pub enum SetFactValueEvent<'a> {
    ValueWritten(&'a Fact<'a>),

    Error(&'a SetFactValueError),
}

pub fn set_fact_value<C: Ctx>(
    name: &str,
    data: &str,
    force: Option<bool>,
    add_to_git: Option<bool>,
    ctx: &mut C,
    mut reporter: impl for<'a> Reporter<C, SetFactValueEvent<'a>>,
) -> Result<(), SetFactValueError> {
    ((|| -> Result<_, _> {
        let state = load_state(false, ctx)?;
        let fact = Fact::find(name, &state)?;
        fact.write(data, force, add_to_git, &*ctx)?;
        reporter.report(ctx, SetFactValueEvent::ValueWritten(&fact));
        Ok(())
    })())
    .inspect_err(|err| {
        reporter.report(ctx, SetFactValueEvent::Error(&err));
    })
}

#[derive(thiserror::Error, Debug)]
pub enum ShowFactError {
    #[error(transparent)]
    Load(#[from] LoadStateError),

    #[error("Failed to find fact {}", NameMarker(&fact_name))]
    FindFact {
        fact_name: String,
        #[source]
        source: FindFactError,
    },
}

pub enum ShowFactEvent<'a> {
    Fact(&'a Fact<'a>),

    Error(&'a ShowFactError),
}

pub fn show_fact<C: Ctx>(
    fact_name: &str,
    ctx: &mut C,
    mut reporter: impl for<'a> Reporter<C, ShowFactEvent<'a>>,
) -> Result<(), ShowFactError> {
    let state = load_state(false, ctx)?;

    match Fact::find(fact_name, &state).map_err(|source| ShowFactError::FindFact {
        fact_name: fact_name.to_string(),
        source,
    }) {
        Ok(fact) => {
            reporter.report(ctx, ShowFactEvent::Fact(&fact));
            Ok(())
        }
        Err(err) => {
            reporter.report(ctx, ShowFactEvent::Error(&err));
            Err(err)
        }
    }
}

#[derive(thiserror::Error, Debug)]
pub enum ListFactsError {
    #[error(transparent)]
    Load(#[from] LoadStateError),

    #[error("Failed to find fact {}", NameMarker(&fact_name))]
    FindFact {
        fact_name: String,
        #[source]
        source: FindFactError,
    },
}

pub enum ListFactsEvent<'a> {
    Fact(&'a Fact<'a>),

    Error(&'a ListFactsError),

    NoMatchingFacts,
}

fn has_intersection(slice: &[impl AsRef<str>], vec: &Vec<String>) -> bool {
    slice
        .iter()
        .any(|slice_item| vec.iter().any(|vec_item| vec_item == slice_item.as_ref()))
}

pub fn list_facts<C: Ctx>(
    fact_names: &[impl AsRef<str>],
    tags: &[impl AsRef<str>],
    ctx: &mut C,
    mut reporter: impl for<'a> Reporter<C, ListFactsEvent<'a>>,
) -> Result<(), Vec<ListFactsError>> {
    let mut errors = Vec::new();

    let state = load_state(false, ctx)
        .map_err(ListFactsError::Load)
        .map_err(|err| {
            reporter.report(ctx, ListFactsEvent::Error(&err));
            vec![err]
        })?;

    let facts: Vec<_> = if fact_names.is_empty() {
        Either::Left(state.facts.keys().map(String::as_str))
    } else {
        Either::Right(fact_names.into_iter().map(AsRef::as_ref))
    }
    .filter_map(|name| {
        Fact::find(name, &state)
            .map_err(|source| ListFactsError::FindFact {
                fact_name: name.to_string(),
                source,
            })
            .map_err(|err| {
                reporter.report(ctx, ListFactsEvent::Error(&err));
                errors.push(err);
            })
            .ok()
    })
    .filter(|fact| tags.is_empty() || has_intersection(tags, &fact.data.tags))
    .collect();

    if !errors.is_empty() {
        return Err(errors);
    }

    if facts.is_empty() {
        reporter.report(ctx, ListFactsEvent::NoMatchingFacts);
    }

    for fact in facts {
        reporter.report(ctx, ListFactsEvent::Fact(&fact));
    }

    Ok(())
}
