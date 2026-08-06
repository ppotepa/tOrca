use crate::{
    ChangeSet, ChatMessage, ClientRuntime, ContactStorage, ConversationStorage, FeatureResult,
    MessageReply, MessageSendEffect, MessageState, MessageStorage, MessageTransportOutcome,
    OperationStorage, PointLookupStorage, RuntimeClock, RuntimeError, RuntimeErrorCode,
    RuntimeEvent, RuntimeResult, RuntimeStorage, RuntimeTransport, VerificationState,
    features::operations::OperationsFeature, message_state_after_transport_outcome,
    message_state_on_send_prepare, runtime_conversation_summary_on_outgoing,
};

/// Transactional technical outbox used by message delivery workflows.
///
/// The adapter implementation must share the transaction used by
/// `MessageStorage` and `OperationStorage`.
pub trait MessageDeliveryStorage {
    fn enqueue_outbound_delivery(
        &mut self,
        message_id: &str,
        contact_installation_id: &str,
        sequence: u64,
        created_at_secs: i64,
    ) -> RuntimeResult<()>;

    fn requeue_outbound_delivery(
        &mut self,
        message_id: &str,
        retry_at: i64,
        error: &str,
    ) -> RuntimeResult<()>;

    fn complete_outbound_delivery(&mut self, message_id: &str) -> RuntimeResult<()>;
}

pub struct MessagingFeature<'a, S> {
    storage: &'a mut S,
}

pub struct MessageRetryResult {
    pub effect: MessageSendEffect,
    pub message_id: uuid::Uuid,
    pub transitions: Vec<MessageState>,
}

pub struct MessageQueueResult {
    pub effect: MessageSendEffect,
    pub message_id: uuid::Uuid,
    pub created_at: i64,
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
        PointLookupStorage::message_by_id(self.storage, message_id)
    }

    pub fn save(&mut self, message: ChatMessage) -> RuntimeResult<FeatureResult<ChatMessage>> {
        self.storage.put_message(message.clone())?;
        let changes = ChangeSet::default()
            .with_message(message.id.clone())
            .with_conversation(message.conversation_id.clone());
        Ok(FeatureResult::changed(message, changes))
    }

    pub fn delete(&mut self, message_id: &str) -> RuntimeResult<FeatureResult<()>> {
        let result = self.delete_with_context(message_id)?;
        Ok(FeatureResult {
            value: (),
            changes: result.changes,
            effects: result.effects,
        })
    }

    pub fn delete_with_context(
        &mut self,
        message_id: &str,
    ) -> RuntimeResult<FeatureResult<MessageDeleteResult>> {
        let message = PointLookupStorage::message_by_id(self.storage, message_id)?
            .ok_or_else(|| RuntimeError::NotFound("message does not exist".to_owned()))?;
        let parsed_message_id = parse_message_id(&message.id)?;
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

    pub fn apply_outcome(
        &mut self,
        message_id: &str,
        outcome: MessageTransportOutcome,
        retry_at: Option<i64>,
        error_detail: Option<&str>,
    ) -> RuntimeResult<FeatureResult<ChatMessage>> {
        let mut message = PointLookupStorage::message_by_id(self.storage, message_id)?
            .ok_or_else(|| RuntimeError::NotFound("message does not exist".to_owned()))?;
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
        match message.state {
            MessageState::Queued => {
                message.next_attempt_at = retry_at.unwrap_or(message.next_attempt_at);
                message.ack_deadline = None;
                message.last_transport_error = error_detail.map(str::to_owned);
            }
            MessageState::Failed => {
                message.next_attempt_at = 0;
                message.ack_deadline = None;
                message.last_transport_error = error_detail.map(str::to_owned);
            }
            MessageState::Sent | MessageState::Delivered | MessageState::Read => {
                message.next_attempt_at = 0;
                message.ack_deadline = None;
                message.last_transport_error = None;
            }
            MessageState::Sending => {}
        }
        self.storage.put_message(message.clone())?;
        let changes = ChangeSet::default()
            .with_message(message.id.clone())
            .with_conversation(message.conversation_id.clone());
        Ok(FeatureResult::changed(message, changes))
    }
}

