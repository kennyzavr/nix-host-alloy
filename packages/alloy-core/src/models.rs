use serde::Deserialize;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

#[derive(Deserialize, Debug, Clone)]
pub struct State {
    pub name: String,

    #[serde(rename = "secretsAgeKeyPairs")]
    pub secrets_age_key_pairs: Vec<AgeKeyPair>,

    pub hosts: HashMap<String, Host>,
    pub jails: HashMap<String, Jail>,
    pub secrets: HashMap<String, Secret>,
    pub facts: HashMap<String, Fact>,
    pub generators: HashMap<String, Generator>,
    pub indexes: HashMap<String, Index>,

    pub qemu: Option<Qemu>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct Host {
    pub tags: Vec<String>,
    pub secrets: HashMap<String, SecretRef>,

    #[serde(rename = "secretsAgeKeyPairs")]
    pub secrets_age_key_pairs: Vec<AgeKeyPair>,

    pub qemu: Option<QemuGuest>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct Jail {
    pub host: String,
    pub tags: Vec<String>,
    pub secrets: HashMap<String, SecretRef>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct SecretRef {
    pub file: PathBuf,
    pub path: PathBuf,
}

#[derive(Deserialize, Debug, Clone)]
pub struct Secret {
    pub file: PathBuf,
    pub tags: Vec<String>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct Fact {
    pub file: PathBuf,
    pub tags: Vec<String>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct Generator {
    pub wants: Vec<String>,
    pub after: Vec<String>,
    pub tags: Vec<String>,
    pub secrets: HashSet<String>,
    pub facts: HashSet<String>,
    #[serde(rename = "scriptPath")]
    pub script_path: Option<PathBuf>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct Index {
    pub keys: Option<HashSet<String>>,
    #[serde(rename = "minValue")]
    pub min_value: u64,
    #[serde(rename = "maxValue")]
    pub max_value: u64,
    #[serde(rename = "factName")]
    pub fact_name: String,
}

#[derive(Deserialize, Debug, Clone)]
pub struct Qemu {
    pub nets: HashMap<String, QemuNet>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct QemuNet {}

#[derive(Deserialize, Debug, Clone)]
pub struct QemuGuest {
    pub nets: HashMap<String, QemuNetRef>,
    #[serde(rename = "portForwards")]
    pub port_forwards: Vec<QemuPortForward>,
    pub variants: HashMap<String, QemuVariant>,
    pub variant: Option<String>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct QemuNetRef {
    pub iface: String,
    pub mac: String,
}

#[derive(Deserialize, Debug, Clone)]
pub struct QemuPortForward {
    pub name: String,
    pub proto: L4Proto,
    pub hypervisor: u16,
    pub guest: u16,
}

#[derive(Deserialize, Debug, Clone)]
pub struct QemuVariant {
    #[serde(rename = "scriptPath")]
    pub script_path: PathBuf,
}

#[derive(Deserialize, Debug, Clone)]
#[serde(rename_all = "lowercase")]
pub enum L4Proto {
    Tcp,
    Udp,
}

#[derive(Deserialize, Debug, Clone)]
pub struct AgeKeyPair {
    pub identity: AgeIdentity,
    pub recipient: AgeRecipient,
}

#[derive(Deserialize, Debug, Clone)]
#[serde(transparent)]
pub struct AgeRecipient(pub PathBuf);

#[derive(Deserialize, Debug, Clone)]
#[serde(transparent)]
pub struct AgeIdentity(pub PathBuf);
