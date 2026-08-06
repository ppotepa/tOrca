use crate::{
    ChangeSet, ChatMessage, ContactStorage, ConversationStorage, DomainEffect, FeatureResult,
    MessageReply, MessageSendEffect, MessageState, MessageStorage, MessageTransportOutcome,
    PointLookupStorage, RuntimeError, RuntimeResult, VerificationState,
    message_state_after_transport_outcome, message_state_on_send_prepare,
    runtime_conversation_summary_on_incoming, runtime_conversation_summary_on_outgoing,
};
use uuid::Uuid;

pub struct MessagingFeature<'a, S> {
    storage: &'a mut S,
}

impl<'a, S> MessagingFeature<'a, S>
where
    S: MessageStorage + ConversationStorage + ContactStorage + PointLookupStorage,
{
    pub fn new(storage: &'a mut S) -> Self {
        Self { storage }
    }

    pub fn by_id(&self, message_id: &str) -> RuntimeResult<Option<ChatMessage>> {
        self.storage.message_by_id(message_id)
    }

    pub fn save(&mut self, message: ChatMessage) -> RuntimeResult<FeatureResult<ChatMessage>> {
        self.storage.put_message(message.clone())?;
        let changes = ChangeSet::default()
            .with_message(message.id.clone())
            .with_conversation(message.conversation_id.clone());
        Ok(FeatureResult::changed(message, changes))
    }

    pub fn delete(&mut self, message_id: &str) -> RuntimeResult<FeatureResult<()>> {
        let conversation_id = self
            .storage
            .message_by_id(message_id)?
            .map(|message| message.conversation_id)
            .ok_or_else(|| RuntimeError::NotFound("message does not exist".to_owned()))?;
        self.storage.delete_message(message_id)?;
        Ok(FeatureResult::changed(
            (),
            ChangeSet::default()
                .with_message(message_id)
                .with_conversation(conversation_id),
        ))
    }

    pub fn queue_outgoing(
        &mut self,
        conversation_id: &str,
        text: String,
        reply_to_message_id: Option<&str>,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<MessageSendEffect>> {
        let text = validate_message_text(&text)?;
        let conversation = self.require_sendable_conversation(conversation_id)?;
        let contact = self.require_sendable_contact(&conversation.contact_installation_id)?;
        let reply_to = reply_to_message_id
            .map(|message_id| self.reply_snapshot(conversation_id, message_id))
            .transpose()?;
        let message_id = Uuid::now_v7().to_string();
        let mut message = ChatMessage {
            id: message_id.clone(),
            conversation_id: conversation_id.to_owned(),
            outgoing: true,
            body: text.clone(),
            reply_to: reply_to.clone(),
            state: MessageState::Queued,
            created_at: now_ms,
            attempt_count: 0,
            last_attempt_at: None,
            next_attempt_at: 0,
            ack_deadline: None,
            last_transport_error: None,
        };
        let updated_conversation = runtime_conversation_summary_on_outgoing(
            Some(conversation.unread_count),
            conversation.id,
            contact.installation_id.clone(),
            text.clone(),
            now_ms,
        );
        self.storage.put_message(message.clone())?;
        self.storage.put_conversation(updated_conversation)?;
        message.state = message_state_on_send_prepare(&message.state).ok_or_else(|| {
            RuntimeError::Conflict("message is not eligible for a send attempt".to_owned())
        })?;
        self.storage.put_message(message.clone())?;
        let changes = ChangeSet::default()
            .with_message(message_id.clone())
            .with_conversation(conversation_id);
        Ok(FeatureResult::changed(
            MessageSendEffect {
                message_id: message_id.clone(),
                conversation_id: conversation_id.to_owned(),
                recipient_installation_id: contact.installation_id,
                body: text,
                reply_to,
            },
            changes,
        )
        .with_effect(DomainEffect::DeliverMessage {
            message_id,
        }))
    }

    pub fn retry(
        &mut self,
        message_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<MessageSendEffect>> {
        let mut message = self.require_message(message_id)?;
        if !message.outgoing {
            return Err(RuntimeError::Conflict(
                "incoming message cannot be retried".to_owned(),
            ));
        }
        if !matches!(message.state, MessageState::Failed | MessageState::Queued) {
            return Err(RuntimeError::Conflict(
                "message is not eligible for manual retry".to_owned(),
            ));
        }
        let conversation = self.require_sendable_conversation(&message.conversation_id)?;
        let contact = self.require_sendable_contact(&conversation.contact_installation_id)?;
        message.state = MessageState::Queued;
        message.next_attempt_at = now_ms;
        message.ack_deadline = None;
        message.last_transport_error = None;
        message.state = message_state_on_send_prepare(&message.state).ok_or_else(|| {
            RuntimeError::Conflict("message is not eligible for a send attempt".to_owned())
        })?;
        self.storage.put_message(message.clone())?;
        let effect = MessageSendEffect {
            message_id: message.id.clone(),
            conversation_id: message.conversation_id.clone(),
            recipient_installation_id: contact.installation_id,
            body: message.body,
            reply_to: message.reply_to,
        };
        Ok(FeatureResult::changed(
            effect,
            ChangeSet::default()
                .with_message(message.id.clone())
                .with_conversation(message.conversation_id),
        )
        .with_effect(DomainEffect::DeliverMessage {
            message_id: message.id,
        }))
    }

    pub fn apply_read(&mut self, message_id: &str) -> RuntimeResult<FeatureResult<ChatMessage>> {
        let mut message = self.require_message(message_id)?;
        if !message.outgoing {
            return Err(RuntimeError::Conflict(
                "incoming message cannot receive a read receipt".to_owned(),
            ));
        }
        if message.state == MessageState::Read {
            return Ok(FeatureResult::unchanged(message));
        }
        if !matches!(message.state, MessageState::Sent | MessageState::Delivered) {
            return Err(RuntimeError::Conflict(
                "message is not eligible for a read receipt".to_owned(),
            ));
        }
        message.state = MessageState::Read;
        self.save(message)
    }

    pub fn apply_transport_outcome(
        &mut self,
        message_id: &str,
        outcome: MessageTransportOutcome,
    ) -> RuntimeResult<FeatureResult<ChatMessage>> {
        let mut message = self.require_message(message_id)?;
        if !message.outgoing {
            return Err(RuntimeError::Conflict(
                "incoming message state is owned by receive_message".to_owned(),
            ));
        }
        let next_state = message_state_after_transport_outcome(&message.state, outcome)
            .ok_or_else(|| {
                RuntimeError::Conflict(
                    "transport outcome is invalid for the current message state".to_owned(),
                )
            })?;
        if next_state == message.state {
            return Ok(FeatureResult::unchanged(message));
        }
        message.state = next_state;
        self.save(message)
    }

    pub fn receive(
        &mut self,
        conversation_id: &str,
        body: String,
        message_id: Option<Uuid>,
        reply_to: Option<MessageReply>,
        attended: bool,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<ChatMessage>> {
        let body = validate_message_text(&body)?;
        let message_id = message_id.unwrap_or_else(Uuid::now_v7);
        if let Some(existing) = self.storage.message_by_id(&message_id.to_string())? {
            if existing.outgoing
                || existing.conversation_id != conversation_id
                || existing.body != body
            {
                return Err(RuntimeError::Conflict(
                    "incoming message id has different content".to_owned(),
                ));
            }
            return Ok(FeatureResult::unchanged(existing));
        }
        let existing = self.storage.conversation_by_id(conversation_id)?;
        let message = ChatMessage {
            id: message_id.to_string(),
            conversation_id: conversation_id.to_owned(),
            outgoing: false,
            body: body.clone(),
            reply_to,
            state: MessageState::Delivered,
            created_at: now_ms,
            attempt_count: 0,
            last_attempt_at: None,
            next_attempt_at: 0,
            ack_deadline: None,
            last_transport_error: None,
        };
        let conversation = runtime_conversation_summary_on_incoming(
            existing.as_ref().map(|value| value.unread_count),
            existing
                .as_ref()
                .map(|value| value.id.clone())
                .unwrap_or_else(|| conversation_id.to_owned()),
            existing
                .as_ref()
                .map(|value| value.contact_installation_id.clone())
                .unwrap_or_else(|| conversation_id.to_owned()),
            body,
            now_ms,
            attended,
        );
        self.storage.put_message(message.clone())?;
        self.storage.put_conversation(conversation)?;
        Ok(FeatureResult::changed(
            message,
            ChangeSet::default()
                .with_message(message_id.to_string())
                .with_conversation(conversation_id),
        ))
    }

    pub fn pending_send_effects(&mut self) -> RuntimeResult<Vec<MessageSendEffect>> {
        let message_ids = self
            .storage
            .pending_messages()?
            .into_iter()
            .filter(|message| message.outgoing)
            .map(|message| message.id)
            .collect::<Vec<_>>();
        message_ids
            .into_iter()
            .map(|message_id| self.prepare_existing_send(&message_id))
            .collect()
    }

    fn prepare_existing_send(&mut self, message_id: &str) -> RuntimeResult<MessageSendEffect> {
        let mut message = self.require_message(message_id)?;
        let conversation = self.require_sendable_conversation(&message.conversation_id)?;
        let contact = self.require_sendable_contact(&conversation.contact_installation_id)?;
        let next_state = message_state_on_send_prepare(&message.state).ok_or_else(|| {
            RuntimeError::Conflict("message is not eligible for a send attempt".to_owned())
        })?;
        if next_state != message.state {
            message.state = next_state;
            self.storage.put_message(message.clone())?;
        }
        Ok(MessageSendEffect {
            message_id: message.id,
            conversation_id: message.conversation_id,
            recipient_installation_id: contact.installation_id,
            body: message.body,
            reply_to: message.reply_to,
        })
    }

    fn require_message(&self, message_id: &str) -> RuntimeResult<ChatMessage> {
        self.storage
            .message_by_id(message_id)?
            .ok_or_else(|| RuntimeError::NotFound("message does not exist".to_owned()))
    }

    fn require_sendable_conversation(
        &self,
        conversation_id: &str,
    ) -> RuntimeResult<crate::ConversationSummary> {
        let conversation = self
            .storage
            .conversation_by_id(conversation_id)?
            .ok_or_else(|| RuntimeError::NotFound("conversation does not exist".to_owned()))?;
        if !conversation.status.can_send() {
            return Err(RuntimeError::Conflict(
                "conversation is not ready to send".to_owned(),
            ));
        }
        Ok(conversation)
    }

    fn require_sendable_contact(&self, installation_id: &str) -> RuntimeResult<crate::ContactRecord> {
        let contact = self
            .storage
            .contact_by_installation_id(installation_id)?
            .ok_or_else(|| RuntimeError::NotFound("recipient contact does not exist".to_owned()))?;
        if contact.verification != VerificationState::Verified {
            return Err(RuntimeError::Conflict(
                "contact must be verified before sending".to_owned(),
            ));
        }
        if contact.blocked {
            return Err(RuntimeError::Conflict("contact is blocked".to_owned()));
        }
        Ok(contact)
    }

    fn reply_snapshot(&self, conversation_id: &str, message_id: &str) -> RuntimeResult<MessageReply> {
        let message = self.require_message(message_id)?;
        if message.conversation_id != conversation_id {
            return Err(RuntimeError::Conflict(
                "reply message belongs to another conversation".to_owned(),
            ));
        }
        Ok(MessageReply {
            message_id: message.id,
            body: message.body,
            outgoing: message.outgoing,
        })
    }
}

fn validate_message_text(text: &str) -> RuntimeResult<String> {
    let normalized = text.trim();
    if normalized.is_empty() {
        return Err(RuntimeError::InvalidParams(
            "message text must not be empty".to_owned(),
        ));
    }
    Ok(normalized.to_owned())
}
