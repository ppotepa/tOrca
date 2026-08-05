use crate::{
    ChatMessage, ContactRecord, ConversationSummary, PairingItem, RuntimeResult, RuntimeStorage,
};

/// Point-oriented reads used by domain features.
///
/// The blanket implementation keeps existing storage adapters source-compatible
/// while moving collection scans behind the storage boundary. Production
/// adapters can override this port with direct SQL without changing domain code.
pub trait PointLookupStorage {
    fn contact_by_installation_id(
        &self,
        installation_id: &str,
    ) -> RuntimeResult<Option<ContactRecord>>;

    fn conversation_by_id(&self, id: &str) -> RuntimeResult<Option<ConversationSummary>>;

    fn conversation_for_contact(
        &self,
        installation_id: &str,
    ) -> RuntimeResult<Option<ConversationSummary>>;

    fn pairing_inbox_by_id(&self, pairing_id: &str) -> RuntimeResult<Option<PairingItem>>;

    fn pairing_outbox_by_id(&self, pairing_id: &str) -> RuntimeResult<Option<PairingItem>>;

    fn message_by_id(&self, message_id: &str) -> RuntimeResult<Option<ChatMessage>>;
}

impl<T: RuntimeStorage + ?Sized> PointLookupStorage for T {
    fn contact_by_installation_id(
        &self,
        installation_id: &str,
    ) -> RuntimeResult<Option<ContactRecord>> {
        Ok(RuntimeStorage::contacts(self)?
            .into_iter()
            .find(|contact| contact.installation_id == installation_id))
    }

    fn conversation_by_id(&self, id: &str) -> RuntimeResult<Option<ConversationSummary>> {
        Ok(RuntimeStorage::conversations(self)?
            .into_iter()
            .find(|conversation| conversation.id == id))
    }

    fn conversation_for_contact(
        &self,
        installation_id: &str,
    ) -> RuntimeResult<Option<ConversationSummary>> {
        Ok(RuntimeStorage::conversations(self)?
            .into_iter()
            .find(|conversation| conversation.contact_installation_id == installation_id))
    }

    fn pairing_inbox_by_id(&self, pairing_id: &str) -> RuntimeResult<Option<PairingItem>> {
        Ok(RuntimeStorage::pairing_inbox(self)?
            .into_iter()
            .find(|item| item.pairing_id == pairing_id))
    }

    fn pairing_outbox_by_id(&self, pairing_id: &str) -> RuntimeResult<Option<PairingItem>> {
        Ok(RuntimeStorage::pairing_outbox(self)?
            .into_iter()
            .find(|item| item.pairing_id == pairing_id))
    }

    fn message_by_id(&self, message_id: &str) -> RuntimeResult<Option<ChatMessage>> {
        RuntimeStorage::message(self, message_id)
    }
}
