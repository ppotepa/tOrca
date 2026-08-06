use crate::{ChatMessage, ContactRecord, ConversationSummary, PairingItem, RuntimeResult};

/// Point-oriented reads required by domain features.
///
/// Implementations must use direct storage lookups. Collection-scan fallbacks
/// are intentionally forbidden so a feature cannot accidentally turn a single
/// entity read into an unbounded projection load.
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

    fn pairing_inbox_by_offer_invite_id(
        &self,
        offer_invite_id: &str,
    ) -> RuntimeResult<Option<PairingItem>>;

    fn pairing_outbox_by_id(&self, pairing_id: &str) -> RuntimeResult<Option<PairingItem>>;

    fn message_by_id(&self, message_id: &str) -> RuntimeResult<Option<ChatMessage>>;
}
