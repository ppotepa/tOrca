use tokio::sync::mpsc;
use torchat_runtime::{InviteCode, PairingItem, RuntimeError, RuntimeResult};

use crate::{
    EngineRelay,
    input::EngineInputEnvelope,
    relay::{RelayDeferredControl, RelayEvent},
};

pub(crate) struct DeferredCommandContext {
    pub request_id: String,
    pub command_id: Option<String>,
    pub command_descriptor: String,
}

pub(crate) enum RelayEffectOperation {
    RefreshPairingCode,
    SubmitPairingCode {
        code: String,
        pairing_id: uuid::Uuid,
        offer: String,
    },
    CancelPairing {
        pairing_id: String,
    },
}

pub(crate) struct RelayEffect {
    context: DeferredCommandContext,
    relay: Box<dyn EngineRelay>,
    operation: RelayEffectOperation,
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

pub(crate) enum RelayEffectResult {
    PairingCode(Result<InviteCode, String>),
    PairingSubmitted(Result<PairingItem, String>),
    PairingCancelled {
        pairing_id: String,
        result: Result<(), String>,
    },
    WorkerFailed(String),
}

pub(crate) struct RelayEffectOutcome {
    pub effect_id: uuid::Uuid,
    pub context: DeferredCommandContext,
    pub relay: Box<dyn EngineRelay>,
    pub result: RelayEffectResult,
}

pub(crate) enum EngineEffectOutcome {
    Relay(RelayEffectOutcome),
}

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
                    RelayEffectResult::WorkerFailed(
                        "rendezvous effect worker panicked".to_owned(),
                    )
                });
                let outcome = EngineEffectOutcome::Relay(RelayEffectOutcome {
                    effect_id,
                    context,
                    relay,
                    result,
                });
                let _ = inbox.blocking_send(
                    EngineInputEnvelope::effect_outcome_correlated(
                        unix_ms(),
                        causation_id,
                        correlation_id,
                        outcome,
                    ),
                );
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

#[derive(Default)]
pub(crate) struct RelayEffectPlaceholder {
    deferred: RelayDeferredControl,
}

impl EngineRelay for RelayEffectPlaceholder {
    fn can_start_effect(&self) -> bool {
        false
    }

    fn take_deferred_control(&mut self) -> RelayDeferredControl {
        std::mem::take(&mut self.deferred)
    }

    fn set_socks5_url(&mut self, socks5_url: Option<String>) {
        self.deferred.socks5_url = Some(socks5_url);
    }

    fn invalidate_session(&mut self) {
        self.deferred.invalidate_session = true;
    }

    fn shutdown(&mut self) {}

    fn ensure_session(&mut self) -> RuntimeResult<()> {
        busy()
    }

    fn send_envelope(
        &mut self,
        _message_id: uuid::Uuid,
        _recipient: &str,
        _ciphertext: &str,
    ) -> RuntimeResult<()> {
        busy()
    }

    fn poll_event(&mut self) -> Option<RelayEvent> {
        None
    }

    fn refresh_pairing_code(&mut self) -> RuntimeResult<InviteCode> {
        busy()
    }

    fn submit_pairing_code(&mut self, _code: &str) -> RuntimeResult<PairingItem> {
        busy()
    }

    fn submit_pairing_code_with_offer(
        &mut self,
        _code: &str,
        _pairing_id: uuid::Uuid,
        _offer: String,
    ) -> RuntimeResult<PairingItem> {
        busy()
    }

    fn cancel_pairing(&mut self, _pairing_id: &str) -> RuntimeResult<()> {
        busy()
    }
}

fn busy<T>() -> RuntimeResult<T> {
    Err(RuntimeError::Unavailable(
        "rendezvous effect is already in progress".to_owned(),
    ))
}

fn unix_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}
