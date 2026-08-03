use super::*;

impl ClientEngineActor {
    pub(super) async fn drain_relay_events(&mut self, events: &mpsc::Sender<EngineEvent>) {
        while let Some(event) = self.relay.poll_event() {
            match self.handle_relay_event(event) {
                Ok((runtime_events, connection_snapshot, log_event)) => {
                    if let Some(snapshot) = connection_snapshot {
                        let _ = events.send(EngineEvent::Connection { snapshot }).await;
                    }
                    if let Some(log) = log_event {
                        let _ = events.send(EngineEvent::Log { log }).await;
                    }
                    for event in runtime_events {
                        let _ = events.send(EngineEvent::Runtime { event }).await;
                    }
                    for event in self.pending_engine_events.drain(..) {
                        let _ = events.send(event).await;
                    }
                }
                Err(error) => {
                    self.pending_engine_events.clear();
                    let _ = events
                        .send(EngineEvent::Log {
                            log: EngineLogEvent {
                                level: "error".to_owned(),
                                message: format!("relay event handling failed: {error}"),
                            },
                        })
                        .await;
                }
            }
        }
    }

    fn handle_relay_event(
        &mut self,
        event: RelayEvent,
    ) -> EngineResult<(
        Vec<torchat_client_runtime::RuntimeEvent>,
        Option<ConnectionSnapshot>,
        Option<EngineLogEvent>,
    )> {
        match event {
            RelayEvent::Connected => {
                self.connection_state = ConnectionState::Connected;
                let (_, mut runtime_events) =
                    self.with_runtime(|runtime| runtime.expedite_retry_after_ready())?;
                runtime_events.push(transport_status_event(
                    torchat_client_runtime::TransportComponent::Relay,
                    torchat_client_runtime::TransportProbeState::Ready,
                    "relay connected",
                    Some(100),
                    self.tor_status.latency_ms,
                    0,
                    None,
                    self.connection_generation,
                    self.socks5_url.clone(),
                    self.clock.now_ms(),
                ));
                self.flush_pending_send_effects()?;
                self.flush_pending_receipt_effects()?;
                self.retry_pending_welcomes()?;
                self.retry_pending_contact_confirmations()?;
                self.queue_relay_endpoint_bootstraps()?;
                self.send_capability_offers_for_contacts()?;
                self.retry_capability_deliveries()?;
                Ok((
                    runtime_events,
                    Some(self.connection_snapshot("relay connected")),
                    Some(EngineLogEvent {
                        level: "info".to_owned(),
                        message: "relay connected".to_owned(),
                    }),
                ))
            }
            RelayEvent::Backoff {
                attempt,
                retry_in_ms,
                detail,
            } => {
                self.connection_state = ConnectionState::Backoff {
                    attempt,
                    retry_in_ms,
                };
                let runtime_events = vec![transport_status_event(
                    torchat_client_runtime::TransportComponent::Relay,
                    torchat_client_runtime::TransportProbeState::Degraded,
                    detail.clone(),
                    None,
                    None,
                    attempt,
                    Some(retry_in_ms),
                    self.connection_generation,
                    None,
                    self.clock.now_ms(),
                )];
                Ok((
                    runtime_events,
                    Some(self.connection_snapshot("relay reconnect backoff")),
                    Some(EngineLogEvent {
                        level: "info".to_owned(),
                        message: format!(
                            "relay reconnect backoff attempt {attempt} retry_in_ms={retry_in_ms}: {detail}"
                        ),
                    }),
                ))
            }
            RelayEvent::Disconnected { detail } => {
                self.connection_state = ConnectionState::Disconnected;
                self.requeue_after_disconnect()?;
                Ok((
                    vec![transport_status_event(
                        torchat_client_runtime::TransportComponent::Relay,
                        torchat_client_runtime::TransportProbeState::Offline,
                        detail.clone(),
                        None,
                        None,
                        self.relay_retry_attempt,
                        None,
                        self.connection_generation,
                        None,
                        self.clock.now_ms(),
                    )],
                    Some(self.connection_snapshot("relay disconnected")),
                    Some(EngineLogEvent {
                        level: "warn".to_owned(),
                        message: format!("relay disconnected: {detail}"),
                    }),
                ))
            }
            RelayEvent::PairingAvailable { pairing_id } => {
                self.enqueue_pairing_inbox_refresh();
                Ok((
                    Vec::new(),
                    None,
                    Some(EngineLogEvent {
                        level: "info".to_owned(),
                        message: format!(
                            "pairing inbox synchronization scheduled after relay notification pairing_id={pairing_id}"
                        ),
                    }),
                ))
            }
            RelayEvent::Envelope(envelope) => self
                .handle_relay_envelope(envelope)
                .map(|events| (events, None, None)),
            RelayEvent::MessageTransportOutcome {
                message_id,
                outcome,
            } => {
                let runtime_events = self.handle_relay_delivery_outcome(message_id, outcome)?;
                Ok((runtime_events, None, None))
            }
        }
    }

