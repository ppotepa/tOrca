use torchat_runtime::{InviteCode, PairingItem};

use crate::EngineRelay;

use super::DeferredCommandContext;

#[allow(clippy::large_enum_variant)]
pub(crate) enum RelayEffectResult {
    PairingCode(Result<InviteCode, String>),
    PairingSubmitted(Result<PairingItem, String>),
    PairingCancelled {
        pairing_id: String,
        result: Result<(), String>,
    },
    WorkerFailed(String),
}

#[allow(dead_code)]
pub(crate) struct RelayEffectOutcome {
    pub effect_id: uuid::Uuid,
    pub context: DeferredCommandContext,
    pub relay: Box<dyn EngineRelay>,
    pub result: RelayEffectResult,
}

pub(crate) enum EngineEffectOutcome {
    Relay(RelayEffectOutcome),
}
