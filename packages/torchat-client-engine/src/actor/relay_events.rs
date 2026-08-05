use super::*;

impl ClientEngineActor {
    pub(super) fn collect_relay_events(&mut self) -> Vec<EngineEvent> {
        let mut outputs = Vec::new();
        while let Some(event) = self.relay.poll_event() {
            match self.handle_relay_event(event) {
                Ok((runtime_events, connection_snapshot, log_event)) => {
                    if let Some(snapshot) = connection_snapshot {
                        outputs.push(EngineEvent::Connection { snapshot });
                    }
                    if let Some(log) = log_event {
                        outputs.push(EngineEvent::Log { log });
                    }
                    outputs.extend(
                        runtime_events
                            .into_iter()
                            .map(|event| EngineEvent::Runtime { event }),
                    );
                    outputs.append(&mut self.pending_engine_events);
                }
                Err(error) => {
                    self.pending_engine_events.clear();
                    outputs.push(EngineEvent::Log {
                        log: EngineLogEvent {
                            level: "error".to_owned(),
                            message: format!("relay event handling failed: {error}"),
                        },
                    });
                }
            }
        }
        outputs
    }
}
