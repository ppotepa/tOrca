use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_retry_message(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        message_id: String,
    ) -> CommandHandlerResult {
        let (effect, runtime_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| runtime.retry_message(&message_id),
            |_| Ok(ResponsePayload::Empty),
        )?;
        self.deliver_send_effect(effect.into())?;
        Ok((ResponsePayload::Empty, runtime_events, None))
    }
}
