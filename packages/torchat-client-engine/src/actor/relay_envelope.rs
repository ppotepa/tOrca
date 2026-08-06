use super::*;
use crate::event::NotificationKind;

impl ClientEngineActor {
    pub(super) fn handle_relay_envelope(
        &mut self,
        envelope: RelayEnvelope,
    ) -> EngineResult<Vec<torchat_runtime::RuntimeEvent>> {
        // Control-plane payloads (pairing and Welcome) use RelayPayloadV1.
        // Application messages are opaque PeerCiphertextPayloads: the relay
        // must never inspect their MLS ciphertext, but the recipient still
        // needs to feed the decoded bytes through the exact same application
        // path used by the onion listener.
        let payload = match RelayPayloadV1::decode(&envelope.ciphertext) {
            Ok(payload) => payload,
            Err(relay_error) => {
                let ciphertext = PeerCiphertextPayload::decode(&envelope.ciphertext)
                    .map_err(|peer_error| {
                        EngineError::InvalidCommand(format!(
                            "invalid relay envelope payload: {relay_error}; peer payload: {peer_error}"
                        ))
                    })?;
                return self.handle_application_envelope(envelope, ciphertext);
            }
        };
        match &payload {
            RelayPayloadV1::PairingOffer {
                pairing_id, invite, ..
            } => {
                let parsed = ContactInvite::parse(invite).map_err(EngineError::InvalidCommand)?;
                let sender = contact_record_from_card(&contact_card_from_invite(&parsed), false);
                let item = PairingItem {
                    pairing_id: pairing_id.clone(),
                    pair_key: Some(pairing_pair_key(
                        &self.identity.installation_id(),
                        &parsed.installation_id,
                    )),
                    // Rendezvous authorization is bound to the live WebSocket
                    // and its side token. The runtime still requires a non-empty local
                    // capability to authorize the UI transition, but this
                    // value is never sent to the relay.
                    capability: Some(pairing_id.clone()),
                    sender: Some(sender),
                    expires_at: parsed.expires_at as i64,
                    state: InviteState::Pending,
                    received: true,
                    available_actions: Vec::new(),
                    offer_invite_id: Some(parsed.invite_id),
                    offer_payload: Some(invite.clone()),
                };
                let now_secs = self.clock.now_ms() / 1_000;
                let (_, runtime_events) = self.with_runtime(|runtime| {
                    torchat_runtime::ClientPairingFeatureFacade::feature_receive_pairing_offer(
                        runtime,
                        item,
                        now_secs,
                    )
                    .map(|_| ())
                })?;
                self.queue_notification(NotificationRequest {
                    id: pairing_id.clone(),
                    kind: NotificationKind::PairingRequest,
                    conversation_id: None,
                    preview_text: None,
                });
                Ok(runtime_events)
            }
            RelayPayloadV1::PairingRejected { pairing_id, .. } => {
                if let Ok(pairing_id) = uuid::Uuid::parse_str(pairing_id) {
                    return self.apply_pairing_peer_outcome_with_operation(
                        &pairing_id.to_string(),
                        PairingPeerOutcome::RejectionReceived,
                    );
                }
                Ok(Vec::new())
            }
            RelayPayloadV1::Welcome { sender, .. } => {
                payload
                    .verify_welcome(&envelope.sender, &self.identity.installation_id())
                    .map_err(EngineError::InvalidCommand)?;
                let peer_endpoint = payload.welcome_peer_endpoint().cloned();
                let peer_capability = payload
                    .welcome_peer_capability()
                    .map(|(id, secret)| (id.to_owned(), secret.to_owned()));
                if let Some(endpoint) = &peer_endpoint {
                    endpoint
                        .validate(self.clock.now_ms() / 1_000)
                        .map_err(EngineError::InvalidCommand)?;
                    if endpoint.installation_id != sender.installation_id
                        || endpoint.identity_public_key != sender.public_key
                    {
                        return Err(EngineError::InvalidCommand(
                            "Welcome peer endpoint does not match sender identity".to_owned(),
                        ));
                    }
                }
                let (invite_id, welcome, tree) = payload
                    .decode_welcome()
                    .map_err(EngineError::InvalidCommand)?;
                self.database.bind_pairing_outbox_pair_key(
                    &invite_id,
                    &pairing_pair_key(&self.identity.installation_id(), &sender.installation_id),
                )?;
                // A relay reconnect can replay a Welcome which has already
                // been committed. MLS key packages are intentionally
                // one-time material, so accepting that duplicate would fail.
                if self.database.invite_used(&invite_id)? {
                    if let Err(error) =
                        self.queue_welcome_applied(&sender.installation_id, &invite_id)
                    {
                        self.pending_engine_events.push(EngineEvent::Log {
                            log: EngineLogEvent {
                                level: "warn".to_owned(),
                                message: format!(
                                    "WelcomeApplied resend deferred invite_id={invite_id} error={error}"
                                ),
                            },
                        });
                    }
                    self.pending_engine_events.push(EngineEvent::Log {
                        log: EngineLogEvent {
                            level: "info".to_owned(),
                            message: format!(
                                "ignoring duplicate Welcome for completed invite_id={invite_id}"
                            ),
                        },
                    });
                    return Ok(Vec::new());
                }
                let pending_invite = self
                    .database
                    .pending_local_invite_mls(&invite_id, self.clock.now_ms() / 1_000)?
                    .ok_or_else(|| {
                        EngineError::InvalidCommand(
                            "local MLS state for contact invite is missing or expired".to_owned(),
                        )
                    })?;
                if let Some(expected_sender) = &pending_invite.recipient_installation_id
                    && expected_sender != &sender.installation_id
                {
                    return Err(EngineError::InvalidCommand(
                        "Welcome sender does not match invite recipient".to_owned(),
                    ));
                }
                let member = MlsMember::restore(
                    &pending_invite.snapshot,
                    self.identity.public_key().as_bytes(),
                )
                .map_err(|error| {
                    EngineError::Storage(format!("restore invite MLS state: {error}"))
                })?;
                let conversation = match member.accept_conversation(&welcome, &tree) {
                    Ok(value) => value,
                    Err(error) => {
                        let detail = error.to_string();
                        if detail.contains("No matching key package") {
                            self.pending_engine_events.push(EngineEvent::Log {
                                log: EngineLogEvent {
                                    level: "warn".to_owned(),
                                    message: format!(
                                        "discarded stale Welcome invite_id={invite_id}; local MLS key package is no longer available"
                                    ),
                                },
                            });
                            return Ok(vec![torchat_runtime::RuntimeEvent::RuntimeError {
                                message: "pairing_invite_expired".to_owned(),
                            }]);
                        }
                        return Err(EngineError::InvalidCommand(detail));
                    }
                };
                let committed = self.commit_contact_with_conversation(
                    sender.clone(),
                    conversation,
                    None,
                    Some(&invite_id),
                    None,
                    Some(&invite_id),
                );
                match committed {
                    Ok(mut runtime_events) => {
                        if let Some((capability_id, secret)) = peer_capability {
                            let secret = URL_SAFE_NO_PAD.decode(secret).map_err(|_| {
                                EngineError::InvalidCommand(
                                    "invalid Welcome capability secret".to_owned(),
                                )
                            })?;
                            self.database.put_peer_endpoint_capability(
                                &sender.installation_id,
                                &capability_id,
                                &secret,
                                peer_endpoint.as_ref().map_or(1, |value| value.sequence),
                                self.clock.now_ms() / 1_000,
                                peer_endpoint.as_ref().and_then(|value| value.expires_at),
                            )?;
                            self.database.put_contact_endpoint_capability(
                                &sender.installation_id,
                                &pending_invite.local_capability_id,
                                &pending_invite.local_capability_secret,
                            )?;
                        }
                        let mut reconcile_events = self
                            .reconcile_outbox_pairing_contact_with_operations(
                                &sender.installation_id,
                            )?;
                        runtime_events.append(&mut reconcile_events);
                        if let Some(peer_endpoint) = peer_endpoint {
                            runtime_events.extend(self.apply_peer_endpoint(peer_endpoint)?);
                        }
                        if let Err(error) =
                            self.queue_welcome_applied(&sender.installation_id, &invite_id)
                        {
                            self.pending_engine_events.push(EngineEvent::Log {
                                log: EngineLogEvent {
                                    level: "warn".to_owned(),
                                    message: format!(
                                        "WelcomeApplied enqueue deferred invite_id={invite_id} error={error}"
                                    ),
                                },
                            });
                        }
                        Ok(runtime_events)
                    }
                    Err(error) => Err(error),
                }
            }
            RelayPayloadV1::WelcomeApplied { .. } => {
                let invite_id = payload
                    .verify_welcome_applied(&envelope.sender, &self.identity.installation_id())
                    .map_err(EngineError::InvalidCommand)?;
                let Some(pending) = self.database.pending_welcome(&invite_id)? else {
                    return Ok(Vec::new());
                };
                if pending.recipient_installation_id != envelope.sender {
                    return Err(EngineError::InvalidCommand(
                        "WelcomeApplied does not match pending Welcome recipient".to_owned(),
                    ));
                }
                self.database.remove_pending_welcome(&invite_id)?;
                self.pending_welcomes.remove(&invite_id);
                Ok(Vec::new())
            }
            RelayPayloadV1::RelationshipRemovalApplied { .. } => {
                let removal_id = payload
                    .verify_relationship_removal_applied(
                        &envelope.sender,
                        &self.identity.installation_id(),
                    )
                    .map_err(EngineError::InvalidCommand)?;
                self.database
                    .complete_relationship_removal_ack(&removal_id)?;
                Ok(Vec::new())
            }
            RelayPayloadV1::PeerEndpointBootstrap { .. } => {
                let endpoint = payload
                    .verify_peer_endpoint_bootstrap(
                        &envelope.sender,
                        &self.identity.installation_id(),
                    )
                    .map_err(EngineError::InvalidCommand)?;
                let contact = self
                    .database
                    .contact_by_installation_id(&endpoint.installation_id)
                    .map_err(runtime_error)?;
                let Some(contact) = contact else {
                    self.database.put_pending_peer_endpoint_inbox(
                        &PendingPeerEndpointInboxRecord {
                            contact_installation_id: endpoint.installation_id.clone(),
                            payload: payload
                                .encode()
                                .map_err(EngineError::InvalidCommand)?
                                .into_bytes(),
                            endpoint_sequence: endpoint.sequence,
                            received_at: self.clock.now_ms(),
                        },
                    )?;
                    self.pending_engine_events.push(EngineEvent::Log {
                        log: EngineLogEvent {
                            level: "info".to_owned(),
                            message: format!(
                                "peer endpoint bootstrap deferred until contact exists contact={}",
                                endpoint.installation_id
                            ),
                        },
                    });
                    return Ok(Vec::new());
                };
                if !contact.public_key.trim().is_empty()
                    && contact.public_key != endpoint.identity_public_key
                {
                    return Err(EngineError::InvalidCommand(
                        "peer endpoint bootstrap identity does not match contact".to_owned(),
                    ));
                }
                self.apply_peer_endpoint(endpoint)
            }
        }
    }
}
