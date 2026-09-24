use std::collections::{HashMap, HashSet};

use crate::{NameMark, NotDefinedError, ctx::Ctx, facts, models};

#[derive(Debug, Clone, Copy)]
pub struct Entity<'s> {
    pub name: &'s str,
    pub data: &'s models::Index,
    pub fact: facts::Entity<'s>,
    _priv: (),
}

#[derive(thiserror::Error, Debug)]
pub enum FindError<'s> {
    #[error(transparent)]
    NotDefined(#[from] NotDefinedError),

    #[error("Asociated fact {} not found", NameMark(fact_name))]
    FactNotDefined {
        fact_name: &'s str,
        #[source]
        source: facts::FindError,
    },
}

pub fn find<'s>(state: &'s models::State, name: &'s str) -> Result<Entity<'s>, FindError<'s>> {
    let data = state.indexes.get(name).ok_or(NotDefinedError)?;
    let fact = facts::find(state, &data.fact_name).map_err(|source| FindError::FactNotDefined {
        fact_name: data.fact_name.as_str(),
        source,
    })?;

    Ok(Entity {
        name,
        data,
        fact,
        _priv: (),
    })
}

#[derive(thiserror::Error, Debug)]
pub enum FindAllError<'s> {
    #[error(
        "Asociated fact {} not found for index {}",
        NameMark(fact_name),
        NameMark(name)
    )]
    FactNotDefined {
        name: &'s str,
        fact_name: &'s str,
        #[source]
        source: facts::FindError,
    },

    #[error("Index {} has no evaluated keys", NameMark(name))]
    NoKeys { name: &'s str },
}

pub fn find_all<'s>(
    state: &'s models::State,
) -> impl IntoIterator<Item = Result<Entity<'s>, FindAllError<'s>>> {
    state
        .indexes
        .iter()
        .map(move |(name, data)| -> Result<_, _> {
            let fact = facts::find(state, &data.fact_name).map_err(|source| {
                FindAllError::FactNotDefined {
                    name: name.as_str(),
                    fact_name: data.fact_name.as_str(),
                    source,
                }
            })?;

            Ok(Entity {
                name,
                data,
                fact,
                _priv: (),
            })
        })
}

#[derive(thiserror::Error, Debug)]
pub enum AllocError {
    #[error("Index has no evaluated keys")]
    NoKeys,

    #[error("Failed to read associated fact")]
    ReadFact(#[from] facts::ReadError),

    #[error("Failed to write associated fact")]
    WriteFact(#[from] facts::WriteError),

    #[error("Failed to parse JSON state")]
    Parse(#[from] serde_json::Error),

    #[error("Index state corrupted: {reason}")]
    Corrupted { reason: String },

    #[error("Failed to allocate the index: need {needed} values, min {min}, max {max}")]
    AllocationFailed { needed: usize, min: u64, max: u64 },
}

pub struct AllocResult {
    pub changed: bool,
    pub size: usize,
}

pub fn alloc(
    ctx: &dyn Ctx,
    entity: Entity<'_>,
    reset: bool,
    add_to_git: bool,
) -> Result<AllocResult, AllocError> {
    let Some(keys) = entity.data.keys.as_ref() else {
        return Err(AllocError::NoKeys);
    };

    let (existing_state, file_exists) = read_state(ctx, entity, reset)?;

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
            compute_allocations(current_state.values().copied(), needed, entity)?;
        for k in unallocated_keys {
            current_state.insert(k, available_values.remove(0));
        }
    }

    if current_state == existing_state && file_exists {
        return Ok(AllocResult {
            changed: false,
            size: current_state.len(),
        });
    }

    let json_data = serde_json::to_string_pretty(&current_state)?;
    facts::write(ctx, entity.fact, json_data, true, add_to_git)?;

    Ok(AllocResult {
        changed: true,
        size: current_state.len(),
    })
}

fn read_state(
    ctx: &dyn Ctx,
    entity: Entity<'_>,
    reset: bool,
) -> Result<(HashMap<String, u64>, bool), AllocError> {
    let raw_data = match facts::read(ctx, entity.fact) {
        Ok(data) => data,
        Err(facts::ReadError::FsRead { .. }) => {
            return Ok((HashMap::new(), false));
        }
        Err(e) => {
            return Err(AllocError::ReadFact(e));
        }
    };

    let existing_state: Result<HashMap<String, u64>, AllocError> = (|| {
        let parsed: HashMap<String, u64> = serde_json::from_str(&raw_data)?;

        let mut state = HashMap::new();
        let mut seen_values = HashSet::new();

        for (k, val) in parsed {
            if val < entity.data.min_value || val > entity.data.max_value {
                return Err(AllocError::Corrupted {
                    reason: format!(
                        "value {} for key `{}` is out of bounds [{}, {}]",
                        val, k, entity.data.min_value, entity.data.max_value
                    ),
                });
            }
            if !seen_values.insert(val) {
                return Err(AllocError::Corrupted {
                    reason: format!("duplicate value {} found for key `{}`", val, k),
                });
            }
            state.insert(k, val);
        }
        Ok(state)
    })();

    match existing_state {
        Ok(state) => Ok((state, true)),
        Err(e) => {
            if reset {
                Ok((HashMap::new(), true))
            } else {
                Err(e)
            }
        }
    }
}

fn compute_allocations(
    used_values: impl Iterator<Item = u64>,
    needed: usize,
    entity: Entity<'_>,
) -> Result<Vec<u64>, AllocError> {
    let mut used_sorted: Vec<u64> = used_values.collect();
    used_sorted.sort_unstable();

    let mut available_values = Vec::with_capacity(needed);
    let mut candidate = entity.data.min_value;

    for used_val in used_sorted {
        if available_values.len() >= needed {
            break;
        }
        while candidate < used_val
            && available_values.len() < needed
            && candidate <= entity.data.max_value
        {
            available_values.push(candidate);
            candidate += 1;
        }
        candidate = candidate.max(used_val.saturating_add(1));
    }

    while available_values.len() < needed && candidate <= entity.data.max_value {
        available_values.push(candidate);
        candidate += 1;
    }

    if available_values.len() < needed {
        return Err(AllocError::AllocationFailed {
            needed,
            min: entity.data.min_value,
            max: entity.data.max_value,
        });
    }

    Ok(available_values)
}
