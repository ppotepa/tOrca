use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_start_conversation(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        contact_id: String,
    ) -> CommandHandlerResult {
        let (created, runtime_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| runtime.start_conversation(&contact_id),
            |value| json_response(value),
        )?;
        let _ = self.queue_peer_probe(&contact_id);
        Ok((json_response(created)?, runtime_events, None))
    }
}
