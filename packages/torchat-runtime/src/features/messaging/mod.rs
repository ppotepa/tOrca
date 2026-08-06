use crate::{
    ChangeSet, ChatMessage, ClientRuntime, ContactStorage, ConversationStorage, FeatureResult,
    MessageSendEffect, MessageState, MessageStorage, PointLookupStorage, RuntimeClock, RuntimeError,
    RuntimeEvent, RuntimeResult, RuntimeStorage, RuntimeTransport, VerificationState,
    message_state_on_send_prepare,
};

pub struct MessagingFeature<'a, S> {
    storage: &'a mut S,
}

pub struct MessageRetryResult {
    pub effect: MessageSendEffect,
    pub message_id: uuid::Uuid,
    pub transitions: Vec<MessageState>,
}

pub struct MessageDeleteResult {
    pub message_id: uuid::Uuid,
    pub conversation_id: String,
}

impl<'a, S> MessagingFeature<'a, S>
where
    S: MessageStorage + PointLookupStorage,
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

    pub fn delete(
        &mut self,
        message_id: &str,
    ) -> RuntimeResult<FeatureResult<MessageDeleteResult>> {
        let message = self
            .storage
            .message_by_id(message_id)?
            .ok_or_else(|| RuntimeError::NotFound("message does not exist".to_owned()))?;
        let parsed_message_id = uuid::Uuid::parse_str(&message.id).map_err(|_| {
            RuntimeError::InvalidParams("message id is not a valid UUID".to_owned())
        })?;
        self.storage.delete_message(message_id)?;
        let changes = ChangeSet::default()
            .with_message(message_id)
            .with_conversation(message.conversation_id.clone());
        Ok(FeatureResult::changed(
            MessageDeleteResult {
                message_id: parsed_message_id,
                conversation_id: message.conversation_id,
            },
            changes,
        ))
    }
}

impl<'a, S> MessagingFeature<'a, S>
where
    S: MessageStorage + ConversationStorage + ContactStorage + PointLookupStorage,
{
    pub fn retry(
        &mut self,
        message_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<MessageRetryResult>> {
        let mut message = self
            .storage
            .message_by_id(message_id)?
            .ok_or_else(|| RuntimeError::NotFound("message does not exist".to_owned()))?;
        let parsed_message_id = uuid::Uuid::parse_str(&message.id).map_err(|_| {
            RuntimeError::InvalidParams("message id is not a valid UUID".to_owned())
        })?;
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

        let conversation = self
            .storage
            .conversation_by_id(&message.conversation_id)?
            .ok_or_else(|| RuntimeError::NotFound("conversation does not exist".to_owned()))?;
        if !conversation.status.can_send() {
            return Err(RuntimeError::Conflict(
                "conversation is not ready to send".to_owned(),
            ));
        }
        let contact = self
            .storage
            .contact_by_installation_id(&conversation.contact_installation_id)?
            .ok_or_else(|| RuntimeError::NotFound("recipient contact does not exist".to_owned()))?;
        if contact.verification != VerificationState::Verified {
            return Err(RuntimeError::Conflict(
                "contact must be verified before sending".to_owned(),
            ));
        }
        if contact.blocked {
            return Err(RuntimeError::Conflict("contact is blocked".to_owned()));
        }

        message.state = MessageState::Queued;
        message.next_attempt_at = now_ms;
        message.ack_deadline = None;
        message.last_transport_error = None;
        self.storage.put_message(message.clone())?;
        let mut transitions = vec![MessageState::Queued];

        let next_state = message_state_on_send_prepare(&message.state).ok_or_else(|| {
            RuntimeError::Conflict("message is not eligible for a send attempt".to_owned())
        })?;
        if next_state != message.state {
            message.state = next_state.clone();
            self.storage.put_message(message.clone())?;
            transitions.push(next_state);
        }

        let effect = MessageSendEffect {
            message_id: message.id.clone(),
            conversation_id: message.conversation_id.clone(),
            recipient_installation_id: contact.installation_id,
            body: message.body,
            reply_to: message.reply_to,
        };
        let changes = ChangeSet::default()
            .with_message(message.id)
            .with_conversation(message.conversation_id);
        Ok(FeatureResult::changed(
            MessageRetryResult {
                effect,
                message_id: parsed_message_id,
                transitions,
            },
            changes,
        ))
    }
}

/// Command-facing messaging boundary kept separate from the broad migration
/// facade so handlers cannot accidentally regain access to unrelated domains.
pub trait ClientRuntimeMessagingFacade {
    fn feature_retry_message(
        &mut self,
        message_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<MessageSendEffect>>;

    fn feature_delete_message_local(
        &mut self,
        message_id: &str,
    ) -> RuntimeResult<FeatureResult<()>>;
}

impl<S, T, C> ClientRuntimeMessagingFacade for ClientRuntime<S, T, C>
where
    S: RuntimeStorage
        + MessageStorage
        + ConversationStorage
        + ContactStorage
        + PointLookupStorage,
    T: RuntimeTransport,
    C: RuntimeClock,
{
    fn feature_retry_message(
        &mut self,
        message_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<MessageSendEffect>> {
        let result = MessagingFeature::new(self.storage_mut()).retry(message_id, now_ms)?;
        for state in &result.value.transitions {
            self.session_mut().push_event(RuntimeEvent::MessageStateChanged {
                message_id: Some(result.value.message_id),
                conversation_id: Some(result.value.effect.conversation_id.clone()),
                state: Some(state.clone()),
            });
        }
        Ok(FeatureResult {
            value: result.value.effect,
            changes: result.changes,
            effects: result.effects,
        })
    }

    fn feature_delete_message_local(
        &mut self,
        message_id: &str,
    ) -> RuntimeResult<FeatureResult<()>> {
        let result = MessagingFeature::new(self.storage_mut()).delete(message_id)?;
        self.session_mut().push_event(RuntimeEvent::MessageStateChanged {
            message_id: Some(result.value.message_id),
            conversation_id: Some(result.value.conversation_id),
            state: None,
        });
        Ok(FeatureResult {
            value: (),
            changes: result.changes,
            effects: result.effects,
        })
    }
}
