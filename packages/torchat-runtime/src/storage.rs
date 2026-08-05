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
    ApplyRemoteRemoval {
        installation_id: String,
        remote_removed_at: i64,
        removal_id: String,
        relationship_epoch: i64,
    },
}

fn unsupported(operation: &str) -> crate::RuntimeError {
    crate::RuntimeError::Unavailable(format!(
        "required storage operation is unavailable: {operation}"
    ))
}

pub trait RuntimeStorage {
    fn identity(&self) -> RuntimeResult<Option<RuntimeIdentity>>;
    fn profile(&self) -> RuntimeResult<Option<RuntimeProfile>>;
    fn put_profile(&mut self, profile: RuntimeProfile) -> RuntimeResult<()>;

    fn pairing_code(&self) -> RuntimeResult<Option<InviteCode>>;
    fn put_pairing_code(&mut self, code: InviteCode) -> RuntimeResult<()>;

    fn pairing_inbox(&self) -> RuntimeResult<Vec<PairingItem>>;
    fn pairing_inbox_by_id(&self, pairing_id: &str) -> RuntimeResult<Option<PairingItem>> {
        Ok(self
            .pairing_inbox()?
            .into_iter()
            .find(|item| item.pairing_id == pairing_id))
    }
    fn put_pairing_inbox(&mut self, item: PairingItem) -> RuntimeResult<()>;

    fn pairing_outbox(&self) -> RuntimeResult<Vec<PairingItem>>;
    fn pairing_outbox_by_id(&self, pairing_id: &str) -> RuntimeResult<Option<PairingItem>> {
        Ok(self
            .pairing_outbox()?
            .into_iter()
            .find(|item| item.pairing_id == pairing_id))
    }
    fn put_pairing_outbox(&mut self, item: PairingItem) -> RuntimeResult<()>;

    fn contacts(&self) -> RuntimeResult<Vec<ContactRecord>>;
    fn contact_by_installation_id(
        &self,
        installation_id: &str,
    ) -> RuntimeResult<Option<ContactRecord>> {
        Ok(self
            .contacts()?
            .into_iter()
            .find(|contact| contact.installation_id == installation_id))
    }
    fn put_contact(&mut self, contact: ContactRecord) -> RuntimeResult<()>;

    fn current_relationship_epoch(&mut self, _installation_id: &str) -> RuntimeResult<i64> {
        Err(unsupported("current_relationship_epoch"))
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
            RelationshipTransition::ApplyRemoteRemoval {
                installation_id,
                remote_removed_at,
                removal_id,
                relationship_epoch,
            } => self.apply_remote_relationship_removal(
                &installation_id,
                remote_removed_at,
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
        Err(unsupported("begin_verified_relationship"))
    }

    fn conversations(&self) -> RuntimeResult<Vec<ConversationSummary>>;
    fn conversation_by_id(&self, id: &str) -> RuntimeResult<Option<ConversationSummary>> {
        Ok(self
            .conversations()?
            .into_iter()
            .find(|conversation| conversation.id == id))
    }
    fn conversation_for_contact(
        &self,
        installation_id: &str,
    ) -> RuntimeResult<Option<ConversationSummary>> {
        Ok(self
            .conversations()?
            .into_iter()
            .find(|conversation| conversation.contact_installation_id == installation_id))
    }
    fn put_conversation(&mut self, conversation: ConversationSummary) -> RuntimeResult<()>;
    fn mark_conversation_read(&mut self, conversation_id: &str) -> RuntimeResult<()>;

    fn messages(&self, conversation_id: &str) -> RuntimeResult<Vec<ChatMessage>>;
    fn message_by_id(&self, message_id: &str) -> RuntimeResult<Option<ChatMessage>> {
        self.message(message_id)
    }
    fn put_message(&mut self, message: ChatMessage) -> RuntimeResult<()>;
    fn delete_message(&mut self, message_id: &str) -> RuntimeResult<()>;

    fn remove_relationship(
        &mut self,
        _installation_id: &str,
        _removed_at: i64,
        _preserve_history: bool,
    ) -> RuntimeResult<()> {
        Err(unsupported("remove_relationship"))
    }

    fn remove_relationship_with_id(
        &mut self,
        installation_id: &str,
        removed_at: i64,
        preserve_history: bool,
        _removal_id: &str,
        _relationship_epoch: i64,
    ) -> RuntimeResult<()> {
        self.remove_relationship(installation_id, removed_at, preserve_history)
    }

    fn apply_remote_relationship_removal(
        &mut self,
        _installation_id: &str,
        _remote_removed_at: i64,
        _removal_id: &str,
        _relationship_epoch: i64,
    ) -> RuntimeResult<()> {
        Err(unsupported("apply_remote_relationship_removal"))
    }

    fn put_relationship_removal_ack(
        &mut self,
        _removal_id: &str,
        _contact_installation_id: &str,
        _relationship_epoch: i64,
        _payload: &[u8],
    ) -> RuntimeResult<()> {
        Err(unsupported("put_relationship_removal_ack"))
    }

    fn pending_messages(&self) -> RuntimeResult<Vec<ChatMessage>>;

    fn pending_receipts(&self) -> RuntimeResult<Vec<ReceiptSendEffect>> {
        Err(unsupported("pending_receipts"))
    }

    fn expedite_retry_after_ready(&mut self) -> RuntimeResult<()> {
        Err(unsupported("expedite_retry_after_ready"))
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
        Err(unsupported("put_peer_endpoint_capability"))
    }

    fn revoke_peer_endpoint_capability(
        &mut self,
        _contact_installation_id: &str,
    ) -> RuntimeResult<()> {
        Err(unsupported("revoke_peer_endpoint_capability"))
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
