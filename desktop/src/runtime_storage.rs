use std::time::{SystemTime, UNIX_EPOCH};
use torchat_client_runtime::{
    ChatMessage, ContactRecord, ConversationSummary, InviteCode, PairingItem, RuntimeError,
    RuntimeIdentity, RuntimeProfile, RuntimeResult, RuntimeStorage, VerificationState,
};
use torchat_core::relay::ContactCard;

use crate::{DesktopState, store::StoredMessage};

pub(crate) struct DesktopRuntimeStorage<'a> {
    pub(crate) state: &'a mut DesktopState,
}

impl RuntimeStorage for DesktopRuntimeStorage<'_> {
    fn identity(&self) -> RuntimeResult<Option<RuntimeIdentity>> {
        Ok(Some(RuntimeIdentity::from_parts(
            self.state.identity.installation_id(),
            self.state.identity.public_key(),
            self.state.identity.fingerprint(),
        )))
    }

    fn profile(&self) -> RuntimeResult<Option<RuntimeProfile>> {
        Ok(Some(RuntimeProfile::from_parts(
            self.state.identity.installation_id(),
            self.state.nickname.clone(),
            self.state.identity.public_key(),
            self.state.identity.fingerprint(),
        )))
    }

    fn put_profile(&mut self, profile: RuntimeProfile) -> RuntimeResult<()> {
        self.state
            .store
            .put_secret("profile-nickname-v1", profile.nickname.as_bytes())
            .map_err(runtime_error)?;
        self.state.nickname = profile.nickname;
        Ok(())
    }

    fn pairing_code(&self) -> RuntimeResult<Option<InviteCode>> {
        Ok(None)
    }

    fn put_pairing_code(&mut self, code: InviteCode) -> RuntimeResult<()> {
        self.state
            .store
            .put_secret(
                "pairing-code-v1",
                &serde_json::to_vec(&code).map_err(runtime_error)?,
            )
            .map_err(runtime_error)
    }

    fn pairing_inbox(&self) -> RuntimeResult<Vec<PairingItem>> {
        Ok(torchat_client_runtime::runtime_pairing_items_from_iter(
            self.state.pairing_inbox.iter().cloned(),
        ))
    }

    fn put_pairing_inbox(&mut self, item: PairingItem) -> RuntimeResult<()> {
        let pairing_id = uuid::Uuid::parse_str(&item.pairing_id).map_err(runtime_error)?;
        let state = crate::model::PairingInboxItem {
            pairing_id,
            sender: item
                .sender
                .map(|contact| torchat_core::relay::ContactCard {
                    installation_id: contact.installation_id,
                    public_key: contact.public_key,
                    fingerprint: contact.fingerprint,
                    nickname: contact.nickname,
                })
                .ok_or_else(|| {
                    RuntimeError::InvalidParams("pairing inbox item missing sender".into())
                })?,
            capability: item.capability.ok_or_else(|| {
                RuntimeError::InvalidParams("pairing inbox item missing capability".into())
            })?,
            expires_at: item.expires_at,
            state: item.state,
            offer_invite_id: item.offer_invite_id,
            offer_payload: item.offer_payload,
        };
        self.state
            .pairing_inbox
            .retain(|value| value.pairing_id != pairing_id);
        self.state.pairing_inbox.push(state);
        self.state.persist_pairing_inbox().map_err(runtime_error)
    }

    fn pairing_outbox(&self) -> RuntimeResult<Vec<PairingItem>> {
        Ok(torchat_client_runtime::runtime_pairing_items_from_iter(
            self.state.pairing_outbox.iter().cloned(),
        ))
    }

    fn put_pairing_outbox(&mut self, item: PairingItem) -> RuntimeResult<()> {
        let pairing_id = uuid::Uuid::parse_str(&item.pairing_id).map_err(runtime_error)?;
        let state = crate::model::PairingRequestResponse {
            pairing_id,
            expires_at: item.expires_at,
            state: item.state,
        };
        self.state
            .pairing_outbox
            .retain(|value| value.pairing_id != pairing_id);
        self.state.pairing_outbox.push(state);
        self.state.persist_pairing_outbox().map_err(runtime_error)
    }

    fn contacts(&self) -> RuntimeResult<Vec<ContactRecord>> {
        self.state
            .store
            .contacts()
            .and_then(|contacts: Vec<ContactCard>| {
                contacts
                    .into_iter()
                    .map(|card| {
                        let verified = self
                            .state
                            .store
                            .contact_is_verified(&card.installation_id)?;
                        Ok(contact_record_from_card(card, verified))
                    })
                    .collect()
            })
            .map_err(runtime_error)
    }

    fn put_contact(&mut self, contact: ContactRecord) -> RuntimeResult<()> {
        let card = contact_card_from_record(&contact);
        self.state
            .store
            .put_contact(&card, "runtime")
            .and_then(|()| {
                if contact.verification == VerificationState::Verified {
                    self.state.store.verify_contact(&contact.installation_id)?;
                }
                Ok(())
            })
            .map_err(runtime_error)
    }

    fn conversations(&self) -> RuntimeResult<Vec<ConversationSummary>> {
        self.state
            .store
            .runtime_conversations()
            .map_err(runtime_error)
    }

    fn put_conversation(&mut self, conversation: ConversationSummary) -> RuntimeResult<()> {
        self.state
            .store
            .put_runtime_conversation(&conversation)
            .map_err(runtime_error)
    }

    fn mark_conversation_read(&mut self, conversation_id: &str) -> RuntimeResult<()> {
        self.state
            .store
            .mark_conversation_read(conversation_id)
            .map_err(runtime_error)
    }

    fn messages(&self, conversation_id: &str) -> RuntimeResult<Vec<ChatMessage>> {
        self.state
            .store
            .messages(conversation_id)
            .map(|messages| {
                messages
                    .into_iter()
                    .map(runtime_message_from_stored)
                    .collect()
            })
            .map_err(runtime_error)
    }

    fn message(&self, message_id: &str) -> RuntimeResult<Option<ChatMessage>> {
        self.state
            .store
            .message(message_id)
            .map(|message| message.map(runtime_message_from_stored))
            .map_err(runtime_error)
    }

    fn put_message(&mut self, message: ChatMessage) -> RuntimeResult<()> {
        let mut stored = stored_message_from_runtime(message);
        if let Ok(Some(existing)) = self.state.store.message(&stored.id) {
            stored.relay_payload = existing.relay_payload;
            stored.attempt_count = existing.attempt_count;
            stored.last_attempt_at = existing.last_attempt_at;
            stored.next_attempt_at = existing.next_attempt_at;
            stored.ack_deadline = existing.ack_deadline;
            stored.last_transport_error = existing.last_transport_error;
        }
        self.state.store.put_message(&stored).map_err(runtime_error)
    }

    fn pending_messages(&self) -> RuntimeResult<Vec<ChatMessage>> {
        self.state
            .store
            .pending_outgoing(
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|value| value.as_millis() as i64)
                    .unwrap_or_default(),
            )
            .map(|messages| {
                messages
                    .into_iter()
                    .map(runtime_message_from_stored)
                    .collect()
            })
            .map_err(runtime_error)
    }
}

