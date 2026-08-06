use super::super::{CommandHandlerResult, *};

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
                torchat_runtime::ClientRuntimeFeatureFacade::feature_verify_contact(
                    runtime,
                    &installation_id,
                    now_ms,
                )
                .map(|_| ())
            },
            |_| json_response(true),
        )?;
        Ok((json_response(true)?, runtime_events, None))
    }
}
