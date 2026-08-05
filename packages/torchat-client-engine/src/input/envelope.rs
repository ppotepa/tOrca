use crate::{
    EngineCommand, EngineCommandEnvelope, PlatformFact,
    effects::EngineEffectOutcome,
    peer::PeerTransportEvent,
    relay::RelayEvent,
};

use super::{EngineInputKind, EngineInputSource, EngineTimerKind};

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct CommandRequestContext {
    pub request_id: String,
    pub command_id: Option<String>,
}

pub(crate) struct EngineInputEnvelope {
    pub input_id: uuid::Uuid,
    pub correlation_id: Option<String>,
    pub causation_id: Option<uuid::Uuid>,
    pub source: EngineInputSource,
    pub enqueued_at_ms: i64,
    pub input: EngineInput,
}

pub(crate) enum EngineInput {
    Command(EngineCommandEnvelope),
    PeerEvent(PeerTransportEvent),
    RelayEvent(RelayEvent),
    PlatformFact {
        request: Option<CommandRequestContext>,
        fact: PlatformFact,
    },
    TimerElapsed {
        kind: EngineTimerKind,
        generation: u64,
    },
    EffectOutcome(EngineEffectOutcome),
    ShutdownRequested,
}

impl EngineInputEnvelope {
    pub(crate) fn command(enqueued_at_ms: i64, envelope: EngineCommandEnvelope) -> Self {
        let EngineCommandEnvelope {
            request_id,
            command_id,
            command,
        } = envelope;
        match command {
            EngineCommand::PlatformFact { fact } => Self::platform_fact(
                enqueued_at_ms,
                Some(CommandRequestContext {
                    request_id,
                    command_id,
                }),
                fact,
            ),
            command => Self {
                input_id: uuid::Uuid::new_v4(),
                correlation_id: Some(request_id.clone()),
                causation_id: None,
                source: EngineInputSource::ClientApi,
                enqueued_at_ms,
                input: EngineInput::Command(EngineCommandEnvelope {
                    request_id,
                    command_id,
                    command,
                }),
            },
        }
    }

    pub(crate) fn peer_event(enqueued_at_ms: i64, event: PeerTransportEvent) -> Self {
        Self {
            input_id: uuid::Uuid::new_v4(),
            correlation_id: None,
            causation_id: None,
            source: EngineInputSource::Peer,
            enqueued_at_ms,
            input: EngineInput::PeerEvent(event),
        }
    }

    pub(crate) fn relay_event(enqueued_at_ms: i64, event: RelayEvent) -> Self {
        Self {
            input_id: uuid::Uuid::new_v4(),
            correlation_id: None,
            causation_id: None,
            source: EngineInputSource::Relay,
            enqueued_at_ms,
            input: EngineInput::RelayEvent(event),
        }
    }

    pub(crate) fn platform_fact(
        enqueued_at_ms: i64,
        request: Option<CommandRequestContext>,
        fact: PlatformFact,
    ) -> Self {
        let correlation_id = request.as_ref().map(|request| request.request_id.clone());
        Self {
            input_id: uuid::Uuid::new_v4(),
            correlation_id,
            causation_id: None,
            source: EngineInputSource::Platform,
            enqueued_at_ms,
            input: EngineInput::PlatformFact { request, fact },
        }
    }

    pub(crate) fn timer(
        enqueued_at_ms: i64,
        kind: EngineTimerKind,
        generation: u64,
    ) -> Self {
        Self {
            input_id: uuid::Uuid::new_v4(),
            correlation_id: None,
            causation_id: None,
            source: EngineInputSource::Scheduler,
            enqueued_at_ms,
            input: EngineInput::TimerElapsed { kind, generation },
        }
    }

    pub(crate) fn effect_outcome(
        enqueued_at_ms: i64,
        causation_id: uuid::Uuid,
        outcome: EngineEffectOutcome,
    ) -> Self {
        Self {
            input_id: uuid::Uuid::new_v4(),
            correlation_id: None,
            causation_id: Some(causation_id),
            source: EngineInputSource::EffectWorker,
            enqueued_at_ms,
            input: EngineInput::EffectOutcome(outcome),
        }
    }

    pub(crate) fn shutdown(enqueued_at_ms: i64) -> Self {
        Self {
            input_id: uuid::Uuid::new_v4(),
            correlation_id: None,
            causation_id: None,
            source: EngineInputSource::Platform,
            enqueued_at_ms,
            input: EngineInput::ShutdownRequested,
        }
    }

    pub(crate) fn into_command_envelope(self) -> Option<EngineCommandEnvelope> {
        match self.input {
            EngineInput::Command(envelope) => Some(envelope),
            EngineInput::PlatformFact {
                request: Some(request),
                fact,
            } => Some(EngineCommandEnvelope {
                request_id: request.request_id,
                command_id: request.command_id,
                command: EngineCommand::PlatformFact { fact },
            }),
            _ => None,
        }
    }

    pub(crate) fn kind(&self) -> EngineInputKind {
        match &self.input {
            EngineInput::Command(_) => EngineInputKind::Command,
            EngineInput::PeerEvent(_) => EngineInputKind::PeerEvent,
            EngineInput::RelayEvent(_) => EngineInputKind::RelayEvent,
            EngineInput::PlatformFact { .. } => EngineInputKind::PlatformFact,
            EngineInput::TimerElapsed { .. } => EngineInputKind::TimerElapsed,
            EngineInput::EffectOutcome(_) => EngineInputKind::EffectOutcome,
            EngineInput::ShutdownRequested => EngineInputKind::ShutdownRequested,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_input_preserves_request_correlation() {
        let input = EngineInputEnvelope::command(
            123,
            EngineCommandEnvelope {
                request_id: "request-1".to_owned(),
                command_id: Some("command-1".to_owned()),
                command: EngineCommand::Bootstrap,
            },
        );
        assert_eq!(input.correlation_id.as_deref(), Some("request-1"));
        assert_eq!(input.kind(), EngineInputKind::Command);
    }

    #[test]
    fn platform_command_preserves_request_context() {
        let input = EngineInputEnvelope::command(
            321,
            EngineCommandEnvelope {
                request_id: "request-platform".to_owned(),
                command_id: Some("command-platform".to_owned()),
                command: EngineCommand::PlatformFact {
                    fact: PlatformFact::NetworkChanged { online: false },
                },
            },
        );
        assert_eq!(input.kind(), EngineInputKind::PlatformFact);
        let restored = input.into_command_envelope().expect("platform command restored");
        assert_eq!(restored.request_id, "request-platform");
    }
}
