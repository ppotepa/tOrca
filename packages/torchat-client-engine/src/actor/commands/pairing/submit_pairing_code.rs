use super::super::super::*;

use crate::{effects::DeferredCommandContext, processing::EngineProcessingResult};

impl ClientEngineActor {
    pub(in crate::actor) fn command_submit_pairing_code(
        &mut self,
        input_id: uuid::Uuid,
        context: DeferredCommandContext,
        code: String,
    ) -> EngineProcessingResult {
        if let Err(result) = self.ensure_relay_effect_available(context.request_id.clone()) {
            return result;
        }
        match self.prepare_submit_pairing_effect(code) {
            Ok((operation, runtime_events)) => {
                self.defer_relay_effect(input_id, context, operation, runtime_events)
            }
            Err(error) => self.command_error_result(context.request_id, error),
        }
    }
}
