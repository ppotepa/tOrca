use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_retry_message(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        message_id: String,
    ) -> CommandHandlerResult {
        let now_ms = self.clock.now_ms();
        let (effect, runtime_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| {
                torchat_runtime::ClientRuntimeFeatureFacade::feature_retry_message(
                    runtime,
                    &message_id,
                    now_ms,
                )
                .map(|result| result.value)
            },
            |_| Ok(ResponsePayload::Empty),
        )?;
        self.deliver_send_effect(effect.into())?;
        Ok((ResponsePayload::Empty, runtime_events, None))
    }
}
