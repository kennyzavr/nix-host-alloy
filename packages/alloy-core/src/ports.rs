use std::path::Path;

use crate::{
    DynError,
    models::{AgeIdentity, AgeRecipient},
};

pub trait GenRunner {
    fn run(&self, bin_path: &Path, force: bool, add_to_git: bool) -> Result<(), DynError>;
}

pub trait FileSystem {
    fn exists(&self, path: &Path) -> bool;

    fn read(&self, path: &Path) -> Result<Vec<u8>, DynError>;

    fn write(
        &self,
        path: &Path,
        data: &[u8],
        force: bool,
        add_to_git: bool,
    ) -> Result<(), DynError>;
}

pub trait Age {
    fn encrypt(
        &self,
        recipients: &mut dyn Iterator<Item = &AgeRecipient>,
        data: &[u8],
    ) -> Result<Vec<u8>, DynError>;

    fn decrypt(
        &self,
        identities: &mut dyn Iterator<Item = &AgeIdentity>,
        data: &[u8],
    ) -> Result<Vec<u8>, DynError>;
}
