use crate::{
    ChangeSet, ContactRecord, ContactStorage, FeatureResult, PointLookupStorage, RuntimeResult,
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
}
