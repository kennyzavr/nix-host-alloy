use std::collections::{HashMap, HashSet};

use either::Either;

use crate::domain::{
    NameMarker,
    facts::{Fact, FindFactError, ReadFactError, WriteFactError},
    models::{self},
    ports::{Ctx, Reporter},
    state::{LoadStateError, load_state},
};

#[derive(Debug, Clone, Copy)]
pub struct Index<'s> {
    pub name: &'s str,
    pub data: &'s models::Index,
    pub(crate) fact: Fact<'s>,
    _priv: (),
}

#[derive(thiserror::Error, Debug)]
pub enum FindIndexError {
    #[error("Not found")]
    NotFound,

    #[error("Asociated fact {} not found", NameMarker(fact_name))]
    FactNotDefined {
        fact_name: String,
        #[source]
        source: FindFactError,
    },
}

#[derive(thiserror::Error, Debug)]
pub enum ReadIndexError {
    #[error("Failed to read associated fact")]
    ReadFact(#[from] ReadFactError),

    #[error("Failed to parse JSON state")]
    Parse(#[from] serde_json::Error),

    #[error("Index state corrupted: {reason}")]
    Corrupted { reason: String },
}

#[derive(thiserror::Error, Debug)]
pub enum AllocIndexError {
    #[error("Index has no evaluated keys")]
    NoKeys,

    #[error(transparent)]
    Read(#[from] ReadIndexError),

    #[error("Failed to write associated fact")]
    WriteFact(#[from] WriteFactError),

    #[error("Failed to allocate the index: need {needed} values, min {min}, max {max}")]
    AllocationFailed { needed: usize, min: u64, max: u64 },

    #[error("Failed to serialize state to json")]
    Serialize(#[from] serde_json::Error),
}

impl<'s> Index<'s> {
    pub fn fact(&self) -> &Fact<'s> {
        &self.fact
    }

    pub fn find(name: &'s str, state: &'s models::State) -> Result<Self, FindIndexError> {
        let data = state.indexes.get(name).ok_or(FindIndexError::NotFound)?;
        let fact = Fact::find(&data.fact_name, state).map_err(|source| {
            FindIndexError::FactNotDefined {
                fact_name: data.fact_name.clone(),
                source,
            }
        })?;

        Ok(Self {
            name,
            data,
            fact,
            _priv: (),
        })
    }

    pub fn read(&self, ctx: &dyn Ctx) -> Result<HashMap<String, u64>, ReadIndexError> {
        let raw_data = self.fact.read(ctx)?;

        let parsed: HashMap<String, u64> = serde_json::from_str(&raw_data)?;

        let mut state = HashMap::new();
        let mut seen_values = HashSet::new();

        for (k, val) in parsed {
            if val < self.data.min_value || val > self.data.max_value {
                return Err(ReadIndexError::Corrupted {
                    reason: format!(
                        "value {} for key {} is out of bounds [{}, {}]",
                        val,
                        NameMarker(&k),
                        self.data.min_value,
                        self.data.max_value
                    ),
                });
            }

            if !seen_values.insert(val) {
                return Err(ReadIndexError::Corrupted {
                    reason: format!("duplicate value {} found for key {}", val, NameMarker(&k)),
                });
            }

            state.insert(k, val);
        }

        Ok(state)
    }

    pub fn alloc(
        &self,
        force: Option<bool>,
        add_to_git: Option<bool>,
        ctx: &dyn Ctx,
    ) -> Result<(HashMap<String, u64>, bool), AllocIndexError> {
        let force = force.or(ctx.env().force).unwrap_or(false);

        let Some(keys) = self.data.keys.as_ref() else {
            return Err(AllocIndexError::NoKeys);
        };

        let (existing_state, file_exists) = if force {
            (HashMap::new(), false)
        } else {
            match self.read(ctx) {
                Ok(data) => (data, true),
                Err(ReadIndexError::ReadFact(ReadFactError::FsRead(_))) => (HashMap::new(), false),
                Err(ReadIndexError::Parse(_)) if force => (HashMap::new(), true),
                Err(source) => {
                    return Err(AllocIndexError::Read(source));
                }
            }
        };

        let mut current_state: HashMap<String, u64> = existing_state
            .iter()
            .filter(|(k, _)| keys.contains(k.as_str()))
            .map(|(k, v)| (k.clone(), *v))
            .collect();

        let mut unallocated_keys: Vec<String> = keys
            .iter()
            .filter(|k| !current_state.contains_key(k.as_str()))
            .cloned()
            .collect();
        unallocated_keys.sort();

        let needed = unallocated_keys.len();
        if needed > 0 {
            let mut available_values =
                self.compute_allocations(current_state.values().copied(), needed)?;
            for k in unallocated_keys {
                current_state.insert(k, available_values.remove(0));
            }
        }

        let changed = current_state != existing_state || !file_exists;

        if changed {
            let json_data = serde_json::to_string_pretty(&current_state)?;
            self.fact.write(&json_data, Some(true), add_to_git, ctx)?;
        }

        Ok((current_state, changed))
    }

    fn compute_allocations(
        &self,
        used_values: impl Iterator<Item = u64>,
        needed: usize,
    ) -> Result<Vec<u64>, AllocIndexError> {
        let mut used_sorted: Vec<u64> = used_values.collect();
        used_sorted.sort_unstable();

        let mut available_values = Vec::with_capacity(needed);
        let mut candidate = self.data.min_value;

        for used_val in used_sorted {
            if available_values.len() >= needed {
                break;
            }
            while candidate < used_val
                && available_values.len() < needed
                && candidate <= self.data.max_value
            {
                available_values.push(candidate);
                candidate += 1;
            }
            candidate = candidate.max(used_val.saturating_add(1));
        }

        while available_values.len() < needed && candidate <= self.data.max_value {
            available_values.push(candidate);
            candidate += 1;
        }

        if available_values.len() < needed {
            return Err(AllocIndexError::AllocationFailed {
                needed,
                min: self.data.min_value,
                max: self.data.max_value,
            });
        }

        Ok(available_values)
    }
}

#[derive(thiserror::Error, Debug)]
pub enum AllocIndexesError {
    #[error(transparent)]
    Load(#[from] LoadStateError),

    #[error("Failed to find index {}", NameMarker(&index_name))]
    FindIndex {
        index_name: String,
        #[source]
        source: FindIndexError,
    },

    #[error("Failed to allocate index {}", NameMarker(&index_name))]
    Alloc {
        index_name: String,
        #[source]
        source: AllocIndexError,
    },
}

pub enum AllocIndexesEvent<'a> {
    IndexAllocated {
        index_name: &'a str,
        values: &'a HashMap<String, u64>,
    },
    IndexSkipped {
        index_name: &'a str,
        values: &'a HashMap<String, u64>,
    },
    Error(&'a AllocIndexesError),
}

pub fn alloc_indexes<C: Ctx>(
    index_names: &[impl AsRef<str>],
    force: Option<bool>,
    add_to_git: Option<bool>,
    ctx: &mut C,
    mut reporter: impl for<'a> Reporter<C, AllocIndexesEvent<'a>>,
) -> Result<(), Vec<AllocIndexesError>> {
    let state = load_state(false, ctx)
        .map_err(AllocIndexesError::Load)
        .map_err(|err| {
            reporter.report(ctx, AllocIndexesEvent::Error(&err));
            vec![err]
        })?;
    let mut errors = Vec::new();

    let indexes: Vec<_> = if index_names.is_empty() {
        Either::Left(state.indexes.keys().map(String::as_str))
    } else {
        Either::Right(index_names.into_iter().map(AsRef::as_ref))
    }
    .filter_map(|name| {
        Index::find(name, &state)
            .map_err(|source| AllocIndexesError::FindIndex {
                index_name: name.to_string(),
                source,
            })
            .map_err(|err| {
                reporter.report(ctx, AllocIndexesEvent::Error(&err));
                errors.push(err);
            })
            .ok()
    })
    .collect();

    if !errors.is_empty() {
        return Err(errors);
    }

    for index in indexes {
        if index.data.keys.is_none() {
            let _ = ctx.nix().trigger_assertions(ctx.env().into());

            let err = AllocIndexesError::Alloc {
                index_name: index.name.to_string(),
                source: AllocIndexError::NoKeys,
            };

            reporter.report(ctx, AllocIndexesEvent::Error(&err));
            errors.push(err);
            continue;
        }

        let (values, changed) = match index.alloc(force, add_to_git, ctx) {
            Ok(v) => v,
            Err(source) => {
                let err = AllocIndexesError::Alloc {
                    index_name: index.name.to_string(),
                    source,
                };

                reporter.report(ctx, AllocIndexesEvent::Error(&err));
                errors.push(err);
                continue;
            }
        };

        reporter.report(
            ctx,
            if changed {
                AllocIndexesEvent::IndexAllocated {
                    index_name: index.name,
                    values: &values,
                }
            } else {
                AllocIndexesEvent::IndexSkipped {
                    index_name: index.name,
                    values: &values,
                }
            },
        );
    }

    if !errors.is_empty() {
        Err(errors)
    } else {
        Ok(())
    }
}

#[derive(thiserror::Error, Debug)]
pub enum ShowIndexError {
    #[error(transparent)]
    Load(#[from] LoadStateError),

    #[error("Failed to find index {}", NameMarker(&index_name))]
    FindIndex {
        index_name: String,
        #[source]
        source: FindIndexError,
    },
}

pub enum ShowIndexEvent<'a> {
    Index(&'a Index<'a>),
    Error(&'a ShowIndexError),
}

pub fn show_index<C: Ctx>(
    index_name: &str,
    ctx: &mut C,
    mut reporter: impl for<'a> Reporter<C, ShowIndexEvent<'a>>,
) -> Result<(), ShowIndexError> {
    let state = load_state(false, ctx)
        .map_err(ShowIndexError::Load)
        .map_err(|err| {
            reporter.report(ctx, ShowIndexEvent::Error(&err));
            err
        })?;

    match Index::find(index_name, &state).map_err(|source| ShowIndexError::FindIndex {
        index_name: index_name.to_string(),
        source,
    }) {
        Ok(index) => {
            reporter.report(ctx, ShowIndexEvent::Index(&index));
            Ok(())
        }
        Err(err) => {
            reporter.report(ctx, ShowIndexEvent::Error(&err));
            Err(err)
        }
    }
}

#[derive(thiserror::Error, Debug)]
pub enum ListIndexesError {
    #[error(transparent)]
    Load(#[from] LoadStateError),

    #[error("Failed to find index {}", NameMarker(&index_name))]
    FindIndex {
        index_name: String,
        #[source]
        source: FindIndexError,
    },
}

pub enum ListIndexesEvent<'a> {
    Index(&'a Index<'a>),

    Error(&'a ListIndexesError),

    NoMatchingIndexes,
}

pub fn list_indexes<C: Ctx>(
    index_names: &[impl AsRef<str>],
    ctx: &mut C,
    mut reporter: impl for<'a> Reporter<C, ListIndexesEvent<'a>>,
) -> Result<(), Vec<ListIndexesError>> {
    let state = load_state(false, ctx)
        .map_err(ListIndexesError::Load)
        .map_err(|err| {
            reporter.report(ctx, ListIndexesEvent::Error(&err));
            vec![err]
        })?;
    let mut errors = Vec::new();

    let indexes: Vec<_> = if index_names.is_empty() {
        Either::Left(state.indexes.keys().map(String::as_str))
    } else {
        Either::Right(index_names.into_iter().map(AsRef::as_ref))
    }
    .filter_map(|name| {
        Index::find(name, &state)
            .map_err(|source| ListIndexesError::FindIndex {
                index_name: name.to_string(),
                source,
            })
            .map_err(|err| {
                reporter.report(ctx, ListIndexesEvent::Error(&err));
                errors.push(err);
            })
            .ok()
    })
    .collect();

    if !errors.is_empty() {
        return Err(errors);
    }

    if indexes.is_empty() {
        reporter.report(ctx, ListIndexesEvent::NoMatchingIndexes);
    }

    for index in indexes {
        reporter.report(ctx, ListIndexesEvent::Index(&index));
    }

    Ok(())
}

#[derive(thiserror::Error, Debug)]
pub enum GetIndexValueError {
    #[error(transparent)]
    Load(#[from] LoadStateError),

    #[error("Failed to find index {}", NameMarker(&index_name))]
    FindIndex {
        index_name: String,
        #[source]
        source: FindIndexError,
    },

    #[error(transparent)]
    Read(#[from] ReadIndexError),
}

pub enum GetIndexValueEvent<'a> {
    ValueRead {
        index: &'a Index<'a>,
        values: &'a HashMap<String, u64>,
    },
    Error(&'a GetIndexValueError),
}

pub fn get_index_value<C: Ctx>(
    index_name: &str,
    ctx: &mut C,
    mut reporter: impl for<'a> Reporter<C, GetIndexValueEvent<'a>>,
) -> Result<HashMap<String, u64>, GetIndexValueError> {
    ((|| -> Result<_, _> {
        let state = load_state(false, ctx)
            .map_err(GetIndexValueError::Load)
            .map_err(|err| {
                reporter.report(ctx, GetIndexValueEvent::Error(&err));
                err
            })?;
        let index =
            Index::find(index_name, &state).map_err(|source| GetIndexValueError::FindIndex {
                index_name: index_name.to_string(),
                source,
            })?;
        let data = index.read(&*ctx)?;
        reporter.report(
            ctx,
            GetIndexValueEvent::ValueRead {
                index: &index,
                values: &data,
            },
        );

        Ok(data)
    })())
    .inspect_err(|err| {
        reporter.report(ctx, GetIndexValueEvent::Error(&err));
    })
}
