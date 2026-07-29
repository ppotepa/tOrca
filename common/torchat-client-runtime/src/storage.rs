use crate::{
    ChatMessage, ContactRecord, ConversationSummary, InviteCode, PairingItem, RuntimeIdentity,
    RuntimeProfile, RuntimeResult,
};

pub trait RuntimeStorage {
    fn identity(&self) -> RuntimeResult<Option<RuntimeIdentity>>;
    fn profile(&self) -> RuntimeResult<Option<RuntimeProfile>>;
    fn put_profile(&mut self, profile: RuntimeProfile) -> RuntimeResult<()>;

    fn pairing_code(&self) -> RuntimeResult<Option<InviteCode>>;
    fn put_pairing_code(&mut self, code: InviteCode) -> RuntimeResult<()>;

    fn pairing_inbox(&self) -> RuntimeResult<Vec<PairingItem>>;
    fn put_pairing_inbox(&mut self, item: PairingItem) -> RuntimeResult<()>;

    fn pairing_outbox(&self) -> RuntimeResult<Vec<PairingItem>>;
    fn put_pairing_outbox(&mut self, item: PairingItem) -> RuntimeResult<()>;

    fn contacts(&self) -> RuntimeResult<Vec<ContactRecord>>;
    fn put_contact(&mut self, contact: ContactRecord) -> RuntimeResult<()>;

    fn conversations(&self) -> RuntimeResult<Vec<ConversationSummary>>;
    fn put_conversation(&mut self, conversation: ConversationSummary) -> RuntimeResult<()>;
    fn mark_conversation_read(&mut self, conversation_id: &str) -> RuntimeResult<()>;

    fn messages(&self, conversation_id: &str) -> RuntimeResult<Vec<ChatMessage>>;
    fn put_message(&mut self, message: ChatMessage) -> RuntimeResult<()>;
    fn pending_messages(&self) -> RuntimeResult<Vec<ChatMessage>>;

    fn message(&self, message_id: &str) -> RuntimeResult<Option<ChatMessage>> {
        for conversation in self.conversations()? {
            if let Some(message) = self
                .messages(&conversation.id)?
                .into_iter()
                .find(|message| message.id == message_id)
            {
                return Ok(Some(message));
            }
        }
        Ok(None)
    }
}
