use super::super::super::*;

use crate::{
    effects::{DeferredCommandContext, RelayEffectOperation},
    processing::EngineProcessingResult,
};

impl ClientEngineActor {
    pub(in crate::actor) fn command_cancel_pairing(
        &mut self,
        input_id: uuid::Uuid,
        context: DeferredCommandContext,
        pairing_id: String,
    ) -> EngineProcessingResult {
        if let Err(result) = self.ensure_relay_effect_available(context.request_id.clone()) {
            return result;
        }
        let operation_id = context.command_id.clone();
        let now_ms = self.clock.now_ms();
        match self.with_runtime(|runtime| {
            if let Some(operation_id) = operation_id.as_deref() {
                torchat_runtime::ClientOperationFeatureFacade::feature_begin_operation(
                    runtime,
                    operation_id,
                    torchat_runtime::OperationType::Pairing,
                    &pairing_id,
                    now_ms,
                )?;
            }
            torchat_runtime::ClientPairingFeatureFacade::feature_prepare_cancel_pairing(
                runtime,
                &pairing_id,
            )
        }) {
            Ok((prepared, runtime_events)) => self.defer_relay_effect(
                input_id,
                context,
                RelayEffectOperation::CancelPairing {
                    pairing_id: prepared.pairing_id,
                },
                runtime_events,
            ),
            Err(error) => self.command_error_result(context.request_id, error),
        }
    }
}
