use crate::{
    ChatMessage, ContactRecord, ConversationSummary, InviteCode, PairingItem, ReceiptSendEffect,
    RelationshipTransition, RuntimeIdentity, RuntimeProfile, RuntimeResult, RuntimeStorage,
};

pub trait IdentityStorage {
    fn identity(&self) -> RuntimeResult<Option<RuntimeIdentity>>;
}

pub trait ProfileStorage {
    fn profile(&self) -> RuntimeResult<Option<RuntimeProfile>>;
    fn put_profile(&mut self, profile: RuntimeProfile) -> RuntimeResult<()>;
}

pub trait PairingStorage {
    fn pairing_code(&self) -> RuntimeResult<Option<InviteCode>>;
    fn put_pairing_code(&mut self, code: InviteCode) -> RuntimeResult<()>;
    fn pairing_inbox(&self) -> RuntimeResult<Vec<PairingItem>>;
    fn put_pairing_inbox(&mut self, item: PairingItem) -> RuntimeResult<()>;
    fn pairing_outbox(&self) -> RuntimeResult<Vec<PairingItem>>;
    fn put_pairing_outbox(&mut self, item: PairingItem) -> RuntimeResult<()>;
}

pub trait ContactStorage {
    fn contacts(&self) -> RuntimeResult<Vec<ContactRecord>>;
    fn put_contact(&mut self, contact: ContactRecord) -> RuntimeResult<()>;
}

pub trait RelationshipStorage {
    fn current_relationship_epoch(&mut self, installation_id: &str) -> RuntimeResult<i64>;
    fn apply_relationship_transition(
        &mut self,
        transition: RelationshipTransition,
    ) -> RuntimeResult<()>;
    fn put_relationship_removal_ack(
        &mut self,
        removal_id: &str,
        contact_installation_id: &str,
        relationship_epoch: i64,
        payload: &[u8],
    ) -> RuntimeResult<()>;
}

pub trait ConversationStorage {
    fn conversations(&self) -> RuntimeResult<Vec<ConversationSummary>>;
    fn put_conversation(&mut self, conversation: ConversationSummary) -> RuntimeResult<()>;
    fn mark_conversation_read(&mut self, conversation_id: &str) -> RuntimeResult<()>;
}

pub trait MessageStorage {
    fn messages(&self, conversation_id: &str) -> RuntimeResult<Vec<ChatMessage>>;
    fn message_by_id(&self, message_id: &str) -> RuntimeResult<Option<ChatMessage>>;
    fn put_message(&mut self, message: ChatMessage) -> RuntimeResult<()>;
    fn delete_message(&mut self, message_id: &str) -> RuntimeResult<()>;
    fn pending_messages(&self) -> RuntimeResult<Vec<ChatMessage>>;
}

pub trait ReceiptStorage {
    fn pending_receipts(&self) -> RuntimeResult<Vec<ReceiptSendEffect>>;
}

pub trait DeliveryStorage {
    fn expedite_retry_after_ready(&mut self) -> RuntimeResult<()>;
}

pub trait CapabilityStorage {
    fn put_peer_endpoint_capability(
        &mut self,
        contact_installation_id: &str,
        capability_id: &str,
        secret: &[u8],
        sequence: u64,
        issued_at: i64,
        expires_at: Option<i64>,
    ) -> RuntimeResult<()>;
    fn revoke_peer_endpoint_capability(
        &mut self,
        contact_installation_id: &str,
    ) -> RuntimeResult<()>;
}

impl<T: RuntimeStorage + ?Sized> IdentityStorage for T {
    fn identity(&self) -> RuntimeResult<Option<RuntimeIdentity>> {
        RuntimeStorage::identity(self)
    }
}

impl<T: RuntimeStorage + ?Sized> ProfileStorage for T {
    fn profile(&self) -> RuntimeResult<Option<RuntimeProfile>> {
        RuntimeStorage::profile(self)
    }

    fn put_profile(&mut self, profile: RuntimeProfile) -> RuntimeResult<()> {
        RuntimeStorage::put_profile(self, profile)
    }
}

impl<T: RuntimeStorage + ?Sized> PairingStorage for T {
    fn pairing_code(&self) -> RuntimeResult<Option<InviteCode>> {
        RuntimeStorage::pairing_code(self)
    }

    fn put_pairing_code(&mut self, code: InviteCode) -> RuntimeResult<()> {
        RuntimeStorage::put_pairing_code(self, code)
    }

