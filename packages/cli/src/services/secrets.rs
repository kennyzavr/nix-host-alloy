use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::domain::models::{HostRecord, JailRecord, SecretRecord, State};
use crate::domain::ports::{
    Crypto, CryptoError, FileSystem, FsError, Git, GitError, NixError, NixEvaluator,
};
use crate::error::ErrorCollection;
use crate::services::{hosts, jails};

#[derive(Debug, thiserror::Error)]
pub enum ReadMasterError {
    #[error("Failed to load state")]
    Nix(#[from] NixError),

    #[error("Master age key pairs not defined")]
    NoKeys,

    #[error("Failed to read '{path}'")]
    Io {
        name: String,
        path: PathBuf,
        #[source]
        source: FsError,
    },

    #[error("Failed to decrypt")]
    Decrypt {
        name: String,
        #[source]
        source: CryptoError,
    },
}

#[derive(Debug, thiserror::Error)]
pub enum WriteMasterError {
    #[error("Failed to load state")]
    Nix(#[from] NixError),

    #[error("Master age key pairs not defined")]
    NoKeys,

    #[error("Failed to encrypt")]
    Encrypt {
        name: String,
        #[source]
        source: CryptoError,
    },

    #[error("Failed to write '{path}'")]
    Io {
        name: String,
        path: PathBuf,
        #[source]
        source: FsError,
    },

    #[error("Failed to add '{path}' to git")]
    Git {
        name: String,
        path: PathBuf,
        #[source]
        source: GitError,
    },
}

#[derive(Debug, thiserror::Error)]
pub enum RekeyHostError {
    #[error("Host `{host_name}` missing secret definition for `{secret_name}`")]
    MissingDefinition {
        host_name: String,
        secret_name: String,
    },

    #[error("Age key pairs not defined for host `{host_name}`")]
    NoKeys { host_name: String },

    #[error("Failed to read master secret `{name}`")]
    ReadMaster {
        name: String,
        #[source]
        source: ReadMasterError,
    },

    #[error("Failed to encrypt secret `{name}` for host `{host_name}`")]
    Encrypt {
        name: String,
        host_name: String,
        #[source]
        source: CryptoError,
    },

    #[error("Failed to write secret `{name}` to '{path}'")]
    Io {
        name: String,
        path: PathBuf,
        #[source]
        source: FsError,
    },

