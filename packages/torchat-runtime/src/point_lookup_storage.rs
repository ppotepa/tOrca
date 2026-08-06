use crate::{ChatMessage, ContactRecord, ConversationSummary, PairingItem, RuntimeResult};

/// Point-oriented reads used by domain features.
///
/// Implementations must perform a direct point lookup. Collection scans are
/// intentionally not provided as a compatibility fallback because they hide
/// missing transactional adapter support and make feature behaviour depend on
/// collection size.
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
