use torchat_runtime::{
    ChatMessage, ContactRecord, ConversationSummary, PairingItem, PointLookupStorage, RuntimeResult,
};

use super::{ClientDatabase, point_lookup_queries};

impl ClientDatabase {
    pub fn contact_by_installation_id(
        &self,
        installation_id: &str,
    ) -> RuntimeResult<Option<ContactRecord>> {
        point_lookup_queries::contact_by_installation_id(self.connection(), installation_id)
    }

    pub fn conversation_by_id(
        &self,
        conversation_id: &str,
    ) -> RuntimeResult<Option<ConversationSummary>> {
        point_lookup_queries::conversation_by_id(self.connection(), conversation_id)
    }

    pub fn conversation_for_contact(
        &self,
        installation_id: &str,
    ) -> RuntimeResult<Option<ConversationSummary>> {
        point_lookup_queries::conversation_for_contact(self.connection(), installation_id)
    }

    pub fn pairing_inbox_by_id(
        &self,
        pairing_id: &str,
    ) -> RuntimeResult<Option<PairingItem>> {
        point_lookup_queries::pairing_inbox_by_id(self.connection(), pairing_id)
    }

    pub fn pairing_outbox_by_id(
        &self,
        pairing_id: &str,
    ) -> RuntimeResult<Option<PairingItem>> {
        point_lookup_queries::pairing_outbox_by_id(self.connection(), pairing_id)
    }

    pub fn message_by_id(&self, message_id: &str) -> RuntimeResult<Option<ChatMessage>> {
        point_lookup_queries::message_by_id(self.connection(), message_id)
    }
}

impl PointLookupStorage for ClientDatabase {
    fn contact_by_installation_id(
        &self,
        installation_id: &str,
    ) -> RuntimeResult<Option<ContactRecord>> {
        ClientDatabase::contact_by_installation_id(self, installation_id)
    }

    fn conversation_by_id(&self, id: &str) -> RuntimeResult<Option<ConversationSummary>> {
        ClientDatabase::conversation_by_id(self, id)
    }

    fn conversation_for_contact(
        &self,
        installation_id: &str,
    ) -> RuntimeResult<Option<ConversationSummary>> {
        ClientDatabase::conversation_for_contact(self, installation_id)
    }

    fn pairing_inbox_by_id(&self, pairing_id: &str) -> RuntimeResult<Option<PairingItem>> {
        ClientDatabase::pairing_inbox_by_id(self, pairing_id)
    }

    fn pairing_outbox_by_id(&self, pairing_id: &str) -> RuntimeResult<Option<PairingItem>> {
        ClientDatabase::pairing_outbox_by_id(self, pairing_id)
    }

    fn message_by_id(&self, message_id: &str) -> RuntimeResult<Option<ChatMessage>> {
        ClientDatabase::message_by_id(self, message_id)
    }
}
