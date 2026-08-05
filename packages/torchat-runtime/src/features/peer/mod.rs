use crate::{CapabilityStorage, ChangeSections, ChangeSet, FeatureResult, RuntimeResult};

pub struct PeerFeature<'a, S> {
    storage: &'a mut S,
}

impl<'a, S> PeerFeature<'a, S>
where
    S: CapabilityStorage,
{
    pub fn new(storage: &'a mut S) -> Self {
        Self { storage }
    }

    pub fn store_capability(
        &mut self,
        contact_installation_id: &str,
        capability_id: &str,
        secret: &[u8],
        sequence: u64,
        issued_at: i64,
        expires_at: Option<i64>,
    ) -> RuntimeResult<FeatureResult<()>> {
        self.storage.put_peer_endpoint_capability(
            contact_installation_id,
            capability_id,
            secret,
            sequence,
            issued_at,
            expires_at,
        )?;
        Ok(FeatureResult::changed(
            (),
            ChangeSet::section(ChangeSections::CAPABILITIES),
        ))
    }

    pub fn revoke_capability(
        &mut self,
        contact_installation_id: &str,
    ) -> RuntimeResult<FeatureResult<()>> {
        self.storage
            .revoke_peer_endpoint_capability(contact_installation_id)?;
        Ok(FeatureResult::changed(
            (),
            ChangeSet::section(ChangeSections::CAPABILITIES),
        ))
    }
}
