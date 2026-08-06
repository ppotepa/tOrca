use super::super::super::*;

use crate::{
    effects::{DeferredCommandContext, RelayEffectOperation},
    processing::EngineProcessingResult,
};
use torchat_runtime::ClientRuntimeFeatureFacade;

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
        match self.with_runtime(|runtime| runtime.feature_prepare_cancel_pairing(&pairing_id)) {
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
