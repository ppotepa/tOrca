use super::super::{CommandHandlerResult, *};
use torchat_runtime::{
    RuntimeClock, features::messaging::ClientRuntimeMessagingFacade,
};

impl ClientEngineActor {
    pub(in crate::actor) fn command_retry_message(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        message_id: String,
    ) -> CommandHandlerResult {
        let now_ms = self.clock.now_ms();
        let (retry, runtime_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| runtime.feature_retry_message(&message_id, now_ms),
            |_| Ok(ResponsePayload::Empty),
        )?;
        self.deliver_send_effect(retry.value.into())?;
        Ok((ResponsePayload::Empty, runtime_events, None))
    }
}