impl<'a, S> MessagingFeature<'a, S>
where
    S: MessageStorage + ConversationStorage + ContactStorage + PointLookupStorage,
{
    pub fn queue(
        &mut self,
        conversation_id: &str,
        text: String,
        reply_to_message_id: Option<&str>,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<MessageQueueResult>> {
        let text = normalize_message_text(&text)?;
        let reply_to = reply_to_message_id
            .map(|message_id| {
                PointLookupStorage::message_by_id(self.storage, message_id)?.ok_or_else(|| {
                    RuntimeError::NotFound("reply message does not exist".to_owned())
                })
            })
            .transpose()?
            .map(|message| {
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
            })
            .transpose()?;

        let conversation = self
            .storage
            .conversation_by_id(conversation_id)?
            .ok_or_else(|| RuntimeError::NotFound("conversation does not exist".to_owned()))?;
        let contact = self.delivery_contact(&conversation)?;
        let message_id = uuid::Uuid::now_v7();
        let mut message = ChatMessage {
            id: message_id.to_string(),
            conversation_id: conversation_id.to_owned(),
            outgoing: true,
            body: text.clone(),
            reply_to,
            state: MessageState::Queued,
            created_at: now_ms,
            attempt_count: 0,
            last_attempt_at: None,
            next_attempt_at: now_ms,
            ack_deadline: None,
            last_transport_error: None,
        };
        let updated_conversation = runtime_conversation_summary_on_outgoing(
            Some(conversation.unread_count),
            conversation.id,
            contact.installation_id.clone(),
            text,
            now_ms,
        );
        self.storage.put_message(message.clone())?;
        self.storage.put_conversation(updated_conversation)?;
        let mut transitions = vec![MessageState::Queued];
        let next_state = message_state_on_send_prepare(&message.state).ok_or_else(|| {
            RuntimeError::Conflict("message is not eligible for a send attempt".to_owned())
        })?;
        if next_state != message.state {
            message.state = next_state.clone();
            self.storage.put_message(message.clone())?;
            transitions.push(next_state);
        }
        let effect = message_effect(&message, contact.installation_id);
        let changes = ChangeSet::default()
            .with_message(message.id.clone())
            .with_conversation(message.conversation_id.clone());
        Ok(FeatureResult::changed(
            MessageQueueResult {
                effect,
                message_id,
                created_at: now_ms,
                transitions,
            },
            changes,
        ))
    }

    pub fn retry(
        &mut self,
        message_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<MessageRetryResult>> {
        let mut message = PointLookupStorage::message_by_id(self.storage, message_id)?
            .ok_or_else(|| RuntimeError::NotFound("message does not exist".to_owned()))?;
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
        message.state = MessageState::Queued;
        message.next_attempt_at = now_ms;
        message.ack_deadline = None;
        message.last_transport_error = None;
        self.storage.put_message(message.clone())?;
        let mut result = self.prepare_existing(message, true)?;
        result.value.transitions.insert(0, MessageState::Queued);
        Ok(result)
    }

    pub fn prepare_pending(&mut self) -> RuntimeResult<Vec<FeatureResult<MessageRetryResult>>> {
        let messages = self.storage.pending_messages()?;
        let mut prepared = Vec::new();
        for message in messages.into_iter().filter(|message| {
            message.outgoing
                && matches!(message.state, MessageState::Queued | MessageState::Sending)
        }) {
            prepared.push(self.prepare_existing(message, false)?);
        }
        Ok(prepared)
    }

    fn prepare_existing(
        &mut self,
        mut message: ChatMessage,
        manual_retry: bool,
    ) -> RuntimeResult<FeatureResult<MessageRetryResult>> {
        let parsed_message_id = parse_message_id(&message.id)?;
        let conversation = self
            .storage
            .conversation_by_id(&message.conversation_id)?
            .ok_or_else(|| RuntimeError::NotFound("conversation does not exist".to_owned()))?;
        let contact = self.delivery_contact(&conversation)?;
        let next_state = message_state_on_send_prepare(&message.state).ok_or_else(|| {
            RuntimeError::Conflict("message is not eligible for a send attempt".to_owned())
        })?;
        let mut transitions = Vec::new();
        if next_state != message.state {
            message.state = next_state.clone();
            self.storage.put_message(message.clone())?;
            transitions.push(next_state);
        } else if manual_retry && message.state != MessageState::Sending {
            return Err(RuntimeError::Conflict(
                "message retry did not enter sending state".to_owned(),
            ));
        }
        let effect = message_effect(&message, contact.installation_id);
        let changes = ChangeSet::default()
            .with_message(message.id.clone())
            .with_conversation(message.conversation_id.clone());
        Ok(FeatureResult::changed(
            MessageRetryResult {
                effect,
                message_id: parsed_message_id,
                transitions,
            },
            changes,
        ))
    }

    fn delivery_contact(
        &self,
        conversation: &crate::ConversationSummary,
    ) -> RuntimeResult<crate::ContactRecord> {
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
        Ok(contact)
    }
}

/// Command and scheduler boundary for durable message delivery.
pub trait ClientRuntimeMessagingFacade {
    fn feature_queue_message_delivery(
        &mut self,
        operation_id: &str,
        command_descriptor: &str,
        conversation_id: &str,
        text: String,
        reply_to_message_id: Option<&str>,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<MessageSendEffect>>;

    fn feature_retry_message(
        &mut self,
        operation_id: &str,
        command_descriptor: &str,
        message_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<MessageSendEffect>>;

    fn feature_prepare_pending_message_deliveries(
        &mut self,
        now_ms: i64,
    ) -> RuntimeResult<Vec<MessageSendEffect>>;

    fn feature_apply_message_delivery_outcome(
        &mut self,
        message_id: &str,
        outcome: MessageTransportOutcome,
        retry_at: Option<i64>,
        error_detail: Option<&str>,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<ChatMessage>>;

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
        + PointLookupStorage
        + OperationStorage
        + MessageDeliveryStorage,
    T: RuntimeTransport,
    C: RuntimeClock,
{
    fn feature_queue_message_delivery(
        &mut self,
        operation_id: &str,
        command_descriptor: &str,
        conversation_id: &str,
        text: String,
        reply_to_message_id: Option<&str>,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<MessageSendEffect>> {
        let queued = MessagingFeature::new(self.storage_mut()).queue(
            conversation_id,
            text,
            reply_to_message_id,
            now_ms,
        )?;
        let effect = queued.value.effect.clone();
        let operation = OperationsFeature::new(self.storage_mut()).begin_message_delivery(
            operation_id,
            &effect.message_id,
            command_descriptor,
            now_ms,
        )?;
        self.storage_mut().enqueue_outbound_delivery(
            &effect.message_id,
            &effect.recipient_installation_id,
            delivery_sequence(queued.value.message_id),
            queued.value.created_at / 1_000,
        )?;
        publish_message_transitions(
            self.session_mut(),
            queued.value.message_id,
            &effect.conversation_id,
            &queued.value.transitions,
        );
        self.session_mut().push_event(RuntimeEvent::Changed {
            kind: Some("conversations".to_owned()),
        });
        let mut changes = queued.changes;
        changes.merge(operation.changes);
        Ok(FeatureResult {
            value: effect,
            changes,
            effects: queued.effects,
        })
    }

    fn feature_retry_message(
        &mut self,
        operation_id: &str,
        command_descriptor: &str,
        message_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<MessageSendEffect>> {
        let retry = MessagingFeature::new(self.storage_mut()).retry(message_id, now_ms)?;
        let effect = retry.value.effect.clone();
        let operation = OperationsFeature::new(self.storage_mut()).begin_message_delivery(
            operation_id,
            &effect.message_id,
            command_descriptor,
            now_ms,
        )?;
        self.storage_mut().enqueue_outbound_delivery(
            &effect.message_id,
            &effect.recipient_installation_id,
            delivery_sequence(retry.value.message_id),
            now_ms / 1_000,
        )?;
        publish_message_transitions(
            self.session_mut(),
            retry.value.message_id,
            &effect.conversation_id,
            &retry.value.transitions,
        );
        let mut changes = retry.changes;
        changes.merge(operation.changes);
        Ok(FeatureResult {
            value: effect,
            changes,
            effects: retry.effects,
        })
    }

    fn feature_prepare_pending_message_deliveries(
        &mut self,
        now_ms: i64,
    ) -> RuntimeResult<Vec<MessageSendEffect>> {
        let pending = MessagingFeature::new(self.storage_mut()).prepare_pending()?;
        let mut effects = Vec::with_capacity(pending.len());
        for prepared in pending {
            let effect = prepared.value.effect.clone();
            let operation_id = format!("message-delivery:{}", effect.message_id);
            let descriptor = format!("message_delivery:{}", effect.message_id);
            OperationsFeature::new(self.storage_mut()).begin_message_delivery(
                &operation_id,
                &effect.message_id,
                &descriptor,
                now_ms,
            )?;
            self.storage_mut().enqueue_outbound_delivery(
                &effect.message_id,
                &effect.recipient_installation_id,
                delivery_sequence(prepared.value.message_id),
                now_ms / 1_000,
            )?;
            publish_message_transitions(
                self.session_mut(),
                prepared.value.message_id,
                &effect.conversation_id,
                &prepared.value.transitions,
            );
            effects.push(effect);
        }
        Ok(effects)
    }

    fn feature_apply_message_delivery_outcome(
        &mut self,
        message_id: &str,
        outcome: MessageTransportOutcome,
        retry_at: Option<i64>,
        error_detail: Option<&str>,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<ChatMessage>> {
        let operation_changes = match outcome {
            MessageTransportOutcome::PeerUnavailable
            | MessageTransportOutcome::RetryableFailure => {
                let retry_at = retry_at.unwrap_or(now_ms);
                self.storage_mut().requeue_outbound_delivery(
                    message_id,
                    retry_at,
                    error_detail.unwrap_or("retry"),
                )?;
                OperationsFeature::new(self.storage_mut())
                    .retry_message_delivery(
                        message_id,
                        retry_at,
                        RuntimeErrorCode::TransportUnavailable,
                        now_ms,
                    )?
                    .changes
            }
            MessageTransportOutcome::PermanentFailure
            | MessageTransportOutcome::PeerAuthenticationFailed
            | MessageTransportOutcome::PeerRejected => {
                self.storage_mut().complete_outbound_delivery(message_id)?;
                OperationsFeature::new(self.storage_mut())
                    .fail_message_delivery(message_id, outcome_error_code(outcome), now_ms)?
                    .changes
            }
            MessageTransportOutcome::Delivered
            | MessageTransportOutcome::PeerPersisted
            | MessageTransportOutcome::PeerDelivered => {
                self.storage_mut().complete_outbound_delivery(message_id)?;
                OperationsFeature::new(self.storage_mut())
                    .complete_message_delivery(message_id, now_ms)?
                    .changes
            }
        };
        let message = MessagingFeature::new(self.storage_mut()).apply_outcome(
            message_id,
            outcome,
            retry_at,
            error_detail,
        )?;
        if !message.changes.sections.is_empty() {
            self.session_mut()
                .push_event(RuntimeEvent::MessageStateChanged {
                    message_id: Some(parse_message_id(&message.value.id)?),
                    conversation_id: Some(message.value.conversation_id.clone()),
                    state: Some(message.value.state.clone()),
                });
        }
        let mut changes = message.changes;
        changes.merge(operation_changes);
        Ok(FeatureResult {
            value: message.value,
            changes,
            effects: message.effects,
        })
    }

    fn feature_delete_message_local(
        &mut self,
        message_id: &str,
    ) -> RuntimeResult<FeatureResult<()>> {
        let result = MessagingFeature::new(self.storage_mut()).delete_with_context(message_id)?;
        self.session_mut()
            .push_event(RuntimeEvent::MessageStateChanged {
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

fn publish_message_transitions(
    session: &mut crate::RuntimeSession,
    message_id: uuid::Uuid,
    conversation_id: &str,
    transitions: &[MessageState],
) {
    for state in transitions {
        session.push_event(RuntimeEvent::MessageStateChanged {
            message_id: Some(message_id),
            conversation_id: Some(conversation_id.to_owned()),
            state: Some(state.clone()),
        });
    }
}

fn message_effect(message: &ChatMessage, recipient_installation_id: String) -> MessageSendEffect {
    MessageSendEffect {
        message_id: message.id.clone(),
        conversation_id: message.conversation_id.clone(),
        recipient_installation_id,
        body: message.body.clone(),
        reply_to: message.reply_to.clone(),
    }
}

fn normalize_message_text(text: &str) -> RuntimeResult<String> {
    let normalized = text.trim();
    if normalized.is_empty() {
        return Err(RuntimeError::InvalidParams(
            "message text must not be empty".to_owned(),
        ));
    }
    Ok(normalized.to_owned())
}

fn parse_message_id(message_id: &str) -> RuntimeResult<uuid::Uuid> {
    uuid::Uuid::parse_str(message_id)
        .map_err(|_| RuntimeError::InvalidParams("message id is not a valid UUID".to_owned()))
}

fn delivery_sequence(message_id: uuid::Uuid) -> u64 {
    let bytes = message_id.as_bytes();
    let mut sequence = [0_u8; 8];
    sequence.copy_from_slice(&bytes[..8]);
    u64::from_be_bytes(sequence).max(1)
}

fn outcome_error_code(outcome: MessageTransportOutcome) -> RuntimeErrorCode {
    match outcome {
        MessageTransportOutcome::PeerAuthenticationFailed => RuntimeErrorCode::CryptoFailed,
        MessageTransportOutcome::PeerRejected => RuntimeErrorCode::Conflict,
        MessageTransportOutcome::PermanentFailure => RuntimeErrorCode::TransportUnavailable,
        MessageTransportOutcome::PeerUnavailable
        | MessageTransportOutcome::RetryableFailure
        | MessageTransportOutcome::Delivered
        | MessageTransportOutcome::PeerPersisted
        | MessageTransportOutcome::PeerDelivered => RuntimeErrorCode::TransportUnavailable,
    }
}
