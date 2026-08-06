use crate::{
    ChangeSet, ContactRecord, ContactStorage, ContactTransportPolicy, FeatureResult,
    PointLookupStorage, RuntimeError, RuntimeResult, VerificationState,
    logic::fallback_contact_nickname,
};

pub struct ContactsFeature<'a, S> {
    storage: &'a mut S,
}

impl<'a, S> ContactsFeature<'a, S>
where
    S: ContactStorage + PointLookupStorage,
{
    pub fn new(storage: &'a mut S) -> Self {
        Self { storage }
    }

    pub fn by_installation_id(
        &self,
        installation_id: &str,
    ) -> RuntimeResult<Option<ContactRecord>> {
        self.storage.contact_by_installation_id(installation_id)
    }

    pub fn require(&self, installation_id: &str) -> RuntimeResult<ContactRecord> {
        self.by_installation_id(installation_id)?
            .ok_or_else(|| RuntimeError::NotFound("contact does not exist".to_owned()))
    }

    pub fn save(&mut self, contact: ContactRecord) -> RuntimeResult<FeatureResult<ContactRecord>> {
        self.storage.put_contact(contact.clone())?;
        let changes = ChangeSet::default().with_contact(contact.installation_id.clone());
        Ok(FeatureResult::changed(contact, changes))
    }

    pub fn promote_verified(
        &mut self,
        mut contact: ContactRecord,
    ) -> RuntimeResult<FeatureResult<ContactRecord>> {
        if let Some(existing) = self.by_installation_id(&contact.installation_id)? {
            if contact.nickname.trim().is_empty() {
                contact.nickname = existing.nickname;
            }
            if contact.public_key.trim().is_empty() {
                contact.public_key = existing.public_key;
            }
            if contact.fingerprint.trim().is_empty() {
                contact.fingerprint = existing.fingerprint;
            }
            if contact.dev.is_none() {
                contact.dev = existing.dev;
            }
            contact.local_alias = existing.local_alias;
            contact.muted = existing.muted;
            contact.blocked = existing.blocked;
            contact.transport_policy = existing.transport_policy;
            contact.last_peer_connected_at = existing.last_peer_connected_at;
            contact.last_seen_at = existing.last_seen_at;
        }
        if contact.nickname.trim().is_empty() {
            contact.nickname = fallback_contact_nickname(&contact.installation_id);
        }
        contact.verification = VerificationState::Verified;
        self.save(contact)
    }

    pub fn update_settings(
        &mut self,
        installation_id: &str,
        local_alias: Option<String>,
        muted: bool,
        blocked: bool,
        transport_policy: Option<ContactTransportPolicy>,
    ) -> RuntimeResult<FeatureResult<ContactRecord>> {
        let mut contact = self.require(installation_id)?;
        contact.local_alias = local_alias
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty());
        if contact
            .local_alias
            .as_ref()
            .is_some_and(|value| value.chars().count() > 32)
        {
            return Err(RuntimeError::InvalidParams(
                "contact alias must not exceed 32 characters".to_owned(),
            ));
        }
        contact.muted = muted;
        contact.blocked = blocked;
        if let Some(policy) = transport_policy {
            contact.transport_policy = policy;
        }
        self.save(contact)
    }

    pub fn verify(&mut self, installation_id: &str) -> RuntimeResult<FeatureResult<ContactRecord>> {
        let mut contact = self.require(installation_id)?;
        if contact.verification == VerificationState::Verified {
            return Ok(FeatureResult::unchanged(contact));
        }
        contact.verification = VerificationState::Verified;
        self.save(contact)
    }

    pub fn accepts_messages(&self, installation_id: &str) -> RuntimeResult<bool> {
        Ok(!self.require(installation_id)?.blocked)
    }

    pub fn allows_notifications(&self, installation_id: &str) -> RuntimeResult<bool> {
        Ok(self
            .by_installation_id(installation_id)?
            .is_some_and(|contact| !contact.blocked && !contact.muted))
    }
}
