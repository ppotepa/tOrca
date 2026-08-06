use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_delete_message_local(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        message_id: String,
    ) -> CommandHandlerResult {
        let (_, runtime_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| {
                torchat_runtime::ClientRuntimeFeatureFacade::feature_delete_message(
                    runtime,
                    &message_id,
                )
                .map(|_| ())
            },
            |_| Ok(ResponsePayload::Empty),
        )?;
        Ok((ResponsePayload::Empty, runtime_events, None))
    }
}
