use crate::{
    ChangeSet, ContactRecord, ContactStorage, ContactTransportPolicy, FeatureResult,
    PointLookupStorage, RuntimeError, RuntimeResult, VerificationState,
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

    pub fn save(&mut self, contact: ContactRecord) -> RuntimeResult<FeatureResult<ContactRecord>> {
        self.storage.put_contact(contact.clone())?;
        let changes = ChangeSet::default().with_contact(contact.installation_id.clone());
        Ok(FeatureResult::changed(contact, changes))
    }

    pub fn update_settings(
        &mut self,
        installation_id: &str,
        local_alias: Option<String>,
        muted: bool,
        blocked: bool,
        transport_policy: Option<ContactTransportPolicy>,
    ) -> RuntimeResult<FeatureResult<ContactRecord>> {
        let mut contact = self
            .storage
            .contact_by_installation_id(installation_id)?
            .ok_or_else(|| RuntimeError::NotFound("contact does not exist".to_owned()))?;
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
        let mut contact = self
            .storage
            .contact_by_installation_id(installation_id)?
            .ok_or_else(|| RuntimeError::NotFound("contact does not exist".to_owned()))?;
        if contact.verification == VerificationState::Verified {
            return Ok(FeatureResult::unchanged(contact));
        }
        contact.verification = VerificationState::Verified;
        self.save(contact)
    }
}
