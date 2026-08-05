use crate::{EngineCommandEnvelope, PlatformFact, peer::PeerTransportEvent, relay::RelayEvent};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum EngineInputSource {
    ClientApi,
    Ffi,
    Relay,
    Peer,
    Platform,
    Scheduler,
    EffectWorker,
    Recovery,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum EngineInputKind {
    Command,
    PeerEvent,
    RelayEvent,
    PlatformFact,
    TimerElapsed,
    EffectOutcome,
    ShutdownRequested,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum EngineTimerKind {
    RelayPoll,
    PeerProbeRound,
    RetryDue,
}

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
    EffectOutcome,
    ShutdownRequested,
}

impl EngineInputEnvelope {
    pub(crate) fn command(enqueued_at_ms: i64, envelope: EngineCommandEnvelope) -> Self {
        let correlation_id = Some(envelope.request_id.clone());
        Self {
            input_id: uuid::Uuid::new_v4(),
            correlation_id,
            causation_id: None,
            source: EngineInputSource::ClientApi,
            enqueued_at_ms,
            input: EngineInput::Command(envelope),
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

    pub(crate) fn kind(&self) -> EngineInputKind {
        match &self.input {
            EngineInput::Command(_) => EngineInputKind::Command,
            EngineInput::PeerEvent(_) => EngineInputKind::PeerEvent,
            EngineInput::RelayEvent(_) => EngineInputKind::RelayEvent,
            EngineInput::PlatformFact { .. } => EngineInputKind::PlatformFact,
            EngineInput::TimerElapsed { .. } => EngineInputKind::TimerElapsed,
            EngineInput::EffectOutcome => EngineInputKind::EffectOutcome,
            EngineInput::ShutdownRequested => EngineInputKind::ShutdownRequested,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::EngineCommand;

    #[test]
    fn command_input_preserves_request_correlation() {
        let command = EngineCommandEnvelope {
            request_id: "request-1".to_owned(),
            command_id: Some("command-1".to_owned()),
            command: EngineCommand::Bootstrap,
        };

        let input = EngineInputEnvelope::command(123, command);

        assert!(!input.input_id.is_nil());
        assert_eq!(input.correlation_id.as_deref(), Some("request-1"));
        assert_eq!(input.source, EngineInputSource::ClientApi);
        assert_eq!(input.enqueued_at_ms, 123);
        assert_eq!(input.kind(), EngineInputKind::Command);
    }

    #[test]
    fn timer_input_carries_generation() {
        let input = EngineInputEnvelope::timer(456, EngineTimerKind::RetryDue, 7);

        match input.input {
            EngineInput::TimerElapsed { kind, generation } => {
                assert_eq!(kind, EngineTimerKind::RetryDue);
                assert_eq!(generation, 7);
            }
            _ => panic!("expected timer input"),
        }
    }

    #[test]
    fn shutdown_is_a_first_class_input() {
        let input = EngineInputEnvelope::shutdown(789);
        assert_eq!(input.kind(), EngineInputKind::ShutdownRequested);
        assert_eq!(input.source, EngineInputSource::Platform);
    }
}
