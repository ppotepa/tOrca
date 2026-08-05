use crate::{
    ChatMessage, ContactRecord, ConversationSummary, PairingItem, RuntimeResult, RuntimeStorage,
};

/// Point-oriented reads used by domain features.
///
/// The aggregate storage contract owns the compatibility defaults. Production
/// adapters override those methods with direct queries, while features depend
/// only on this point-oriented boundary.
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
        RuntimeStorage::contact_by_installation_id(self, installation_id)
    }

    fn conversation_by_id(&self, id: &str) -> RuntimeResult<Option<ConversationSummary>> {
        RuntimeStorage::conversation_by_id(self, id)
    }

    fn conversation_for_contact(
        &self,
        installation_id: &str,
    ) -> RuntimeResult<Option<ConversationSummary>> {
        RuntimeStorage::conversation_for_contact(self, installation_id)
    }

    fn pairing_inbox_by_id(&self, pairing_id: &str) -> RuntimeResult<Option<PairingItem>> {
        RuntimeStorage::pairing_inbox_by_id(self, pairing_id)
    }

    fn pairing_outbox_by_id(&self, pairing_id: &str) -> RuntimeResult<Option<PairingItem>> {
        RuntimeStorage::pairing_outbox_by_id(self, pairing_id)
    }

    fn message_by_id(&self, message_id: &str) -> RuntimeResult<Option<ChatMessage>> {
        RuntimeStorage::message_by_id(self, message_id)
    }
}
