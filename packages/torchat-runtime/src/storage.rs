use crate::{
    ChatMessage, ContactRecord, ConversationSummary, DurableOperation, InviteCode, OperationId,
    PairingItem, ReceiptSendEffect, RuntimeIdentity, RuntimeProfile, RuntimeResult,
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

/// Transitional aggregate retained for existing adapters.
///
/// New domain code must depend on the capability traits or `RuntimeStoragePort`.
/// Point lookups intentionally do not fall back to full collection scans.
pub trait RuntimeStorage {
    fn identity(&self) -> RuntimeResult<Option<RuntimeIdentity>>;
    fn profile(&self) -> RuntimeResult<Option<RuntimeProfile>>;
    fn put_profile(&mut self, profile: RuntimeProfile) -> RuntimeResult<()>;

    fn pairing_code(&self) -> RuntimeResult<Option<InviteCode>>;
    fn put_pairing_code(&mut self, code: InviteCode) -> RuntimeResult<()>;

    fn pairing_inbox(&self) -> RuntimeResult<Vec<PairingItem>>;
    fn pairing_inbox_by_id(&self, _pairing_id: &str) -> RuntimeResult<Option<PairingItem>> {
        Err(unsupported("pairing_inbox_by_id"))
    }
    fn put_pairing_inbox(&mut self, item: PairingItem) -> RuntimeResult<()>;

    fn pairing_outbox(&self) -> RuntimeResult<Vec<PairingItem>>;
    fn pairing_outbox_by_id(&self, _pairing_id: &str) -> RuntimeResult<Option<PairingItem>> {
        Err(unsupported("pairing_outbox_by_id"))
    }
    fn put_pairing_outbox(&mut self, item: PairingItem) -> RuntimeResult<()>;

    fn contacts(&self) -> RuntimeResult<Vec<ContactRecord>>;
    fn contact_by_installation_id(
        &self,
        _installation_id: &str,
    ) -> RuntimeResult<Option<ContactRecord>> {
        Err(unsupported("contact_by_installation_id"))
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
    fn conversation_by_id(&self, _id: &str) -> RuntimeResult<Option<ConversationSummary>> {
        Err(unsupported("conversation_by_id"))
    }
    fn conversation_for_contact(
        &self,
        _installation_id: &str,
    ) -> RuntimeResult<Option<ConversationSummary>> {
        Err(unsupported("conversation_for_contact"))
    }
    fn put_conversation(&mut self, conversation: ConversationSummary) -> RuntimeResult<()>;
    fn mark_conversation_read(&mut self, conversation_id: &str) -> RuntimeResult<()>;

    fn messages(&self, conversation_id: &str) -> RuntimeResult<Vec<ChatMessage>>;
    fn message_by_id(&self, _message_id: &str) -> RuntimeResult<Option<ChatMessage>> {
        Err(unsupported("message_by_id"))
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
        _installation_id: &str,
        _removed_at: i64,
        _preserve_history: bool,
        _removal_id: &str,
        _relationship_epoch: i64,
    ) -> RuntimeResult<()> {
        Err(unsupported("remove_relationship_with_id"))
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

    fn operation_by_id(
        &self,
        _operation_id: &OperationId,
    ) -> RuntimeResult<Option<DurableOperation>> {
        Err(unsupported("operation_by_id"))
    }

    fn put_operation(&mut self, _operation: DurableOperation) -> RuntimeResult<()> {
        Err(unsupported("put_operation"))
    }

    fn pending_operations(&self) -> RuntimeResult<Vec<DurableOperation>> {
        Err(unsupported("pending_operations"))
    }

    fn message(&self, message_id: &str) -> RuntimeResult<Option<ChatMessage>> {
        self.message_by_id(message_id)
    }
}
