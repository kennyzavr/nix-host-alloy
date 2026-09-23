use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use super::facts;
use crate::domain::models::{FactRecord, FactState, IndexRecord};
use crate::domain::ports::NixEvaluator;

#[derive(Debug, thiserror::Error)]
pub enum AllocError {
    #[error("Failed to get associated fact")]
    GetFact(#[from] facts::GetError),

    #[error("Failed to read associated fact")]
    ReadFact(#[from] facts::ReadError),

    #[error("Failed to write associated fact")]
    WriteFact(#[from] facts::WriteError),

    #[error("Failed to parse JSON state")]
    Parse(#[from] serde_json::Error),

    #[error("Index state corrupted: {reason}")]
    Corrupted { name: String, reason: String },

    #[error("Failed to allocate the index: need {needed} values, min {min}, max {max}")]
    AllocationFailed {
        name: String,
        needed: usize,
        min: u64,
        max: u64,
    },
}

#[derive(Debug, thiserror::Error)]
pub enum GetError {
    #[error("Failed to load state")]
    Nix(#[from] crate::domain::ports::NixError),

    #[error(transparent)]
    NotFound(#[from] NotFoundError),
}

#[derive(Debug, thiserror::Error)]
pub enum CollectError {
    #[error("Failed to load state")]
    Nix(#[from] crate::domain::ports::NixError),

    #[error(transparent)]
    IndexesNotFound(crate::error::ErrorCollection<NotFoundError>),
}

pub struct AllocResult {
    pub changed: bool,
    pub size: usize,
}

#[derive(Debug, thiserror::Error)]
#[error("Index `{name}` not found")]
pub struct NotFoundError {
    pub name: String,
}

pub struct Service {
    pub nix: Arc<dyn NixEvaluator>,
    pub facts_service: Arc<facts::Service>,
}

impl Service {
    pub fn get(&self, name: String) -> Result<IndexRecord, GetError> {
        let mut state = self.nix.load_state()?;

        let index = state
            .indexes
            .remove(&name)
            .map(|state| IndexRecord {
                name: name.clone(),
                state,
            })
            .ok_or_else(|| NotFoundError {
                name: name.to_string(),
            })?;

        Ok(index)
    }

    pub fn collect(&self, names: &[String]) -> Result<Vec<IndexRecord>, CollectError> {
        let mut state = self.nix.load_state()?;

        let mut missing = crate::error::ErrorCollection::default();
        for name in names {
            if !state.indexes.contains_key(name) {
                missing.push(NotFoundError { name: name.clone() });
            }
        }
        if !missing.is_empty() {
            return Err(CollectError::IndexesNotFound(missing));
        }

        let mut result = Vec::new();
        for (name, index_state) in state.indexes.drain() {
            if !names.is_empty() && !names.contains(&name) {
                continue;
            }
            result.push(IndexRecord {
                name: name,
                state: index_state,
            });
        }
        Ok(result)
    }

    pub fn alloc(
        &self,
        record: &IndexRecord,
        force: bool,
        add_to_git: bool,
    ) -> Result<AllocResult, AllocError> {
        let fact = self.facts_service.get(record.state.fact_name.clone())?;

        let (existing_state, file_exists) = self.read_state(&fact, record, force)?;

        let mut current_state: HashMap<String, u64> = existing_state
            .iter()
            .filter(|(k, _)| record.state.keys.contains(k.as_str()))
            .map(|(k, v)| (k.clone(), *v))
            .collect();

        let mut unallocated_keys: Vec<String> = record
            .state
            .keys
            .iter()
            .filter(|k| !current_state.contains_key(k.as_str()))
            .cloned()
            .collect();
        unallocated_keys.sort();

        let needed = unallocated_keys.len();

        if needed > 0 {
            let mut available_values =
                self.compute_allocations(current_state.values().copied(), needed, record)?;
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

        self.facts_service
            .write(&fact, json_data, true, add_to_git)?;

        Ok(AllocResult {
            changed: true,
            size: current_state.len(),
        })
    }

    fn read_state(
        &self,
        fact: &FactRecord,
        record: &IndexRecord,
        force: bool,
    ) -> Result<(HashMap<String, u64>, bool), AllocError> {
        let raw_data = match self.facts_service.read(fact) {
            Ok(data) => data,
            Err(facts::ReadError::File { .. }) => {
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
                if val < record.state.min_value || val > record.state.max_value {
                    return Err(AllocError::Corrupted {
                        name: record.name.to_string(),
                        reason: format!(
                            "value {} for key `{}` is out of bounds [{}, {}]",
                            val, k, record.state.min_value, record.state.max_value
                        ),
                    });
                }
                if !seen_values.insert(val) {
                    return Err(AllocError::Corrupted {
                        name: record.name.to_string(),
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
                if force {
                    Ok((HashMap::new(), true))
                } else {
                    Err(e)
                }
            }
        }
    }

    fn compute_allocations(
        &self,
        used_values: impl Iterator<Item = u64>,
        needed: usize,
        record: &IndexRecord,
    ) -> Result<Vec<u64>, AllocError> {
        let mut used_sorted: Vec<u64> = used_values.collect();
        used_sorted.sort_unstable();

        let mut available_values = Vec::with_capacity(needed);
        let mut candidate = record.state.min_value;

        for used_val in used_sorted {
            if available_values.len() >= needed {
                break;
            }
            while candidate < used_val
                && available_values.len() < needed
                && candidate <= record.state.max_value
            {
                available_values.push(candidate);
                candidate += 1;
            }
            candidate = candidate.max(used_val.saturating_add(1));
        }

        while available_values.len() < needed && candidate <= record.state.max_value {
            available_values.push(candidate);
            candidate += 1;
        }

        if available_values.len() < needed {
            return Err(AllocError::AllocationFailed {
                name: record.name.to_string(),
                needed,
                min: record.state.min_value,
                max: record.state.max_value,
            });
        }

        Ok(available_values)
    }
}
