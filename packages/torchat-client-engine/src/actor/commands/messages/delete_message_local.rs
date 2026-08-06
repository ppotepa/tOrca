use super::super::{CommandHandlerResult, *};
use torchat_runtime::{
    RuntimeClock, features::message_deletion::ClientRuntimeMessageDeletionFacade,
};

impl ClientEngineActor {
    pub(in crate::actor) fn command_delete_message_local(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        message_id: String,
    ) -> CommandHandlerResult {
        let now_ms = self.clock.now_ms();
        let (_, runtime_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| runtime.feature_delete_message_delivery(&message_id, now_ms),
            |_| Ok(ResponsePayload::Empty),
        )?;
        Ok((ResponsePayload::Empty, runtime_events, None))
    }
}
