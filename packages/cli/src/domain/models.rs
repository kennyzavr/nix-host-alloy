use serde::Deserialize;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;

#[derive(Deserialize, Debug, Clone)]
pub struct State {
    pub name: String,
    #[serde(rename = "secretsAgeKeyPairs")]
    pub secrets_age_key_pairs: Vec<AgeKeyPair>,
    pub hosts: HashMap<String, HostState>,
    pub jails: HashMap<String, JailState>,
    pub secrets: HashMap<String, SecretState>,
    pub facts: HashMap<String, FactState>,
    pub generators: HashMap<String, GeneratorState>,
    pub indexes: HashMap<String, IndexState>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct HostState {
    pub tags: Vec<String>,
    pub secrets: HashMap<String, NodeSecretState>,
    pub facts: HashMap<String, NodeFactState>,
    #[serde(rename = "secretsAgeKeyPairs")]
    pub secrets_age_key_pairs: Vec<AgeKeyPair>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct JailState {
    pub host: String,
    pub tags: Vec<String>,
    pub secrets: HashMap<String, NodeSecretState>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct FactState {
    pub file: PathBuf,
    pub tags: Vec<String>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct NodeFactState {
    pub path: PathBuf,
}

#[derive(Deserialize, Debug, Clone)]
pub struct GeneratorState {
    pub wants: Vec<String>,
    #[serde(rename = "wantedBy")]
    pub wanted_by: Vec<String>,
    pub before: Vec<String>,
    pub after: Vec<String>,
    pub tags: Vec<String>,
    pub secrets: HashSet<String>,
    pub facts: HashSet<String>,
    pub evaluated: bool,
}

#[derive(Deserialize, Debug, Clone)]
pub struct IndexState {
    pub keys: HashSet<String>,
    #[serde(rename = "minValue")]
    pub min_value: u64,
    #[serde(rename = "maxValue")]
    pub max_value: u64,
    #[serde(rename = "factName")]
    pub fact_name: String,
    pub evaluated: bool,
}

#[derive(Deserialize, Debug, Clone)]
pub struct SecretState {
    pub file: PathBuf,
    pub tags: Vec<String>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct NodeSecretState {
    pub file: PathBuf,
    pub path: PathBuf,
}

#[derive(Deserialize, Debug, Clone)]
pub struct AgeKeyPair {
    pub identity: String,
    pub recipient: String,
}

#[derive(Debug, Clone)]
pub struct GeneratorRecord {
    pub name: String,
    pub state: GeneratorState,
}

#[derive(Debug, Clone)]
pub struct FactRecord {
    pub name: String,
    pub state: FactState,
}

#[derive(Debug, Clone)]
pub struct SecretRecord {
    pub name: String,
    pub state: SecretState,
}

#[derive(Debug, Clone)]
pub struct HostRecord {
    pub name: String,
    pub state: HostState,
}

#[derive(Debug, Clone)]
pub struct JailRecord {
    pub name: String,
    pub state: JailState,
}

#[derive(Debug, Clone)]
pub struct IndexRecord {
    pub name: String,
    pub state: IndexState,
}
