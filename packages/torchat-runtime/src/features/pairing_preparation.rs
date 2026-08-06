use crate::{ChangeSet, FeatureResult, InviteCode, PairingStorage, ProfileStorage, RuntimeResult};

pub struct PairingPreparationFeature<'a, S> {
    storage: &'a mut S,
}

impl<'a, S> PairingPreparationFeature<'a, S>
where
    S: ProfileStorage + PairingStorage,
{
    pub fn new(storage: &'a mut S) -> Self {
        Self { storage }
    }

    pub fn prepare_refresh_code(&self) -> RuntimeResult<()> {
        let profile = self.storage.profile()?;
        crate::features::pairing::process::require_profile_ready(profile.as_ref())
    }

    pub fn commit_code(&mut self, code: InviteCode) -> RuntimeResult<FeatureResult<InviteCode>> {
        self.storage.put_pairing_code(code.clone())?;
        Ok(FeatureResult::changed(
            code,
            ChangeSet::section(crate::ChangeSections::PAIRINGS),
        ))
    }
}
