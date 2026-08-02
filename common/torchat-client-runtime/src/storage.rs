use crate::{
    ChatMessage, ContactRecord, ConversationSummary, InviteCode, PairingItem, ReceiptSendEffect,
    RuntimeIdentity, RuntimeProfile, RuntimeResult,
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
    fn delete_message(&mut self, message_id: &str) -> RuntimeResult<()>;
    fn remove_relationship(
        &mut self,
        installation_id: &str,
        removed_at: i64,
        preserve_history: bool,
    ) -> RuntimeResult<()> {
        let _ = (installation_id, removed_at, preserve_history);
        Err(crate::RuntimeError::Unavailable(
            "relationship removal is not supported by this storage".to_owned(),
        ))
    }
    fn pending_messages(&self) -> RuntimeResult<Vec<ChatMessage>>;
    fn pending_receipts(&self) -> RuntimeResult<Vec<ReceiptSendEffect>> {
        Ok(Vec::new())
    }
    fn expedite_retry_after_ready(&mut self) -> RuntimeResult<()> {
        Ok(())
    }
    fn put_peer_endpoint_capability(
        &mut self,
        _contact_installation_id: &str,
        _capability_id: &str,
        _secret: &[u8],
        _sequence: u64,
        _issued_at: i64,
        _expires_at: Option<i64>,
    ) -> RuntimeResult<()> {
        Err(crate::RuntimeError::Unavailable(
            "peer endpoint capabilities are not supported by this storage".to_owned(),
        ))
    }
    fn revoke_peer_endpoint_capability(
        &mut self,
        _contact_installation_id: &str,
    ) -> RuntimeResult<()> {
        Ok(())
    }

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
