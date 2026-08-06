use super::super::super::*;

use crate::{
    effects::{DeferredCommandContext, RelayEffectOperation},
    processing::EngineProcessingResult,
};

impl ClientEngineActor {
    pub(in crate::actor) fn command_refresh_pairing_code(
        &mut self,
        input_id: uuid::Uuid,
        context: DeferredCommandContext,
    ) -> EngineProcessingResult {
        if let Err(result) = self.ensure_relay_effect_available(context.request_id.clone()) {
            return result;
        }
        match self.with_runtime(|runtime| {
            torchat_runtime::ClientPairingFeatureFacade::feature_prepare_pairing_code_refresh(
                runtime,
            )
        }) {
            Ok((_, runtime_events)) => self.defer_relay_effect(
                input_id,
                context,
                RelayEffectOperation::RefreshPairingCode,
                runtime_events,
            ),
            Err(error) => self.command_error_result(context.request_id, error),
        }
    }
}
