use super::super::{CommandHandlerResult, *};
use torchat_runtime::{ClientRuntimeFeatureFacade, RuntimeClock};

impl ClientEngineActor {
    pub(in crate::actor) fn command_verify_contact(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        installation_id: String,
    ) -> CommandHandlerResult {
        let now_ms = self.clock.now_ms();
        let (_, runtime_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| {
                runtime
                    .feature_verify_contact(&installation_id, now_ms)
                    .map(|result| result.value)
            },
            |_| json_response(true),
        )?;
        Ok((json_response(true)?, runtime_events, None))
    }
}
