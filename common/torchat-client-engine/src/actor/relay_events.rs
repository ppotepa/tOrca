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
            RelayEvent::PairingAvailable { pairing_id } => {
                let events = self.apply_pairing_peer_outcome(
                    &pairing_id.to_string(),
                    PairingPeerOutcome::RejectionReceived,
                )?;
                Ok((events, None, None))
            }
            RelayEvent::PairingFinalized { pairing_id } => {
                let events = self.apply_pairing_peer_outcome(
                    &pairing_id.to_string(),
                    PairingPeerOutcome::WelcomePrepared,
                )?;
                Ok((events, None, None))
            }
            RelayEvent::Envelope(envelope) => self
                .handle_relay_envelope(envelope)
                .map(|events| (events, None, None)),
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
                    MessageTransportOutcome::Delivered
                    | MessageTransportOutcome::PeerPersisted
                    | MessageTransportOutcome::PeerDelivered => {
                        self.database.complete_pairing_response(&pairing_id)?;
                    }
                    MessageTransportOutcome::PeerUnavailable
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
                    MessageTransportOutcome::Delivered
                    | MessageTransportOutcome::PeerPersisted
                    | MessageTransportOutcome::PeerDelivered => {
                        // Relay acceptance is not application-level delivery.
                        // Keep retrying until the peer signs WelcomeApplied.
                    }
                    MessageTransportOutcome::PeerUnavailable
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
            Some(PendingRelayDelivery::Ephemeral {
                installation_id,
                delivery_id,
            }) => {
                if let Some(delivery_id) = delivery_id {
                    if matches!(
                        outcome,
                        MessageTransportOutcome::Delivered
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
                            MessageTransportOutcome::Delivered
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
