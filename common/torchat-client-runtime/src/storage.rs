use crate::{
    ChatMessage, ContactRecord, ConversationSummary, InviteCode, PairingItem, ReceiptSendEffect,
    RuntimeIdentity, RuntimeProfile, RuntimeResult,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RelationshipTransition {
    BeginVerified {
        installation_id: String,
        boundary_at: i64,
    },
    Remove {
        installation_id: String,
        removed_at: i64,
        preserve_history: bool,
        removal_id: String,
        relationship_epoch: i64,
    },
}

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

    fn current_relationship_epoch(&mut self, _installation_id: &str) -> RuntimeResult<i64> {
        Ok(0)
    }

    fn apply_relationship_transition(
        &mut self,
        transition: RelationshipTransition,
    ) -> RuntimeResult<()> {
        match transition {
            RelationshipTransition::BeginVerified {
                installation_id,
                boundary_at,
            } => self.begin_verified_relationship(&installation_id, boundary_at),
            RelationshipTransition::Remove {
                installation_id,
                removed_at,
                preserve_history,
                removal_id,
                relationship_epoch,
            } => self.remove_relationship_with_id(
                &installation_id,
                removed_at,
                preserve_history,
                &removal_id,
                relationship_epoch,
            ),
        }
    }

    fn begin_verified_relationship(
        &mut self,
        _installation_id: &str,
        _boundary_at: i64,
    ) -> RuntimeResult<()> {
        Err(crate::RuntimeError::Unavailable(
            "verified relationship creation is not supported by this storage".to_owned(),
        ))
    }

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
    fn remove_relationship_with_id(
        &mut self,
        installation_id: &str,
        removed_at: i64,
        preserve_history: bool,
        removal_id: &str,
        relationship_epoch: i64,
    ) -> RuntimeResult<()> {
        let _ = (removal_id, relationship_epoch);
        self.remove_relationship(installation_id, removed_at, preserve_history)
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
