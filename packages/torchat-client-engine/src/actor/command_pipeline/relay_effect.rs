use super::super::*;

use crate::{
    effects::{
        DeferredCommandContext, EngineEffectEnvelope, RelayEffectOperation,
        RelayEffectPlaceholder,
    },
    processing::EngineProcessingResult,
};

impl ClientEngineActor {
    pub(in crate::actor) fn ensure_relay_effect_available(
        &mut self,
        request_id: String,
    ) -> Result<(), EngineProcessingResult> {
        if self.relay.can_start_effect() {
            return Ok(());
        }
        Err(self.command_error_result(
            request_id,
            EngineError::Transport("rendezvous operation is already in progress".to_owned()),
        ))
    }

    pub(in crate::actor) fn defer_relay_effect(
        &mut self,
        causation_id: uuid::Uuid,
        context: DeferredCommandContext,
        operation: RelayEffectOperation,
        runtime_events: Vec<torchat_runtime::RuntimeEvent>,
    ) -> EngineProcessingResult {
        let relay = std::mem::replace(
            &mut self.relay,
            Box::new(RelayEffectPlaceholder::default()),
        );
        let mut result = EngineProcessingResult::empty();
        result.events.extend(
            runtime_events
                .into_iter()
                .map(|event| EngineEvent::Runtime { event }),
        );
        result.effects.push(EngineEffectEnvelope::relay(
            causation_id,
            context,
            relay,
            operation,
        ));
        result.scheduler_plan_changed = true;
        result
    }

    pub(in crate::actor) fn prepare_submit_pairing_effect(
        &mut self,
        code: String,
    ) -> EngineResult<(RelayEffectOperation, Vec<torchat_runtime::RuntimeEvent>)> {
        let (normalized, runtime_events) =
            self.with_runtime(|runtime| runtime.prepare_submit_pairing_code(code))?;
        let pairing_id = uuid::Uuid::new_v4();
        let invite = self.build_contact_invite(None)?;
        let offer = RelayPayloadV1::pairing_offer(
            pairing_id.to_string(),
            String::new(),
            invite,
        )
        .encode()
        .map_err(EngineError::InvalidCommand)?;
        Ok((
            RelayEffectOperation::SubmitPairingCode {
                code: normalized,
                pairing_id,
                offer,
            },
            runtime_events,
        ))
    }
}