fn runtime_error(error: impl std::fmt::Display) -> RuntimeError {
    RuntimeError::Storage(format!("{error:#}"))
}

fn contact_record_from_card(card: ContactCard, verified: bool) -> ContactRecord {
    ContactRecord {
        installation_id: card.installation_id,
        nickname: card.nickname,
        public_key: card.public_key,
        fingerprint: card.fingerprint,
        verification: if verified {
            VerificationState::Verified
        } else {
            VerificationState::Unverified
        },
        dev: None,
    }
}

fn contact_card_from_record(contact: &ContactRecord) -> ContactCard {
    ContactCard {
        installation_id: contact.installation_id.clone(),
        public_key: contact.public_key.clone(),
        fingerprint: contact.fingerprint.clone(),
        nickname: contact.nickname.clone(),
    }
}

fn runtime_message_from_stored(message: StoredMessage) -> ChatMessage {
    ChatMessage {
        id: message.id,
        conversation_id: message.peer,
        outgoing: message.outgoing,
        body: message.body,
        state: message.state,
        created_at: message.created_at,
        attempt_count: message.attempt_count as u32,
        last_attempt_at: message.last_attempt_at,
        next_attempt_at: message.next_attempt_at,
        ack_deadline: message.ack_deadline,
        last_transport_error: message.last_transport_error,
    }
}

fn stored_message_from_runtime(message: ChatMessage) -> StoredMessage {
    StoredMessage {
        id: message.id,
        peer: message.conversation_id,
        outgoing: message.outgoing,
        body: message.body,
        state: message.state,
        created_at: message.created_at,
        relay_payload: None,
        attempt_count: message.attempt_count as i64,
        last_attempt_at: message.last_attempt_at,
        next_attempt_at: message.next_attempt_at,
        ack_deadline: message.ack_deadline,
        last_transport_error: message.last_transport_error,
    }
}
