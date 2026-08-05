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
        Vec<torchat_runtime::RuntimeEvent>,
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
                let (_, events) = self.with_runtime(|runtime| {
                    runtime.finalize_pairing(&pairing_id.to_string())
                })?;
                Ok((events, None, None))
            }
            RelayEvent::Envelope(envelope) => self
                .handle_relay_envelope(envelope)
                .map(|events| (events, None, None)),
        }
    }

}
