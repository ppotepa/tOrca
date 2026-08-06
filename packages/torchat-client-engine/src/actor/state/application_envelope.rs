use super::*;
use crate::event::NotificationKind;

pub(crate) struct InboundApplyResult {
    pub(crate) committed: bool,
    pub(crate) receipt_due: bool,
    pub(crate) runtime_events: Vec<torchat_runtime::RuntimeEvent>,
}

impl ClientEngineActor {
    pub(crate) fn handle_application_envelope_result(
        &mut self,
        envelope: RelayEnvelope,
        ciphertext: Vec<u8>,
    ) -> EngineResult<InboundApplyResult> {
        let message_id = envelope.message_id.to_string();
        let runtime_events = self.handle_application_envelope(envelope, ciphertext)?;
        let receipt_due = self.database.delivery_receipt(&message_id)?.is_some();
        Ok(InboundApplyResult {
            committed: true,
            receipt_due,
            runtime_events,
        })
    }

    pub(crate) fn handle_application_envelope(
        &mut self,
        envelope: RelayEnvelope,
        ciphertext: Vec<u8>,
    ) -> EngineResult<Vec<torchat_runtime::RuntimeEvent>> {
        let peer = envelope.sender.clone();
        let message_id = envelope.message_id;
        let ciphertext_hash = Sha256::digest(&ciphertext).to_vec();
        if let Some(existing) = self
            .database
            .received_envelope(&peer, &message_id.to_string())?
        {
            if existing.ciphertext_hash != ciphertext_hash {
                return Err(EngineError::InvalidCommand(
                    "duplicate envelope has different ciphertext".to_owned(),
                ));
            }
            if existing.receipt_state != "DELIVERED"
                && self
                    .database
                    .delivery_receipt(&message_id.to_string())?
                    .is_some()
            {
                self.flush_pending_receipt_effects()?;
            }
            return Ok(Vec::new());
        }

        let Some(mut conversation) = self.conversations.remove(&peer) else {
            let envelope_json = serde_json::to_string(&envelope)
                .map_err(|error| EngineError::Serialization(error.to_string()))?;
            self.database
                .put_pending_application_envelope(&PendingApplicationEnvelopeRecord {
                    sender_installation_id: peer.clone(),
                    message_id: message_id.to_string(),
                    envelope_json,
                    ciphertext,
                    ciphertext_hash,
                    received_at: self.clock.now_ms(),
                })?;
            self.pending_engine_events.push(EngineEvent::Log {
                log: EngineLogEvent {
                    level: "info".to_owned(),
                    message: format!(
                        "application envelope deferred until MLS Welcome contact={peer}"
                    ),
                },
            });
            return Ok(Vec::new());
        };
        let snapshot_before = conversation
            .snapshot()
            .map_err(|error| EngineError::Storage(error.to_string()))?;

        let result = (|| {
            let plaintext = conversation
                .decrypt(&ciphertext)
                .map_err(EngineError::InvalidCommand)?;
            let application =
                ApplicationPayloadV1::decode(&plaintext).map_err(EngineError::InvalidCommand)?;
            let snapshot_after = conversation
                .snapshot()
                .map_err(|error| EngineError::Storage(error.to_string()))?;
            let received_at = self.clock.now_ms() / 1_000;
            let envelope_record = ReceivedEnvelopeRecord {
                sender_installation_id: peer.clone(),
                message_id: message_id.to_string(),
                ciphertext_hash,
                received_at,
                receipt_state: "NONE".to_owned(),
            };

            match application {
                ApplicationPayloadV1::Message {
                    message_id: payload_message_id,
                    body,
                    reply_to,
                    ..
                } => {
                    if payload_message_id != message_id {
                        return Err(EngineError::InvalidCommand(
                            "application messageId mismatch".to_owned(),
                        ));
                    }
                    let receipt = DeliveryReceiptRecord {
                        envelope_id: uuid::Uuid::new_v4().to_string(),
                        message_id: message_id.to_string(),
                        conversation_id: peer.clone(),
                        original_sender: peer.clone(),
                        received_at,
                        wire_ciphertext: None,
                        state: "PENDING".to_owned(),
                        attempt_count: 0,
                        next_attempt_at: 0,
                        last_error: None,
                        created_at: received_at,
                    };
                    let notification = NotificationRequest {
                        id: message_id.to_string(),
                        kind: NotificationKind::MessageReceived,
                        conversation_id: Some(peer.clone()),
                        preview_text: Some(body.clone()),
                    };
                    let (notify, runtime_events) = self.with_runtime(|runtime| {
                        let accepts = runtime.contact_accepts_messages(&peer)?;
                        let mut envelope_record = envelope_record.clone();
                        if accepts {
                            runtime.receive_message_reply(
                                &peer,
                                body.clone(),
                                Some(message_id),
                                reply_to.clone().map(|reply| torchat_runtime::MessageReply {
                                    message_id: reply.message_id.to_string(),
                                    body: reply.body,
                                    outgoing: !reply.outgoing,
                                }),
                            )?;
                            runtime.storage_mut().put_delivery_receipt(&receipt)?;
                            envelope_record.receipt_state = "PENDING".to_owned();
                        }
                        runtime
                            .storage_mut()
                            .put_conversation_mls_snapshot(&peer, &snapshot_after)?;
                        runtime
                            .storage_mut()
                            .put_received_envelope(&envelope_record)?;
                        Ok(accepts && runtime.contact_allows_notifications(&peer)?)
                    })?;
                    Ok((runtime_events, notify.then_some(notification)))
                }
                ApplicationPayloadV1::DeliveryReceipt {
                    message_id: delivered_message_id,
                    ..
                } => {
                    let (_, runtime_events) = self.with_runtime(|runtime| {
                        runtime.apply_message_transport_outcome(
                            delivered_message_id,
                            MessageTransportOutcome::Delivered,
                        )?;
                        runtime
                            .storage_mut()
                            .put_conversation_mls_snapshot(&peer, &snapshot_after)?;
                        runtime
                            .storage_mut()
                            .put_received_envelope(&envelope_record)?;
                        Ok(())
                    })?;
                    Ok((runtime_events, None))
                }
                ApplicationPayloadV1::Typing {
                    sent_at, typing, ..
                } => {
                    let (_, mut runtime_events) = self.with_runtime(|runtime| {
                        runtime
                            .storage_mut()
                            .put_conversation_mls_snapshot(&peer, &snapshot_after)?;
                        Ok(())
                    })?;
                    runtime_events.push(torchat_runtime::RuntimeEvent::TypingChanged {
                        conversation_id: peer.clone(),
                        typing,
                        expires_at: sent_at + 5_000,
                    });
                    Ok((runtime_events, None))
                }
                ApplicationPayloadV1::Presence {
                    sent_at, online, ..
                } => {
                    let (_, mut runtime_events) = self.with_runtime(|runtime| {
                        runtime
                            .storage_mut()
                            .put_conversation_mls_snapshot(&peer, &snapshot_after)?;
                        Ok(())
                    })?;
                    runtime_events.push(torchat_runtime::RuntimeEvent::PresenceChanged {
                        contact_id: peer.clone(),
                        online,
                        idle: !online,
                        observed_at: sent_at,
                        expires_at: sent_at + 45_000,
                    });
                    Ok((runtime_events, None))
                }
                ApplicationPayloadV1::ReadReceipt { message_ids, .. } => {
                    let (_, events) = self.with_runtime(|runtime| {
                        for message_id in message_ids {
                            let _ = runtime.apply_message_read(message_id);
                        }
                        runtime
                            .storage_mut()
                            .put_conversation_mls_snapshot(&peer, &snapshot_after)?;
                        Ok(())
                    })?;
                    Ok((events, None))
                }
                ApplicationPayloadV1::RelationshipRemoved {
                    message_id: removal_message_id,
                    removed_at,
                    preserve_history: _,
                    relationship_epoch,
                    removal_id,
                    ..
                } => {
                    if removal_message_id != message_id {
                        return Err(EngineError::InvalidCommand(
                            "relationship removal messageId mismatch".to_owned(),
                        ));
                    }
                    let removal_id = removal_id
                        .map(|value| value.to_string())
                        .unwrap_or_else(|| removal_message_id.to_string());
                    let relationship_epoch = relationship_epoch.unwrap_or(0);
                    let ack = RelayPayloadV1::relationship_removal_applied(
                        &self.identity,
                        peer.clone(),
                        removal_id.clone(),
                        relationship_epoch,
                        self.clock.now_ms(),
                    )
                    .encode()
                    .map_err(EngineError::InvalidCommand)?;
                    let (_, events) = self.with_runtime(|runtime| {
                        // The shared runtime owns the relationship transition;
                        // the transport only delivers the typed application
                        // payload and persists the resulting MLS snapshot.
                        runtime.apply_remote_relationship_removal(
                            &peer,
                            removed_at,
                            &removal_id,
                            relationship_epoch,
                        )?;
                        runtime.storage_mut().put_relationship_removal_ack(
                            &removal_id,
                            &peer,
                            relationship_epoch,
                            ack.as_bytes(),
                        )?;
                        runtime
                            .storage_mut()
                            .put_received_envelope(&envelope_record)?;
                        Ok(())
                    })?;
                    Ok((events, None))
                }
                ApplicationPayloadV1::CapabilityOffer {
                    capability_id,
                    secret,
                    sequence,
                    issued_at,
                    expires_at,
                    ..
                } => {
                    let secret = URL_SAFE_NO_PAD.decode(secret).map_err(|_| {
                        EngineError::InvalidCommand("invalid capability secret".into())
                    })?;
                    if secret.len() < 16 || capability_id.len() != 16 {
                        return Err(EngineError::InvalidCommand(
                            "invalid endpoint capability payload".into(),
                        ));
                    }
                    let had_peer_capability = self
                        .database
                        .peer_endpoint_capability_secret(&peer, &capability_id)?
                        .is_some();
                    let (_, mut events) = self.with_runtime(|runtime| {
                        runtime.storage_mut().put_peer_endpoint_capability(
                            &peer,
                            &capability_id,
                            &secret,
                            sequence,
                            issued_at,
                            expires_at,
                        )?;
                        runtime
                            .storage_mut()
                            .put_conversation_mls_snapshot(&peer, &snapshot_after)?;
                        runtime
                            .storage_mut()
                            .put_received_envelope(&envelope_record)?;
                        Ok(())
                    })?;
                    events.push(torchat_runtime::RuntimeEvent::ContactCapabilityChanged {
                        contact_id: peer.clone(),
                        capability_id: capability_id.clone(),
                        sequence,
                        status: torchat_runtime::CapabilityStatus::Active,
                    });
                    // If this is the first grant received from the peer, make
                    // the exchange symmetric. Duplicate offers do not trigger
                    // another offer, preventing an acknowledgement loop.
                    if !had_peer_capability && let Err(error) = self.send_capability_offer(&peer) {
                        self.pending_engine_events.push(EngineEvent::Log {
                            log: EngineLogEvent {
                                level: "warn".to_owned(),
                                message: format!(
                                    "symmetric capability offer deferred contact={} error={error}",
                                    peer
                                ),
                            },
                        });
                    }
                    if let Err(error) = self.send_ephemeral_payload(
                        &peer,
                        ApplicationPayloadV1::CapabilityOfferAck {
                            version: torchat_core::PROTOCOL_VERSION,
                            capability_id,
                            sequence,
                        },
                    ) {
                        self.pending_engine_events.push(EngineEvent::Log {
                            log: EngineLogEvent {
                                level: "warn".to_owned(),
                                message: format!(
                                    "capability acknowledgement deferred contact={} error={error}",
                                    peer
                                ),
                            },
                        });
                    }
                    // New authentication material invalidates failures caused
                    // by the previous credentials. Retry queued deliveries
                    // immediately instead of preserving exponential backoff.
                    self.database.expedite_peer_deliveries(&peer)?;
                    let _ = self.queue_peer_probe(&peer);
                    Ok((events, None))
                }
                ApplicationPayloadV1::CapabilityOfferAck {
                    capability_id,
                    sequence,
                    ..
                } => {
                    // This is the application-level acknowledgement for the
                    // durable offer. A peer persistence ACK only proves peer
                    // acceptance, not that the peer installed the secret.
                    self.database
                        .complete_capability_deliveries_for_contact(&peer)?;
                    let (_, mut events) = self.with_runtime(|runtime| {
                        runtime
                            .storage_mut()
                            .put_conversation_mls_snapshot(&peer, &snapshot_after)?;
                        runtime
                            .storage_mut()
                            .put_received_envelope(&envelope_record)?;
                        Ok(())
                    })?;
                    events.push(torchat_runtime::RuntimeEvent::ContactCapabilityChanged {
                        contact_id: peer.clone(),
                        capability_id,
                        sequence,
                        status: torchat_runtime::CapabilityStatus::Active,
                    });
                    self.database.expedite_peer_deliveries(&peer)?;
                    let _ = self.queue_peer_probe(&peer);
                    Ok((events, None))
                }
                ApplicationPayloadV1::CapabilityRevoked {
                    capability_id,
                    sequence,
                    ..
                } => {
                    let (_, mut events) = self.with_runtime(|runtime| {
                        runtime
                            .storage_mut()
                            .revoke_peer_endpoint_capability(&peer)?;
                        runtime
                            .storage_mut()
                            .put_conversation_mls_snapshot(&peer, &snapshot_after)?;
                        runtime
                            .storage_mut()
                            .put_received_envelope(&envelope_record)?;
                        Ok(())
                    })?;
                    events.push(torchat_runtime::RuntimeEvent::ContactCapabilityChanged {
                        contact_id: peer.clone(),
                        capability_id,
                        sequence,
                        status: torchat_runtime::CapabilityStatus::Revoked,
                    });
                    Ok((events, None))
                }
            }
        })();

        match result {
            Ok((runtime_events, notification)) => {
                self.conversations.insert(peer, conversation);
                // The inbound transaction is already committed at this point.
                // Receipt transport is a separate durable effect and must not
                // turn a successful inbound message into a rejected/crypto
                // failure when its first send attempt fails.
                if let Err(error) = self.flush_pending_receipt_effects() {
                    self.receipt_queue_failed_after_commit =
                        self.receipt_queue_failed_after_commit.saturating_add(1);
                    self.pending_engine_events.push(EngineEvent::Log {
                        log: EngineLogEvent {
                            level: "warn".to_owned(),
                            message: format!(
                                "receipt_queue_failed_after_commit: deferred durable receipt effect ({error_kind})",
                                error_kind = super::error_kind(&error),
                            ),
                        },
                    });
                }
                if let Some(notification) = notification {
                    self.queue_notification(notification);
                }
                Ok(runtime_events)
            }
            Err(error) => {
                let restored =
                    DirectConversation::restore(&snapshot_before).map_err(|restore_error| {
                        EngineError::Storage(format!(
                            "restore MLS conversation after receive rollback: {restore_error}"
                        ))
                    })?;
                self.conversations.insert(peer, restored);
                Err(error)
            }
        }
    }
}