    #[error("Failed to add secret `{name}` to git at '{path}'")]
    Git {
        name: String,
        path: PathBuf,
        #[source]
        source: GitError,
    },
}

#[derive(Debug, thiserror::Error)]
pub enum RekeyJailError {
    #[error("Failed to load state")]
    Nix(#[from] NixError),

    #[error("Jail `{jail_name}` missing secret definition for `{secret_name}`")]
    MissingDefinition {
        jail_name: String,
        secret_name: String,
    },

    #[error("Associated host `{host_name}` not found for jail `{jail_name}`")]
    HostNotFound {
        jail_name: String,
        host_name: String,
    },

    #[error("Age key pairs not defined for host `{host_name}`")]
    NoKeys { host_name: String },

    #[error("Failed to read master secret `{name}`")]
    ReadMaster {
        name: String,
        #[source]
        source: ReadMasterError,
    },

    #[error("Failed to encrypt secret `{name}` for host `{host_name}`")]
    Encrypt {
        name: String,
        host_name: String,
        #[source]
        source: CryptoError,
    },

    #[error("Failed to write secret `{name}` to '{path}'")]
    Io {
        name: String,
        path: PathBuf,
        #[source]
        source: FsError,
    },

    #[error("Failed to add secret `{name}` to git at '{path}'")]
    Git {
        name: String,
        path: PathBuf,
        #[source]
        source: GitError,
    },
}

#[derive(Debug, thiserror::Error)]
pub enum GetError {
    #[error("Failed to load state")]
    Nix(#[from] NixError),

    #[error(transparent)]
    NotFound(#[from] NotFoundError),
}

#[derive(Debug, thiserror::Error)]
#[error("Master secret `{secret_name}` not found")]
pub struct NotFoundError {
    pub secret_name: String,
}

#[derive(Debug, thiserror::Error)]
#[error("Host `{host_name}` missing secret definition for `{secret_name}`")]
pub struct HostNoDefError {
    pub host_name: String,
    pub secret_name: String,
}

#[derive(Debug, thiserror::Error)]
#[error("Jail `{jail_name}` missing secret definition for `{secret_name}`")]
pub struct JailNoDefError {
    pub jail_name: String,
    pub secret_name: String,
}

#[derive(Debug, thiserror::Error)]
pub enum HostCollectError {
    #[error("Failed to load state")]
    Nix(#[from] NixError),

    #[error(transparent)]
    HostsNotFound(ErrorCollection<hosts::NotFoundError>),

    #[error(transparent)]
    SecretsNotFound(ErrorCollection<NotFoundError>),

    #[error(transparent)]
    DefsNotFound(ErrorCollection<HostNoDefError>),
}

#[derive(Debug, thiserror::Error)]
pub enum JailCollectError {
    #[error("Failed to load state")]
    Nix(#[from] NixError),

    #[error(transparent)]
    JailsNotFound(ErrorCollection<jails::NotFoundError>),

    #[error(transparent)]
    SecretsNotFound(ErrorCollection<NotFoundError>),

    #[error(transparent)]
    DefsNotFound(ErrorCollection<JailNoDefError>),
}

pub struct Service {
    pub nix: Arc<dyn NixEvaluator>,
    pub fs: Arc<dyn FileSystem>,
    pub git: Arc<dyn Git>,
    pub crypto: Arc<dyn Crypto>,
}

impl Service {
    pub fn get(&self, name: String) -> Result<SecretRecord, GetError> {
        let mut state = self.nix.load_state()?;

        let secret = state
            .secrets
            .remove(&name)
            .map(|state| SecretRecord {
                name: name.clone(),
                state,
            })
            .ok_or_else(|| NotFoundError { secret_name: name })?;

        Ok(secret)
    }

    pub fn master_exists(&self, record: &SecretRecord) -> bool {
        self.fs.exists(&record.state.file)
    }

    pub fn read_master(&self, record: &SecretRecord) -> Result<Vec<u8>, ReadMasterError> {
        let state = self.nix.load_state()?;

        let identities: Vec<String> = state
            .secrets_age_key_pairs
            .iter()
            .map(|k| k.identity.clone())
            .collect();

        if identities.is_empty() {
            return Err(ReadMasterError::NoKeys);
        }

        let path = &record.state.file;
        let encrypted_data = self.fs.read(path).map_err(|e| ReadMasterError::Io {
            name: record.name.to_string(),
            path: path.clone(),
            source: e,
        })?;

        let data = self
            .crypto
            .decrypt(&identities, &encrypted_data)
            .map_err(|e| ReadMasterError::Decrypt {
                name: record.name.to_string(),
                source: e,
            })?;

        Ok(data)
    }

    pub fn write_master(
        &self,
        record: &SecretRecord,
        data: &[u8],
        force: bool,
        add_to_git: bool,
    ) -> Result<(), WriteMasterError> {
        let state = self.nix.load_state()?;

        let recipients: Vec<String> = state
            .secrets_age_key_pairs
            .iter()
            .map(|k| k.recipient.clone())
            .collect();

        if recipients.is_empty() {
            return Err(WriteMasterError::NoKeys);
        }

        let path = &record.state.file;
        if add_to_git {
            self.git
                .check_in_repo(path)
                .map_err(|e| WriteMasterError::Git {
                    name: record.name.to_string(),
                    path: path.clone(),
                    source: e,
                })?;
        }

        let encrypted_data =
            self.crypto
                .encrypt(&recipients, data)
                .map_err(|e| WriteMasterError::Encrypt {
                    name: record.name.to_string(),
                    source: e,
                })?;

        self.fs
            .write(path, &encrypted_data, force)
            .map_err(|e| WriteMasterError::Io {
                name: record.name.to_string(),
                path: path.clone(),
                source: e,
            })?;

        if add_to_git {
            self.git.add_file(path).map_err(|e| WriteMasterError::Git {
                name: record.name.to_string(),
                path: path.clone(),
                source: e,
            })?;
        }

        Ok(())
    }

    pub fn rekey_host(
        &self,
        host: &HostRecord,
        secret: &SecretRecord,
        force: bool,
        add_to_git: bool,
    ) -> Result<(), RekeyHostError> {
        let host_secret = host.state.secrets.get(&secret.name).ok_or_else(|| {
            RekeyHostError::MissingDefinition {
                host_name: host.name.to_string(),
                secret_name: secret.name.to_string(),
            }
        })?;

        let master_data =
            self.read_master(secret)
                .map_err(|source| RekeyHostError::ReadMaster {
                    name: secret.name.to_string(),
                    source,
                })?;

        let recipients: Vec<String> = host
            .state
            .secrets_age_key_pairs
            .iter()
            .map(|k| k.recipient.clone())
            .collect();

        if recipients.is_empty() {
            return Err(RekeyHostError::NoKeys {
                host_name: host.name.to_string(),
            });
        }

        let path = &host_secret.file;

        if add_to_git {
            self.git
                .check_in_repo(path)
                .map_err(|e| RekeyHostError::Git {
                    name: secret.name.to_string(),
                    path: path.clone(),
                    source: e,
                })?;
        }

        let encrypted_data = self
            .crypto
            .encrypt(&recipients, &master_data)
            .map_err(|e| RekeyHostError::Encrypt {
                name: secret.name.to_string(),
                host_name: host.name.to_string(),
                source: e,
            })?;

        self.fs
            .write(path, &encrypted_data, force)
            .map_err(|e| RekeyHostError::Io {
                name: secret.name.to_string(),
                path: path.clone(),
                source: e,
            })?;

        if add_to_git {
            self.git.add_file(path).map_err(|e| RekeyHostError::Git {
                name: secret.name.to_string(),
                path: path.clone(),
                source: e,
            })?;
        }

        Ok(())
    }

    pub fn rekey_jail(
        &self,
        jail: &JailRecord,
        secret: &SecretRecord,
        force: bool,
        add_to_git: bool,
    ) -> Result<(), RekeyJailError> {
        let mut state = self.nix.load_state()?;

        let host_record =
            state
                .hosts
                .remove(&jail.state.host)
                .ok_or_else(|| RekeyJailError::HostNotFound {
                    jail_name: jail.name.to_string(),
                    host_name: jail.state.host.clone(),
                })?;

        let jail_secret = jail.state.secrets.get(&secret.name).ok_or_else(|| {
            RekeyJailError::MissingDefinition {
                jail_name: jail.name.to_string(),
                secret_name: secret.name.to_string(),
            }
        })?;

        let master_data =
            self.read_master(secret)
                .map_err(|source| RekeyJailError::ReadMaster {
                    name: secret.name.to_string(),
                    source,
                })?;

        let recipients: Vec<String> = host_record
            .secrets_age_key_pairs
            .iter()
            .map(|k| k.recipient.clone())
            .collect();

        if recipients.is_empty() {
            return Err(RekeyJailError::NoKeys {
                host_name: jail.state.host.clone(),
            });
        }

        let path = &jail_secret.file;

        if add_to_git {
            self.git
                .check_in_repo(path)
                .map_err(|e| RekeyJailError::Git {
                    name: secret.name.to_string(),
                    path: path.clone(),
                    source: e,
                })?;
        }

        let encrypted_data = self
            .crypto
            .encrypt(&recipients, &master_data)
            .map_err(|e| RekeyJailError::Encrypt {
                name: secret.name.to_string(),
                host_name: jail.name.to_string(),
                source: e,
            })?;

        self.fs
            .write(path, &encrypted_data, force)
            .map_err(|e| RekeyJailError::Io {
                name: secret.name.to_string(),
                path: path.clone(),
                source: e,
            })?;

        if add_to_git {
            self.git.add_file(path).map_err(|e| RekeyJailError::Git {
                name: secret.name.to_string(),
                path: path.clone(),
                source: e,
            })?;
        }

        Ok(())
    }

    pub fn collect_hosts(
        &self,
        secrets: &[String],
        hosts: &[String],
        tags: &[String],
    ) -> Result<Vec<(HostRecord, SecretRecord)>, HostCollectError> {
        let state = self.nix.load_state()?;

        let mut missing_hosts = ErrorCollection::default();
        for host in hosts {
            if !state.hosts.contains_key(host) {
                missing_hosts.push(hosts::NotFoundError { name: host.clone() });
            }
        }
        if !missing_hosts.is_empty() {
            return Err(HostCollectError::HostsNotFound(missing_hosts));
        }

        let mut missing_secrets = ErrorCollection::default();
        for secret in secrets {
            if !state.secrets.contains_key(secret) {
                missing_secrets.push(NotFoundError {
                    secret_name: secret.clone(),
                });
            }
        }
        if !missing_secrets.is_empty() {
            return Err(HostCollectError::SecretsNotFound(missing_secrets));
        }

        let mut missing_defs = ErrorCollection::default();
        if !hosts.is_empty() && !secrets.is_empty() {
            for host_name in hosts {
                if let Some(host_state) = state.hosts.get(host_name) {
                    for secret_name in secrets {
                        if !host_state.secrets.contains_key(secret_name) {
                            missing_defs.push(HostNoDefError {
                                host_name: host_name.clone(),
                                secret_name: secret_name.clone(),
                            });
                        }
                    }
                }
            }
        }
        if !missing_defs.is_empty() {
            return Err(HostCollectError::DefsNotFound(missing_defs));
        }

        let mut result = Vec::new();

        for (host_name, host_state) in &state.hosts {
            if !hosts.is_empty() && !hosts.contains(host_name) {
                continue;
            }

            for secret_name in host_state.secrets.keys() {
                if !secrets.is_empty() && !secrets.contains(secret_name) {
                    continue;
                }

                if let Some(master_state) = state.secrets.get(secret_name) {
                    if !tags.is_empty() && !master_state.tags.iter().any(|t| tags.contains(t)) {
                        continue;
                    }
                    result.push((
                        HostRecord {
                            name: host_name.clone(),
                            state: host_state.clone(),
                        },
                        SecretRecord {
                            name: secret_name.clone(),
                            state: master_state.clone(),
                        },
                    ));
                }
            }
        }

        Ok(result)
    }

    pub fn collect_jails(
        &self,
        secrets: &[String],
        jails: &[String],
        tags: &[String],
    ) -> Result<Vec<(JailRecord, SecretRecord)>, JailCollectError> {
        let state = self.nix.load_state()?;

        let mut missing_jails = ErrorCollection::default();
        for jail in jails {
            if !state.jails.contains_key(jail) {
                missing_jails.push(jails::NotFoundError { name: jail.clone() });
            }
        }
        if !missing_jails.is_empty() {
            return Err(JailCollectError::JailsNotFound(missing_jails));
        }

        let mut missing_secrets = ErrorCollection::default();
        for secret in secrets {
            if !state.secrets.contains_key(secret) {
                missing_secrets.push(NotFoundError {
                    secret_name: secret.clone(),
                });
            }
        }
        if !missing_secrets.is_empty() {
            return Err(JailCollectError::SecretsNotFound(missing_secrets));
        }

        let mut missing_defs = ErrorCollection::default();
        if !jails.is_empty() && !secrets.is_empty() {
            for jail_name in jails {
                if let Some(jail_state) = state.jails.get(jail_name) {
                    for secret_name in secrets {
                        if !jail_state.secrets.contains_key(secret_name) {
                            missing_defs.push(JailNoDefError {
                                jail_name: jail_name.clone(),
                                secret_name: secret_name.clone(),
                            });
                        }
                    }
                }
            }
        }
        if !missing_defs.is_empty() {
            return Err(JailCollectError::DefsNotFound(missing_defs));
        }

        let mut result = Vec::new();

        for (jail_name, jail_state) in &state.jails {
            if !jails.is_empty() && !jails.contains(jail_name) {
                continue;
            }

            for secret_name in jail_state.secrets.keys() {
                if !secrets.is_empty() && !secrets.contains(secret_name) {
                    continue;
                }

                if let Some(master_state) = state.secrets.get(secret_name) {
                    if !tags.is_empty() && !master_state.tags.iter().any(|t| tags.contains(t)) {
                        continue;
                    }
                    result.push((
                        JailRecord {
                            name: jail_name.clone(),
                            state: jail_state.clone(),
                        },
                        SecretRecord {
                            name: secret_name.clone(),
                            state: master_state.clone(),
                        },
                    ));
                }
            }
        }

        Ok(result)
    }
}
