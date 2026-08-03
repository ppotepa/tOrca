use super::*;

impl ClientEngineActor {
    pub(super) fn send_message_command(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        conversation_id: &str,
        body: String,
        reply_to_message_id: Option<&str>,
    ) -> EngineResult<(MessageSendEffect, Vec<torchat_client_runtime::RuntimeEvent>)> {
        let peer_installation_id = self
            .list_conversations()?
            .into_iter()
            .find(|conversation| conversation.id == conversation_id)
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
        let now_ms = unix_ms();
        let next_attempt_at = now_ms + retry_backoff_ms(0);
        let ack_deadline = Some(now_ms + 60_000);

        let transaction_result = self.with_runtime_idempotent(
            idempotency,
            |runtime| {
                let effect =
                    runtime.send_message_reply(conversation_id, body, reply_to_message_id)?;
                let stored = runtime
                    .storage()
                    .message(&effect.message_id)?
                    .ok_or_else(|| {
                        RuntimeError::Storage(
                            "new outgoing message is missing from the active transaction"
                                .to_owned(),
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
        runtime_events.append(&mut self.dispatch_outbound_message(
            &effect,
            envelope_id,
            sequence,
            payload,
        )?);
        Ok((effect, runtime_events))
    }

    pub(super) fn dispatch_outbound_message(
        &mut self,
        message: &torchat_client_runtime::MessageSendEffect,
        envelope_id: uuid::Uuid,
        sequence: u64,
        payload: String,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        self.database.enqueue_outbound_delivery(
            &message.message_id,
            &message.recipient_installation_id,
            sequence,
            unix_secs(),
        )?;
        let policy = self.contact_transport_policy(&message.recipient_installation_id)?;
        self.pending_engine_events.push(EngineEvent::Log {
            log: EngineLogEvent {
                level: "info".to_owned(),
                message: format!(
                    "delivery route selected message_id={} policy={:?}",
                    message.message_id, policy
                ),
            },
        });
        let peer_result = if matches!(policy, ContactTransportPolicy::RelayOnly) {
            Err(EngineError::Transport(
                "peer route disabled by contact policy".to_owned(),
            ))
        } else {
            self.queue_peer_payload(
                envelope_id,
                &message.recipient_installation_id,
                &message.conversation_id,
                sequence,
                payload.clone().into_bytes(),
                PeerDeliveryTag::Message {
                    message_id: message.message_id.clone(),
                },
            )
        };
        if let Err(error) = peer_result {
            return self.handle_failed_peer_message_delivery(
                &message.recipient_installation_id,
                &message.message_id,
                &error.to_string(),
            );
        }
        Ok(Vec::new())
    }

    pub(super) fn handle_failed_peer_message_delivery(
        &mut self,
        installation_id: &str,
        message_id: &str,
        error: &str,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        let policy = self.contact_transport_policy(installation_id)?;
        let payload = self
            .database
            .message(message_id)?
            .and_then(|message| message.wire_ciphertext)
            .ok_or_else(|| {
                EngineError::Storage("outbound wire ciphertext is missing".to_owned())
            })?;
        let payload = String::from_utf8(payload).map_err(|decode_error| {
            EngineError::Storage(format!(
                "stored wire ciphertext is invalid UTF-8: {decode_error}"
            ))
        })?;
        let envelope_id = uuid::Uuid::parse_str(message_id)
            .map_err(|parse_error| EngineError::InvalidCommand(parse_error.to_string()))?;
        if matches!(
            policy,
            ContactTransportPolicy::PeerWithRelayFallback | ContactTransportPolicy::RelayOnly
        ) && self
            .queue_relay_envelope(
                envelope_id,
                installation_id,
                &payload,
                PendingRelayDelivery::Message {
                    message_id: message_id.to_owned(),
                },
            )
            .is_ok()
        {
            self.pending_engine_events.push(EngineEvent::Log {
                log: EngineLogEvent {
                    level: "warn".to_owned(),
                    message: format!(
                        "delivery route fallback message_id={} route=relay error={error}",
                        message_id
                    ),
                },
            });
            return Ok(Vec::new());
        }
        let delivery = self.database.outbound_delivery(message_id)?;
        let attempt = delivery
            .as_ref()
            .map(|record| record.attempt_count)
            .unwrap_or(0);
        let age_exhausted = delivery.as_ref().is_some_and(|record| {
            super::RetryPolicy::DELIVERY
                .age_exhausted(record.created_at.saturating_mul(1_000), unix_ms())
        });
        if matches!(
            super::classify_retry_error(error),
            super::RetryDisposition::Permanent | super::RetryDisposition::Protocol
        ) || super::RetryPolicy::DELIVERY.exhausted(attempt)
            || age_exhausted
        {
            let error_code = match super::classify_retry_error(error) {
                super::RetryDisposition::Protocol => "protocol",
                super::RetryDisposition::Authentication => "authentication",
                super::RetryDisposition::Permanent => "permanent",
                super::RetryDisposition::Transient => "retry_exhausted",
            };
            self.database
                .connection()
                .execute(
                    "UPDATE messages SET dead_lettered_at = unixepoch(), last_error_code = ?1 WHERE id = ?2;",
                    rusqlite::params![error_code, message_id],
                )
                .map_err(|error| EngineError::Storage(error.to_string()))?;
            self.database.complete_outbound_delivery(message_id)?;
            if super::RetryPolicy::DELIVERY.exhausted(attempt) || age_exhausted {
                self.database.record_delivery_dead_letter(
                    "message",
                    message_id,
                    Some(installation_id),
                    attempt,
                    error,
                )?;
            }
            self.apply_message_transport_outcome(
                message_id,
                MessageTransportOutcome::PermanentFailure,
            )
        } else {
            self.database.requeue_outbound_delivery(
                message_id,
                self.clock.now_ms() + retry_backoff_ms(attempt),
                error,
            )?;
            self.apply_message_transport_outcome(
                message_id,
                MessageTransportOutcome::PeerUnavailable,
            )
        }
    }

    pub(super) fn prepare_outbound_message_payload(
        &mut self,
        effect: &torchat_client_runtime::MessageSendEffect,
    ) -> EngineResult<String> {
        let message_id = uuid::Uuid::parse_str(&effect.message_id)
            .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
        let stored = self.database.message(&effect.message_id)?.ok_or_else(|| {
            EngineError::Storage("runtime message is missing from engine store".to_owned())
        })?;
        let next_attempt_at = self.clock.now_ms() + retry_backoff_ms(stored.attempt_count);
        let ack_deadline = Some(unix_ms() + 60_000);
        if let Some(existing) = stored.wire_ciphertext {
            if !self.database.claim_outgoing_attempt(
                &effect.message_id,
                next_attempt_at,
                ack_deadline,
                None,
            )? {
                return Err(EngineError::Storage(
                    "outgoing message could not be claimed for retry".to_owned(),
                ));
            }
            return String::from_utf8(existing).map_err(|error| {
                EngineError::Storage(format!("stored wire ciphertext is invalid UTF-8: {error}"))
            });
        }

        let mut conversation = self
            .conversations
            .remove(&effect.recipient_installation_id)
            .ok_or_else(|| {
                EngineError::InvalidCommand(
                    "contact requires MLS welcome before sending".to_owned(),
                )
            })?;
        let snapshot_before = conversation
            .snapshot()
            .map_err(|error| EngineError::Storage(error.to_string()))?;
        let encryption_result = (|| {
            let plaintext = ApplicationPayloadV1::Message {
                version: torchat_core::PROTOCOL_VERSION,
                message_id,
                sent_at: stored.created_at,
                body: effect.body.clone(),
                reply_to: effect
                    .reply_to
                    .clone()
                    .map(|reply| {
                        Ok::<_, EngineError>(ApplicationReply {
                            message_id: uuid::Uuid::parse_str(&reply.message_id)
                                .map_err(|error| EngineError::InvalidCommand(error.to_string()))?,
                            body: reply.body,
                            outgoing: reply.outgoing,
                        })
                    })
                    .transpose()?,
            }
            .encode()
            .map_err(EngineError::InvalidCommand)?;
            let encrypted = conversation
                .encrypt(&plaintext)
                .map_err(EngineError::InvalidCommand)?;
            let payload = PeerCiphertextPayload::new(&encrypted)
                .encode()
                .map_err(EngineError::InvalidCommand)?;
            let snapshot_after = conversation
                .snapshot()
                .map_err(|error| EngineError::Storage(error.to_string()))?;
            if !self.database.persist_outbound_encryption_and_claim(
                &effect.message_id,
                payload.as_bytes(),
                &effect.conversation_id,
                &snapshot_after,
                next_attempt_at,
                ack_deadline,
            )? {
                return Err(EngineError::Storage(
                    "outgoing message could not be claimed after encryption".to_owned(),
                ));
            }
            Ok(payload)
        })();

        match encryption_result {
            Ok(payload) => {
                self.conversations
                    .insert(effect.recipient_installation_id.clone(), conversation);
                Ok(payload)
            }
            Err(error) => {
                let restored =
                    DirectConversation::restore(&snapshot_before).map_err(|restore_error| {
                        EngineError::Storage(format!(
                            "restore MLS conversation after retry rollback: {restore_error}"
                        ))
                    })?;
                self.conversations
                    .insert(effect.recipient_installation_id.clone(), restored);
                Err(error)
            }
        }
    }

    pub(super) fn drain_pending_pre_welcome(
        &mut self,
        contact_installation_id: &str,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        let pending = self
            .database
            .pending_application_envelopes(contact_installation_id)?;
        if pending.is_empty() {
            return Ok(Vec::new());
        }
        let mut events = Vec::new();
        for record in pending {
            let envelope: RelayEnvelope = serde_json::from_str(&record.envelope_json)
                .map_err(|error| EngineError::Serialization(error.to_string()))?;
            let message_id = record.message_id.clone();
            let ciphertext = record.ciphertext.clone();
            match self.handle_application_envelope(envelope, ciphertext) {
                Ok(mut replayed) => {
                    self.database.remove_pending_application_envelope(
                        contact_installation_id,
                        &message_id,
                    )?;
                    events.append(&mut replayed);
                }
                Err(error) => {
                    self.pending_engine_events.push(EngineEvent::Log {
                        log: EngineLogEvent {
                            level: "warn".to_owned(),
                            message: format!(
                                "deferred application envelope replay failed contact={} error={error}",
                                contact_installation_id
                            ),
                        },
                    });
                }
            }
        }
        Ok(events)
    }
}
