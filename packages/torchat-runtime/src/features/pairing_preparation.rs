use crate::{ProfileStorage, RuntimeResult};

pub struct PairingPreparationFeature<'a, S> {
    storage: &'a S,
}

impl<'a, S> PairingPreparationFeature<'a, S>
where
    S: ProfileStorage,
{
    pub fn new(storage: &'a S) -> Self {
        Self { storage }
    }

    pub fn prepare_refresh_code(&self) -> RuntimeResult<()> {
        let profile = self.storage.profile()?;
        crate::features::pairing::process::require_profile_ready(profile.as_ref())
    }
}
