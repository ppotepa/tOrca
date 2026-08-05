use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_close_conversation(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
    ) -> CommandHandlerResult {
        let (_, runtime_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| {
                runtime.close_conversation();
                Ok(())
            },
            |_| json_response(true),
        )?;
        Ok((json_response(true)?, runtime_events, None))
    }
}
