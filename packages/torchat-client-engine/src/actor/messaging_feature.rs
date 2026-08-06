use super::*;

impl ClientEngineActor {
    pub(super) fn send_message_feature_command(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        conversation_id: &str,
        body: String,
        reply_to_message_id: Option<&str>,
    ) -> EngineResult<(MessageSendEffect, Vec<torchat_runtime::RuntimeEvent>)> {
        let peer_installation_id = self
            .database
            .conversation_by_id(conversation_id)
            .map_err(runtime_error)?
            .map(|conversation| conversation.contact_installation_id)
            .ok_or_else(|| EngineError::InvalidCommand("conversation does not exist".to_owned()))?;
        let mut conversation = self
            .conversations
            .remove(&peer_installation_id)
            .ok_or_else(|| {
                EngineError::InvalidCommand(
                    "contact requires MLS welcome before sending".to_owned(),
                )
            })?;
        let snapshot_before = conversation
            .snapshot()
            .map_err(|error| EngineError::Storage(error.to_string()))?;
        let now_ms = self.clock.now_ms();
        let next_attempt_at = now_ms + retry_backoff_ms(0);
        let ack_deadline = Some(now_ms + 60_000);
        let operation_id = idempotency.map(|context| context.command_id.clone());

        let transaction_result = self.with_runtime_idempotent(
            idempotency,
            |runtime| {
                if let Some(operation_id) = operation_id.as_deref() {
                    torchat_runtime::ClientOperationFeatureFacade::feature_begin_operation(
                        runtime,
                        operation_id,
                        torchat_runtime::OperationType::MessageDelivery,
                        conversation_id,
                        now_ms,
                    )?;
                }
                let feature = torchat_runtime::ClientRuntimeFeatureFacade::feature_queue_message(
                    runtime,
                    conversation_id,
                    body,
                    reply_to_message_id,
                    now_ms,
                )?;
                let effect = feature.value;
                let stored = torchat_runtime::ClientRuntimeFeatureFacade::feature_message_by_id(
                    runtime,
                    &effect.message_id,
                )?
                .ok_or_else(|| {
                    RuntimeError::Storage(
                        "new outgoing message is missing from the active transaction".to_owned(),
                    )
                })?;
                let message_id = uuid::Uuid::parse_str(&effect.message_id)
                    .map_err(|error| RuntimeError::Storage(error.to_string()))?;
                let plaintext = ApplicationPayloadV1::Message {
                    version: torchat_core::PROTOCOL_VERSION,
                    message_id,
                    sent_at: stored.created_at,
                    body: effect.body.clone(),
                    reply_to: effect
                        .reply_to
                        .clone()
                        .map(|reply| {
                            Ok::<_, RuntimeError>(ApplicationReply {
                                message_id: uuid::Uuid::parse_str(&reply.message_id)
                                    .map_err(|error| RuntimeError::Storage(error.to_string()))?,
                                body: reply.body,
                                outgoing: reply.outgoing,
                            })
                        })
                        .transpose()?,
                }
                .encode()
                .map_err(RuntimeError::Storage)?;
                let encrypted = conversation
                    .encrypt(&plaintext)
                    .map_err(RuntimeError::Storage)?;
                let payload = PeerCiphertextPayload::new(&encrypted)
                    .encode()
                    .map_err(RuntimeError::Storage)?;
                let snapshot_after = conversation.snapshot().map_err(RuntimeError::Storage)?;
                runtime.storage_mut().persist_outbound_encryption(
                    &effect.message_id,
                    payload.as_bytes(),
                    &effect.conversation_id,
                    &snapshot_after,
                )?;
                if !runtime.storage_mut().claim_outgoing_attempt(
                    &effect.message_id,
                    next_attempt_at,
                    ack_deadline,
                    None,
                    now_ms,
                )? {
                    return Err(RuntimeError::Storage(
                        "new outgoing message could not be claimed for delivery".to_owned(),
                    ));
                }
                Ok((effect, payload))
            },
            |(effect, _)| json_response(effect),
        );

        let ((effect, payload), mut runtime_events) = match transaction_result {
            Ok(value) => value,
            Err(error) => {
                let restored =
                    DirectConversation::restore(&snapshot_before).map_err(|restore_error| {
                        EngineError::Storage(format!(
                            "restore MLS conversation after send rollback: {restore_error}"
                        ))
                    })?;
                self.conversations.insert(peer_installation_id, restored);
                return Err(error);
            }
        };
        self.conversations
            .insert(peer_installation_id.clone(), conversation);

        let envelope_id = uuid::Uuid::parse_str(&effect.message_id)
            .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
        let sequence = stable_message_sequence(envelope_id);
        match self.dispatch_outbound_message(&effect, envelope_id, sequence, payload) {
            Ok(mut events) => {
                runtime_events.append(&mut events);
                if let Some(operation_id) = operation_id.as_deref() {
                    let completed_at = self.clock.now_ms();
                    let (_, mut operation_events) = self.with_runtime(|runtime| {
                        torchat_runtime::ClientOperationFeatureFacade::feature_complete_operation(
                            runtime,
                            operation_id,
                            completed_at,
                        )
                        .map(|_| ())
                    })?;
                    runtime_events.append(&mut operation_events);
                }
                Ok((effect, runtime_events))
            }
            Err(error) => {
                if let Some(operation_id) = operation_id.as_deref() {
                    let failed_at = self.clock.now_ms();
                    let _ = self.with_runtime(|runtime| {
                        torchat_runtime::ClientOperationFeatureFacade::feature_retry_operation(
                            runtime,
                            operation_id,
                            torchat_runtime::RetryClass::NetworkBackoff,
                            torchat_runtime::RuntimeErrorCode::TransportUnavailable,
                            failed_at,
                        )
                        .map(|_| ())
                    });
                }
                Err(error)
            }
        }
    }
}
