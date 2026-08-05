use crate::{
    effects::EngineEffectOutcome,
    input::{EngineInput, EngineInputEnvelope, EngineInputSource},
    relay::RelayEvent,
};

impl EngineInputEnvelope {
    pub(crate) fn relay_event_caused(
        enqueued_at_ms: i64,
        causation_id: uuid::Uuid,
        event: RelayEvent,
    ) -> Self {
        Self {
            input_id: uuid::Uuid::new_v4(),
            correlation_id: None,
            causation_id: Some(causation_id),
            source: EngineInputSource::Relay,
            enqueued_at_ms,
            input: EngineInput::RelayEvent(event),
        }
    }

    pub(crate) fn effect_outcome_correlated(
        enqueued_at_ms: i64,
        causation_id: uuid::Uuid,
        correlation_id: String,
        outcome: EngineEffectOutcome,
    ) -> Self {
        Self {
            input_id: uuid::Uuid::new_v4(),
            correlation_id: Some(correlation_id),
            causation_id: Some(causation_id),
            source: EngineInputSource::EffectWorker,
            enqueued_at_ms,
            input: EngineInput::EffectOutcome(outcome),
        }
    }
}
