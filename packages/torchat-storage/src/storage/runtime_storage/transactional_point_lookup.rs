use super::super::point_lookup_queries;
use super::SqliteRuntimeStorage;
use torchat_runtime::PointLookupStorage;
use torchat_runtime::{
    ChatMessage, ContactRecord, ConversationSummary, PairingItem, RuntimeResult,
};

impl PointLookupStorage for SqliteRuntimeStorage<'_> {
    fn contact_by_installation_id(
        &self,
        installation_id: &str,
    ) -> RuntimeResult<Option<ContactRecord>> {
        point_lookup_queries::contact_by_installation_id(self.tx(), installation_id)
    }

    fn conversation_by_id(&self, id: &str) -> RuntimeResult<Option<ConversationSummary>> {
        point_lookup_queries::conversation_by_id(self.tx(), id)
    }

    fn conversation_for_contact(
        &self,
        installation_id: &str,
    ) -> RuntimeResult<Option<ConversationSummary>> {
        point_lookup_queries::conversation_for_contact(self.tx(), installation_id)
    }

    fn pairing_inbox_by_id(&self, pairing_id: &str) -> RuntimeResult<Option<PairingItem>> {
        point_lookup_queries::pairing_inbox_by_id(self.tx(), pairing_id)
    }

    fn pairing_outbox_by_id(&self, pairing_id: &str) -> RuntimeResult<Option<PairingItem>> {
        point_lookup_queries::pairing_outbox_by_id(self.tx(), pairing_id)
    }

    fn message_by_id(&self, message_id: &str) -> RuntimeResult<Option<ChatMessage>> {
        point_lookup_queries::message_by_id(self.tx(), message_id)
    }
}