    fn handle_relay_delivery_outcome(
        &mut self,
        envelope_id: uuid::Uuid,
        outcome: MessageTransportOutcome,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        let delivery = self.pending_relay_deliveries.remove(&envelope_id);
        match delivery {
            Some(PendingRelayDelivery::PairingResponse { pairing_id }) => {
                match outcome {
                    MessageTransportOutcome::Forwarded
                    | MessageTransportOutcome::Delivered
                    | MessageTransportOutcome::PeerPersisted
                    | MessageTransportOutcome::PeerDelivered => {
                        self.database.complete_pairing_response(&pairing_id)?;
                    }
                    MessageTransportOutcome::RecipientOffline
                    | MessageTransportOutcome::PeerUnavailable
                    | MessageTransportOutcome::PeerAuthenticationFailed
                    | MessageTransportOutcome::PeerRejected
                    | MessageTransportOutcome::RetryableFailure
                    | MessageTransportOutcome::PermanentFailure => {
                        self.database.record_pairing_response_error(
                            &pairing_id,
                            "relay did not forward pairing response",
                        )?;
                    }
                }
                Ok(Vec::new())
            }
            Some(PendingRelayDelivery::Welcome { invite_id }) => {
                match outcome {
                    MessageTransportOutcome::Forwarded
                    | MessageTransportOutcome::Delivered
                    | MessageTransportOutcome::PeerPersisted
                    | MessageTransportOutcome::PeerDelivered => {
                        // Relay acceptance is not application-level delivery.
                        // Keep retrying until the peer signs WelcomeApplied.
                    }
                    MessageTransportOutcome::RecipientOffline
                    | MessageTransportOutcome::PeerUnavailable
                    | MessageTransportOutcome::PeerAuthenticationFailed
                    | MessageTransportOutcome::PeerRejected
                    | MessageTransportOutcome::RetryableFailure
                    | MessageTransportOutcome::PermanentFailure => {
                        self.database.record_pending_welcome_error(
                            &invite_id,
                            "relay did not forward MLS Welcome",
                        )?;
                    }
                }
                Ok(Vec::new())
            }
            Some(PendingRelayDelivery::Message { message_id }) => match outcome {
                MessageTransportOutcome::Forwarded
                | MessageTransportOutcome::Delivered
                | MessageTransportOutcome::PeerPersisted
                | MessageTransportOutcome::PeerDelivered => {
                    self.database.complete_outbound_delivery(&message_id)?;
                    self.apply_message_transport_outcome(
                        &message_id,
                        MessageTransportOutcome::Forwarded,
                    )
                }
                MessageTransportOutcome::RecipientOffline
                | MessageTransportOutcome::PeerUnavailable
                | MessageTransportOutcome::PeerAuthenticationFailed
                | MessageTransportOutcome::PeerRejected
                | MessageTransportOutcome::RetryableFailure
                | MessageTransportOutcome::PermanentFailure => {
                    let attempt = self
                        .database
                        .outbound_delivery(&message_id)?
                        .map(|record| record.attempt_count)
                        .unwrap_or(0);
                    self.database.requeue_outbound_delivery(
                        &message_id,
                        self.clock.now_ms() + retry_backoff_ms(attempt),
                        "relay did not forward message",
                    )?;
                    self.apply_message_transport_outcome(
                        &message_id,
                        MessageTransportOutcome::RetryableFailure,
                    )
                }
            },
            Some(PendingRelayDelivery::Receipt { message_id }) => {
                match outcome {
                    MessageTransportOutcome::Forwarded
                    | MessageTransportOutcome::Delivered
                    | MessageTransportOutcome::PeerPersisted
                    | MessageTransportOutcome::PeerDelivered => {
                        self.database.complete_delivery_receipt(&message_id)?;
                    }
                    MessageTransportOutcome::RecipientOffline
                    | MessageTransportOutcome::PeerUnavailable
                    | MessageTransportOutcome::PeerAuthenticationFailed
                    | MessageTransportOutcome::PeerRejected
                    | MessageTransportOutcome::RetryableFailure
                    | MessageTransportOutcome::PermanentFailure => {
                        let attempt = self
                            .database
                            .delivery_receipt(&message_id)?
                            .map(|record| record.attempt_count)
                            .unwrap_or(0);
                        self.database.requeue_delivery_receipt(
                            &message_id,
                            self.clock.now_ms() + retry_backoff_ms(attempt),
                            "relay did not forward receipt",
                        )?;
                    }
                }
                Ok(Vec::new())
            }
            Some(PendingRelayDelivery::ReadReceipt { receipt_id }) => {
                match outcome {
                    MessageTransportOutcome::Forwarded
                    | MessageTransportOutcome::Delivered
                    | MessageTransportOutcome::PeerPersisted
                    | MessageTransportOutcome::PeerDelivered => {
                        self.database.complete_read_receipt(&receipt_id)?;
                    }
                    _ => {
                        let attempt = self
                            .database
                            .read_receipt(&receipt_id)?
                            .map(|record| record.attempt_count)
                            .unwrap_or(0);
                        self.database.requeue_read_receipt(
                            &receipt_id,
                            self.clock.now_ms() + retry_backoff_ms(attempt),
                            "relay did not forward read receipt",
                        )?;
                    }
                }
                Ok(Vec::new())
            }
            Some(PendingRelayDelivery::Ephemeral {
                installation_id,
                delivery_id,
            }) => {
                if let Some(delivery_id) = delivery_id {
                    if matches!(
                        outcome,
                        MessageTransportOutcome::Forwarded
                            | MessageTransportOutcome::Delivered
                            | MessageTransportOutcome::PeerPersisted
                            | MessageTransportOutcome::PeerDelivered
                    ) {
                        self.database.complete_capability_delivery(&delivery_id)?;
                    } else {
                        self.database.record_capability_delivery_error(
                            &delivery_id,
                            self.clock.now_ms() + retry_backoff_ms(1),
                            &format!("capability relay outcome: {outcome:?}"),
                        )?;
                    }
                }
                self.pending_engine_events.push(EngineEvent::Log {
                    log: EngineLogEvent {
                        level: match outcome {
                            MessageTransportOutcome::Forwarded
                            | MessageTransportOutcome::Delivered
                            | MessageTransportOutcome::PeerPersisted
                            | MessageTransportOutcome::PeerDelivered => "info".to_owned(),
                            _ => "warn".to_owned(),
                        },
                        message: format!(
                            "ephemeral relay outcome contact={} outcome={outcome:?}",
                            installation_id
                        ),
                    },
                });
                Ok(Vec::new())
            }
            Some(PendingRelayDelivery::RelationshipRemovalAck { removal_id }) => {
                // The sender's signed application ACK is durable until the
                // relay accepts it. Relay FORWARDED is sufficient for this
                // one-way notification; it must never complete the removal
                // outbox owned by the original sender.
                if matches!(
                    outcome,
                    MessageTransportOutcome::Forwarded
                        | MessageTransportOutcome::Delivered
                        | MessageTransportOutcome::PeerPersisted
                        | MessageTransportOutcome::PeerDelivered
                ) {
                    self.database
                        .complete_relationship_removal_ack_delivery(&removal_id)?;
                }
                Ok(Vec::new())
            }
            Some(PendingRelayDelivery::PeerEndpointBootstrap {
                installation_id,
                sequence,
            }) => {
                if matches!(
                    outcome,
                    MessageTransportOutcome::Forwarded
                        | MessageTransportOutcome::Delivered
                        | MessageTransportOutcome::PeerPersisted
                        | MessageTransportOutcome::PeerDelivered
                ) {
                    self.database
                        .complete_peer_endpoint_bootstrap(&installation_id, sequence)?;
                }
                self.pending_engine_events.push(EngineEvent::Log {
                    log: EngineLogEvent {
                        level: match outcome {
                            MessageTransportOutcome::Forwarded
                            | MessageTransportOutcome::Delivered
                            | MessageTransportOutcome::PeerPersisted
                            | MessageTransportOutcome::PeerDelivered => "info".to_owned(),
                            _ => "warn".to_owned(),
                        },
                        message: format!(
                            "peer endpoint bootstrap outcome contact={} sequence={} outcome={outcome:?}",
                            installation_id, sequence
                        ),
                    },
                });
                Ok(Vec::new())
            }
            None => {
                // Application envelopes use their public message id as the
                // relay envelope id. A late outcome can therefore still be
                // applied after the in-memory correlation was cleared.
                match self.apply_message_transport_outcome(&envelope_id.to_string(), outcome) {
                    Ok(events) => Ok(events),
                    Err(EngineError::InvalidCommand(message))
                        if message.contains("message does not exist") =>
                    {
                        Ok(Vec::new())
                    }
                    Err(error) => Err(error),
                }
            }
        }
    }
}
