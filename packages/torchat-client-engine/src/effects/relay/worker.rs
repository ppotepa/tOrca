use tokio::sync::mpsc;

use crate::{EngineRelay, input::EngineInputEnvelope};

use super::{
    EngineEffect, EngineEffectEnvelope, EngineEffectOutcome, RelayEffect, RelayEffectOperation,
    RelayEffectOutcome, RelayEffectResult,
};

pub(crate) fn spawn_engine_effect(
    envelope: EngineEffectEnvelope,
    inbox: mpsc::Sender<EngineInputEnvelope>,
) {
    let EngineEffectEnvelope {
        effect_id,
        causation_id,
        effect,
    } = envelope;
    match effect {
        EngineEffect::Relay(effect) => {
            tokio::task::spawn_blocking(move || {
                let RelayEffect {
                    context,
                    mut relay,
                    operation,
                } = effect;
                let correlation_id = context.request_id.clone();
                let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    execute_relay_operation(relay.as_mut(), operation)
                }))
                .unwrap_or_else(|_| {
                    RelayEffectResult::WorkerFailed("rendezvous effect worker panicked".to_owned())
                });
                let outcome = EngineEffectOutcome::Relay(RelayEffectOutcome {
                    effect_id,
                    context,
                    relay,
                    result,
                });
                let _ = inbox.blocking_send(EngineInputEnvelope::effect_outcome_correlated(
                    unix_ms(),
                    causation_id,
                    correlation_id,
                    outcome,
                ));
            });
        }
    }
}

fn execute_relay_operation(
    relay: &mut dyn EngineRelay,
    operation: RelayEffectOperation,
) -> RelayEffectResult {
    match operation {
        RelayEffectOperation::RefreshPairingCode => RelayEffectResult::PairingCode(
            relay
                .refresh_pairing_code()
                .map_err(|error| error.to_string()),
        ),
        RelayEffectOperation::SubmitPairingCode {
            code,
            pairing_id,
            offer,
        } => RelayEffectResult::PairingSubmitted(
            relay
                .submit_pairing_code_with_offer(&code, pairing_id, offer)
                .map_err(|error| error.to_string()),
        ),
        RelayEffectOperation::CancelPairing { pairing_id } => {
            let result = relay
                .cancel_pairing(&pairing_id)
                .map_err(|error| error.to_string());
            RelayEffectResult::PairingCancelled { pairing_id, result }
        }
    }
}

fn unix_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}
