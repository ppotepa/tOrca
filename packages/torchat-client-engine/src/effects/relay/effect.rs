use crate::EngineRelay;

use super::{DeferredCommandContext, RelayEffectOperation};

pub(crate) struct RelayEffect {
    pub(crate) context: DeferredCommandContext,
    pub(crate) relay: Box<dyn EngineRelay>,
    pub(crate) operation: RelayEffectOperation,
}

pub(crate) enum EngineEffect {
    Relay(RelayEffect),
}

pub(crate) struct EngineEffectEnvelope {
    pub effect_id: uuid::Uuid,
    pub causation_id: uuid::Uuid,
    pub effect: EngineEffect,
}

impl EngineEffectEnvelope {
    pub(crate) fn relay(
        causation_id: uuid::Uuid,
        context: DeferredCommandContext,
        relay: Box<dyn EngineRelay>,
        operation: RelayEffectOperation,
    ) -> Self {
        Self {
            effect_id: uuid::Uuid::new_v4(),
            causation_id,
            effect: EngineEffect::Relay(RelayEffect {
                context,
                relay,
                operation,
            }),
        }
    }
}
