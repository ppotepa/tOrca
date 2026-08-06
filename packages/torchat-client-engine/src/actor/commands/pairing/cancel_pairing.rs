use super::super::super::*;

use crate::{
    effects::{DeferredCommandContext, RelayEffectOperation},
    processing::EngineProcessingResult,
};
use torchat_runtime::{
    ClientRuntimeFeatureFacade, RuntimeClock,
    features::operations::ClientRuntimeOperationsFacade,
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
        let Some(operation_id) = context.command_id.clone() else {
            return self.command_error_result(
                context.request_id,
                EngineError::InvalidCommand(
                    "cancel pairing requires a durable operation id".to_owned(),
                ),
            );
        };
        let now_ms = self.clock.now_ms();
        match self.with_runtime(|runtime| {
            runtime.feature_begin_pairing_operation(&operation_id, &pairing_id, now_ms)?;
            runtime.feature_prepare_cancel_pairing(&pairing_id)
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