    fn pairing_inbox(&self) -> RuntimeResult<Vec<PairingItem>> {
        RuntimeStorage::pairing_inbox(self)
    }

    fn put_pairing_inbox(&mut self, item: PairingItem) -> RuntimeResult<()> {
        RuntimeStorage::put_pairing_inbox(self, item)
    }

    fn pairing_outbox(&self) -> RuntimeResult<Vec<PairingItem>> {
        RuntimeStorage::pairing_outbox(self)
    }

    fn put_pairing_outbox(&mut self, item: PairingItem) -> RuntimeResult<()> {
        RuntimeStorage::put_pairing_outbox(self, item)
    }
}

impl<T: RuntimeStorage + ?Sized> ContactStorage for T {
    fn contacts(&self) -> RuntimeResult<Vec<ContactRecord>> {
        RuntimeStorage::contacts(self)
    }

    fn put_contact(&mut self, contact: ContactRecord) -> RuntimeResult<()> {
        RuntimeStorage::put_contact(self, contact)
    }
}

impl<T: RuntimeStorage + ?Sized> RelationshipStorage for T {
    fn current_relationship_epoch(&mut self, installation_id: &str) -> RuntimeResult<i64> {
        RuntimeStorage::current_relationship_epoch(self, installation_id)
    }

    fn apply_relationship_transition(
        &mut self,
        transition: RelationshipTransition,
    ) -> RuntimeResult<()> {
        RuntimeStorage::apply_relationship_transition(self, transition)
    }

    fn put_relationship_removal_ack(
        &mut self,
        removal_id: &str,
        contact_installation_id: &str,
        relationship_epoch: i64,
        payload: &[u8],
    ) -> RuntimeResult<()> {
        RuntimeStorage::put_relationship_removal_ack(
            self,
            removal_id,
            contact_installation_id,
            relationship_epoch,
            payload,
        )
    }
}

impl<T: RuntimeStorage + ?Sized> ConversationStorage for T {
    fn conversations(&self) -> RuntimeResult<Vec<ConversationSummary>> {
        RuntimeStorage::conversations(self)
    }

    fn put_conversation(&mut self, conversation: ConversationSummary) -> RuntimeResult<()> {
        RuntimeStorage::put_conversation(self, conversation)
    }

    fn mark_conversation_read(&mut self, conversation_id: &str) -> RuntimeResult<()> {
        RuntimeStorage::mark_conversation_read(self, conversation_id)
    }
}

impl<T: RuntimeStorage + ?Sized> MessageStorage for T {
    fn messages(&self, conversation_id: &str) -> RuntimeResult<Vec<ChatMessage>> {
        RuntimeStorage::messages(self, conversation_id)
    }

    fn message_by_id(&self, message_id: &str) -> RuntimeResult<Option<ChatMessage>> {
        RuntimeStorage::message_by_id(self, message_id)
    }

    fn put_message(&mut self, message: ChatMessage) -> RuntimeResult<()> {
        RuntimeStorage::put_message(self, message)
    }

    fn delete_message(&mut self, message_id: &str) -> RuntimeResult<()> {
        RuntimeStorage::delete_message(self, message_id)
    }

    fn pending_messages(&self) -> RuntimeResult<Vec<ChatMessage>> {
        RuntimeStorage::pending_messages(self)
    }
}

impl<T: RuntimeStorage + ?Sized> ReceiptStorage for T {
    fn pending_receipts(&self) -> RuntimeResult<Vec<ReceiptSendEffect>> {
        RuntimeStorage::pending_receipts(self)
    }
}

impl<T: RuntimeStorage + ?Sized> DeliveryStorage for T {
    fn expedite_retry_after_ready(&mut self) -> RuntimeResult<()> {
        RuntimeStorage::expedite_retry_after_ready(self)
    }
}

impl<T: RuntimeStorage + ?Sized> CapabilityStorage for T {
    fn put_peer_endpoint_capability(
        &mut self,
        contact_installation_id: &str,
        capability_id: &str,
        secret: &[u8],
        sequence: u64,
        issued_at: i64,
        expires_at: Option<i64>,
    ) -> RuntimeResult<()> {
        RuntimeStorage::put_peer_endpoint_capability(
            self,
            contact_installation_id,
            capability_id,
            secret,
            sequence,
            issued_at,
            expires_at,
        )
    }

    fn revoke_peer_endpoint_capability(
        &mut self,
        contact_installation_id: &str,
    ) -> RuntimeResult<()> {
        RuntimeStorage::revoke_peer_endpoint_capability(self, contact_installation_id)
    }
}
