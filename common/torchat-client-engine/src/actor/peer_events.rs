use super::*;

impl ClientEngineActor {
    pub(super) fn handle_peer_event(
        &mut self,
        event: PeerTransportEvent,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        match event {
            PeerTransportEvent::InboundMessage {
                envelope,
                persisted,
                delivered,
            } => {
                self.pending_engine_events.push(EngineEvent::Log {
                    log: EngineLogEvent {
                        level: "info".to_owned(),
                        message: format!(
                            "peer message received message_id={} sender={}",
                            envelope.message_id, envelope.sender_installation_id
                        ),
                    },
                });
                let ack = |kind| PeerAck {
                    session_id: envelope.session_id,
                    message_id: envelope.message_id,
                    kind,
                    ciphertext_hash: envelope.ciphertext_hash(),
                };
                let store_result = match self
                    .database
                    .store_inbound_peer_envelope(&envelope, unix_secs())
                {
                    Ok(result) => result,
                    Err(error) => {
                        let _ = persisted.send(Err(error.to_string()));
                        let _ = delivered.send(Err(error.to_string()));
                        return Err(error);
                    }
                };
                let _ = persisted.send(Ok(ack(PeerAckKind::Persisted)));
                if matches!(
                    store_result,
                    InboundEnvelopeStoreResult::Duplicate { delivered: true }
                ) {
                    let _ = delivered.send(Ok(ack(PeerAckKind::Delivered)));
                    return Ok(Vec::new());
                }
                let ciphertext = String::from_utf8(envelope.ciphertext.clone()).map_err(|error| {
                    EngineError::InvalidCommand(format!(
                        "peer wire ciphertext is not UTF-8: {error}"
                    ))
                });
                let result = ciphertext.and_then(|wire_payload| {
                    let ciphertext = PeerCiphertextPayload::decode(&wire_payload)
                        .map_err(EngineError::InvalidCommand)?;
                    self.handle_application_envelope_result(
                        RelayEnvelope {
                            version: torchat_core::PROTOCOL_VERSION,
                            message_id: envelope.message_id,
                            sender: envelope.sender_installation_id.clone(),
                            recipient: self.identity.installation_id(),
                            ciphertext: wire_payload,
                        },
                        ciphertext,
                    )
                });
                match result {
                    Ok(result) if result.committed => {
                        self.database.complete_inbound_peer_envelope(
                            &envelope.sender_installation_id,
                            &envelope.message_id.to_string(),
                        )?;
                        let _ = delivered.send(Ok(ack(PeerAckKind::Delivered)));
                        Ok(result.runtime_events)
                    }
                    Ok(_) => {
                        self.database.reject_inbound_peer_envelope(
                            &envelope.sender_installation_id,
                            &envelope.message_id.to_string(),
                        )?;
                        let _ = delivered.send(Ok(ack(PeerAckKind::Rejected)));
                        Ok(Vec::new())
                    }
                    Err(error) => {
                        self.database.reject_inbound_peer_envelope(
                            &envelope.sender_installation_id,
                            &envelope.message_id.to_string(),
                        )?;
                        let _ = delivered.send(Ok(ack(PeerAckKind::Rejected)));
                        if is_cryptographic_inbound_error(&error) {
                            self.crypto_blocked_peers
                                .insert(envelope.sender_installation_id.clone());
                        }
                        self.pending_engine_events.push(EngineEvent::Log {
                            log: EngineLogEvent {
                                level: "error".to_owned(),
                                message: format!(
                                    "peer MLS session blocked contact={} error={error}",
                                    envelope.sender_installation_id
                                ),
                            },
                        });
                        Ok(vec![
                            torchat_client_runtime::RuntimeEvent::PeerConnectionChanged {
                                contact_id: envelope.sender_installation_id,
                                status: PeerConnectionStatus::Backoff,
                                retry_in_ms: None,
                            },
                        ])
                    }
                }
            }
            PeerTransportEvent::Ack {
                delivery,
                kind,
                contact_installation_id,
                endpoint_sequence,
            } => {
                let delivery_id = match &delivery {
                    PeerDeliveryTag::Message { message_id }
                    | PeerDeliveryTag::Receipt { message_id } => message_id.as_str(),
                    PeerDeliveryTag::ReadReceipt { receipt_id } => receipt_id.as_str(),
                    PeerDeliveryTag::Ephemeral => "ephemeral",
                    PeerDeliveryTag::Probe => "probe",
                    PeerDeliveryTag::EndpointUpdate => "endpoint-update",
                    PeerDeliveryTag::Presence { .. } => "presence",
                    PeerDeliveryTag::Typing { .. } => "typing",
                    PeerDeliveryTag::ConversationFocus { .. } => "focus",
                };
                self.pending_engine_events.push(EngineEvent::Log {
                    log: EngineLogEvent {
                        level: "info".to_owned(),
                        message: format!(
                            "peer ack received contact={} delivery={} kind={:?}",
                            contact_installation_id, delivery_id, kind
                        ),
                    },
                });
                if matches!(kind, PeerAckKind::Persisted | PeerAckKind::Delivered)
                    && let Some(sequence) = endpoint_sequence
                {
                    self.database
                        .complete_endpoint_updates(&contact_installation_id, sequence)?;
                }
                let probe_status = match (&delivery, kind) {
                    (PeerDeliveryTag::Presence { .. }, PeerAckKind::Rejected)
                    | (PeerDeliveryTag::EndpointUpdate, PeerAckKind::Rejected) => Some((
                        ProbeKey::contact_presence(contact_installation_id.clone()),
                        ProbeStatus::Offline,
                    )),
                    (PeerDeliveryTag::Presence { .. }, _) => Some((
                        ProbeKey::contact_presence(contact_installation_id.clone()),
                        ProbeStatus::Online,
                    )),
                    (PeerDeliveryTag::EndpointUpdate, _) => Some((
                        ProbeKey::peer_endpoint(contact_installation_id.clone()),
                        ProbeStatus::Online,
                    )),
                    (PeerDeliveryTag::ConversationFocus { .. }, PeerAckKind::Rejected) => Some((
                        ProbeKey::contact_focus(contact_installation_id.clone()),
                        ProbeStatus::Offline,
                    )),
                    (PeerDeliveryTag::ConversationFocus { .. }, _) => Some((
                        ProbeKey::contact_focus(contact_installation_id.clone()),
                        ProbeStatus::Online,
                    )),
                    _ => None,
                };
                if let Some((probe_key, status)) = probe_status {
                    let now = Instant::now();
                    self.probe_coordinator.ensure(probe_key.clone(), now);
                    self.probe_coordinator.record_result(
                        &probe_key,
                        now,
                        status,
                        None,
                        Duration::from_secs(30),
                    );
                }
                match delivery {
                    PeerDeliveryTag::Message { message_id } => match kind {
                        PeerAckKind::Received => Ok(Vec::new()),
                        PeerAckKind::Persisted => {
                            self.database.complete_outbound_delivery(&message_id)?;
                            self.apply_message_transport_outcome(
                                &message_id,
                                MessageTransportOutcome::PeerPersisted,
                            )
                        }
                        PeerAckKind::Delivered => self.apply_message_transport_outcome(
                            &message_id,
                            MessageTransportOutcome::PeerDelivered,
                        ),
                        PeerAckKind::Rejected => self.apply_message_transport_outcome(
                            &message_id,
                            MessageTransportOutcome::PeerRejected,
                        ),
                    },
                    PeerDeliveryTag::Receipt { message_id } => {
                        if matches!(
                            kind,
                            PeerAckKind::Persisted | PeerAckKind::Delivered | PeerAckKind::Rejected
                        ) {
                            self.database.complete_delivery_receipt(&message_id)?;
                        }
                        Ok(Vec::new())
                    }
                    PeerDeliveryTag::ReadReceipt { receipt_id } => {
                        if matches!(
                            kind,
                            PeerAckKind::Persisted | PeerAckKind::Delivered | PeerAckKind::Rejected
                        ) {
                            self.database.complete_read_receipt(&receipt_id)?;
                        }
                        Ok(Vec::new())
                    }
                    PeerDeliveryTag::Ephemeral => Ok(Vec::new()),
                    PeerDeliveryTag::Probe => Ok(Vec::new()),
                    PeerDeliveryTag::EndpointUpdate => Ok(Vec::new()),
                    PeerDeliveryTag::Presence { .. } => Ok(Vec::new()),
                    PeerDeliveryTag::Typing { .. } => Ok(Vec::new()),
                    PeerDeliveryTag::ConversationFocus { .. } => Ok(Vec::new()),
                }
            }
            PeerTransportEvent::EndpointUpdated { endpoint } => {
                let previous = self
                    .database
                    .contact_peer_endpoint(&endpoint.installation_id)?
                    .ok_or_else(|| {
                        EngineError::InvalidCommand(
                            "peer endpoint update has no known predecessor".to_owned(),
                        )
                    })?;
                endpoint
                    .validate_successor(&previous, unix_secs())
                    .map_err(EngineError::InvalidCommand)?;
                self.database.put_contact_peer_endpoint(&endpoint)?;
                self.database
                    .ensure_contact_endpoint_capability(&endpoint.installation_id)?;
                let capability_probe = ProbeKey::capability(endpoint.installation_id.clone());
                let now = Instant::now();
                self.probe_coordinator.ensure(capability_probe.clone(), now);
                self.probe_coordinator.record_result(
                    &capability_probe,
                    now,
                    ProbeStatus::Online,
                    None,
                    Duration::from_secs(60),
                );
                let base_endpoint = self.local_peer_endpoint.clone().ok_or_else(|| {
                    EngineError::Transport("local onion endpoint is unavailable".to_owned())
                })?;
                let local_endpoint =
                    self.local_endpoint_for_contact(&endpoint.installation_id, &base_endpoint)?;
                if let Some(peer) = &self.peer_transport {
                    let (capability_id, secret) =
                        self.local_capability_credentials(&endpoint.installation_id)?;
                    peer.authorize_contact(&endpoint, local_endpoint, capability_id, secret);
                }
                let contact_id = endpoint.installation_id.clone();
                let _ = self.queue_peer_probe(&contact_id);
                Ok(vec![
                    torchat_client_runtime::RuntimeEvent::PeerEndpointChanged {
                        contact_id,
                        status: PeerEndpointStatus::Verified,
                    },
                ])
            }
            PeerTransportEvent::PresenceChanged {
                installation_id,
                online,
                idle,
                observed_at,
                expires_at,
            } => {
                if online {
                    self.database
                        .record_contact_seen(&installation_id, observed_at)?;
                }
                let presence_probe = ProbeKey::contact_presence(installation_id.clone());
                let now = Instant::now();
                self.probe_coordinator.ensure(presence_probe.clone(), now);
                self.probe_coordinator.record_result(
                    &presence_probe,
                    now,
                    if online {
                        ProbeStatus::Online
                    } else {
                        ProbeStatus::Offline
                    },
                    None,
                    Duration::from_secs(30),
                );
                Ok(vec![
                    torchat_client_runtime::RuntimeEvent::PresenceChanged {
                        contact_id: installation_id,
                        online,
                        idle,
                        observed_at,
                        expires_at,
                    },
                ])
            }
            PeerTransportEvent::TypingChanged {
                installation_id,
                typing,
                expires_at,
            } => Ok(vec![torchat_client_runtime::RuntimeEvent::TypingChanged {
                conversation_id: installation_id,
                typing,
                expires_at,
            }]),
            PeerTransportEvent::ConversationFocusChanged {
                installation_id,
                focused,
                expires_at,
            } => Ok(vec![
                torchat_client_runtime::RuntimeEvent::ConversationFocusChanged {
                    conversation_id: installation_id,
                    focused,
                    expires_at,
                },
            ]),
            PeerTransportEvent::IngressError { error } => {
                let level = if is_expected_peer_shutdown(&error) {
                    "info"
                } else {
                    "warn"
                };
                self.pending_engine_events.push(EngineEvent::Log {
                    log: EngineLogEvent {
                        level: level.to_owned(),
                        message: format!("peer inbound connection failed: {error}"),
                    },
                });
                Ok(Vec::new())
            }
            PeerTransportEvent::ConnectionChanged {
                installation_id,
                session_id,
                status,
                error,
                delivery,
            } => {
                if let Some(error_message) = error.as_deref() {
                    self.pending_engine_events.push(EngineEvent::Log {
                        log: EngineLogEvent {
                            level: "warn".to_owned(),
                            message: format!(
                                "peer connection failed contact={} status={status:?} delivery={delivery:?} error={error_message}",
                                installation_id
                            ),
                        },
                    });
                }
                let status = if status == PeerConnectionStatus::Connected
                    && self.crypto_blocked_peers.contains(&installation_id)
                {
                    PeerConnectionStatus::Backoff
                } else {
                    status
                };
                if let Some(session_id) = session_id {
                    let sessions = self
                        .active_peer_sessions
                        .entry(installation_id.clone())
                        .or_default();
                    match status {
                        PeerConnectionStatus::Connected => {
                            sessions.insert(session_id);
                        }
                        PeerConnectionStatus::Offline => {
                            sessions.remove(&session_id);
                            if !sessions.is_empty() {
                                return Ok(Vec::new());
                            }
                        }
                        _ => {}
                    }
                } else if self
                    .active_peer_sessions
                    .get(&installation_id)
                    .is_some_and(|sessions| !sessions.is_empty())
                    && matches!(
                        status,
                        PeerConnectionStatus::Connecting
                            | PeerConnectionStatus::Authenticating
                            | PeerConnectionStatus::Backoff
                    )
                {
                    return Ok(Vec::new());
                }
                let probe_key = ProbeKey::contact(installation_id.clone());
                let now = Instant::now();
                self.probe_coordinator.ensure(probe_key.clone(), now);
                let probe_status = match status {
                    PeerConnectionStatus::Connected => Some(ProbeStatus::Online),
                    PeerConnectionStatus::Backoff | PeerConnectionStatus::Offline => {
                        Some(ProbeStatus::Offline)
                    }
                    PeerConnectionStatus::Connecting | PeerConnectionStatus::Authenticating => None,
                };
                if let Some(probe_status) = probe_status {
                    self.probe_coordinator.record_result(
                        &probe_key,
                        now,
                        probe_status,
                        None,
                        Duration::from_secs(30),
                    );
                    self.pending_engine_events.push(EngineEvent::Log {
                        log: EngineLogEvent {
                            level: if status == PeerConnectionStatus::Backoff {
                                "warn".to_owned()
                            } else {
                                "debug".to_owned()
                            },
                            message: format!(
                                "{} contact_id_hash={} status={:?}",
                                if status == PeerConnectionStatus::Backoff {
                                    "contact_probe_backoff"
                                } else {
                                    "contact_probe_finished"
                                },
                                pseudonymous_target_id(&installation_id),
                                status
                            ),
                        },
                    });
                }
                if status == PeerConnectionStatus::Connected {
                    self.database
                        .mark_peer_connected(&installation_id, unix_secs())?;
                }
                let mut runtime_events = match (&status, error.as_deref(), delivery) {
                    (
                        PeerConnectionStatus::Backoff,
                        Some(error_message),
                        Some(PeerDeliveryTag::Message { message_id }),
                    ) => self.handle_failed_peer_message_delivery(
                        &installation_id,
                        &message_id,
                        error_message,
                    )?,
                    (
                        PeerConnectionStatus::Backoff,
                        Some(error_message),
                        Some(PeerDeliveryTag::Receipt { message_id }),
                    ) => {
                        self.handle_failed_peer_receipt_delivery(
                            &installation_id,
                            &message_id,
                            error_message,
                        )?;
                        Vec::new()
                    }
                    _ => Vec::new(),
                };
                let retry_in_ms = match (&status, error.as_deref()) {
                    (PeerConnectionStatus::Backoff, Some(_)) => {
                        self.peer_retry_in_ms(&installation_id)?
                    }
                    _ => None,
                };
                runtime_events.push(
                    torchat_client_runtime::RuntimeEvent::PeerConnectionChanged {
                        contact_id: installation_id,
                        status,
                        retry_in_ms,
                    },
                );
                Ok(runtime_events)
            }
        }
    }
}

fn is_cryptographic_inbound_error(error: &EngineError) -> bool {
    matches!(error, EngineError::InvalidCommand(message)
        if ["decrypt", "MLS", "ciphertext", "authentication", "hash"]
            .iter()
            .any(|marker| message.contains(marker)))
}

#[cfg(test)]
mod tests {
    use super::is_cryptographic_inbound_error;
    use crate::EngineError;

    #[test]
    fn only_cryptographic_inbound_errors_are_blocking() {
        for message in [
            "MLS decrypt failed",
            "ciphertext authentication failed",
            "application hash mismatch",
        ] {
            assert!(is_cryptographic_inbound_error(
                &EngineError::InvalidCommand(message.to_owned(),)
            ));
        }
        for error in [
            EngineError::Storage("receipt retry unavailable".to_owned()),
            EngineError::Transport("relay timeout".to_owned()),
            EngineError::InvalidCommand("receipt effect failed".to_owned()),
        ] {
            assert!(!is_cryptographic_inbound_error(&error));
        }
    }
}
