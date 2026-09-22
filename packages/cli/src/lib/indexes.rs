use std::collections::{HashMap, HashSet};

use miette::Diagnostic;
use serde_json::Value;
use thiserror::Error;

use crate::lib::{
    facts, file,
    state::{IndexState, State},
    workspace,
};

#[derive(Error, Diagnostic, Debug)]
pub enum Error {
    #[error("Index not found")]
    #[diagnostic(
        code(alloy::indexes::not_found),
        help("Define the index in your nix configuration")
    )]
    NotFound,
    #[error(transparent)]
    #[diagnostic(transparent)]
    FactRead(#[from] facts::ReadError),
    #[error(transparent)]
    #[diagnostic(transparent)]
    FactWrite(#[from] facts::WriteError),
    #[error("Failed to parse index state")]
    #[diagnostic(code(alloy::indexes::parse))]
    Parse(#[from] serde_json::Error),
    #[error("Index state corrupted: {reason}")]
    #[diagnostic(code(alloy::indexes::corrupted))]
    Corrupted { reason: String },
    #[error("Failed to allocate index: need {needed} values, min {min}, max {max}")]
    #[diagnostic(code(alloy::indexes::allocation_failed))]
    AllocationFailed { needed: usize, min: u64, max: u64 },
}

pub struct AllocateResult {
    pub changed: bool,
    pub size: usize,
}

pub fn allocate(
    workspace: &workspace::Workspace,
    state: &State,
    name: &str,
    force: bool,
    add_to_git: bool,
) -> Result<AllocateResult, Error> {
    let Some((_, index)) = state
        .indexes
        .iter()
        .find(|(index_name, _)| name == **index_name)
    else {
        return Err(Error::NotFound);
    };

    let (existing_state, file_exists) = read_state(workspace, state, index, force)?;

    let mut current_state: HashMap<String, u64> = existing_state
        .iter()
        .filter(|(k, _)| index.keys.contains(k.as_str()))
        .map(|(k, v)| (k.clone(), *v))
        .collect();

    let mut unallocated_keys: Vec<String> = index
        .keys
        .iter()
        .filter(|k| !current_state.contains_key(k.as_str()))
        .cloned()
        .collect();
    unallocated_keys.sort();

    let needed = unallocated_keys.len();

    if needed > 0 {
        let mut available_values =
            compute_allocations(current_state.values().copied(), needed, index)?;
        for k in unallocated_keys {
            current_state.insert(k, available_values.remove(0));
        }
    }

    if current_state == existing_state && file_exists {
        return Ok(AllocateResult {
            changed: false,
            size: current_state.len(),
        });
    }

    let json_data = serde_json::to_string_pretty(&current_state)?;
    facts::write(
        workspace,
        state,
        &index.fact_name,
        json_data,
        true,
        add_to_git,
    )?;

    Ok(AllocateResult {
        changed: true,
        size: current_state.len(),
    })
}

fn read_state(
    workspace: &workspace::Workspace,
    state: &State,
    index: &IndexState,
    force: bool,
) -> Result<(HashMap<String, u64>, bool), Error> {
    let raw_data = match facts::read(workspace, state, &index.fact_name) {
        Ok(data) => data,
        Err(facts::ReadError::NotFound(_))
        | Err(facts::ReadError::File(file::ReadError::FileNotFound { .. })) => {
            return Ok((HashMap::new(), false));
        }
        Err(e) => return Err(e.into()),
    };

    let existing_state: Result<HashMap<String, u64>, Error> = (|| {
        let parsed: HashMap<String, Value> = serde_json::from_str(&raw_data)?;
        let mut state = HashMap::new();
        let mut seen_values = HashSet::new();

        for (k, v) in parsed {
            let val = match v.as_u64() {
                Some(val) => val,
                None => {
                    return Err(Error::Corrupted {
                        reason: format!("value for key '{}' is not an integer", k),
                    });
                }
            };
            if val < index.min_value || val > index.max_value {
                return Err(Error::Corrupted {
                    reason: format!(
                        "value {} for key '{}' is out of bounds [{}, {}]",
                        val, k, index.min_value, index.max_value
                    ),
                });
            }
            if !seen_values.insert(val) {
                return Err(Error::Corrupted {
                    reason: format!("duplicate value {} found for key '{}'", val, k),
                });
            }
            state.insert(k, val);
        }
        Ok(state)
    })();

    match existing_state {
        Ok(state) => Ok((state, true)),
        Err(e) => {
            if force {
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
    index: &IndexState,
) -> Result<Vec<u64>, Error> {
    let mut used_sorted: Vec<u64> = used_values.collect();
    used_sorted.sort_unstable();

    let mut available_values = Vec::with_capacity(needed);
    let mut candidate = index.min_value;

    for used_val in used_sorted {
        if available_values.len() >= needed {
            break;
        }
        while candidate < used_val
            && available_values.len() < needed
            && candidate <= index.max_value
        {
            available_values.push(candidate);
            candidate += 1;
        }
        candidate = candidate.max(used_val.saturating_add(1));
    }

    while available_values.len() < needed && candidate <= index.max_value {
        available_values.push(candidate);
        candidate += 1;
    }

    if available_values.len() < needed {
        return Err(Error::AllocationFailed {
            needed,
            min: index.min_value,
            max: index.max_value,
        });
    }

    Ok(available_values)
}
