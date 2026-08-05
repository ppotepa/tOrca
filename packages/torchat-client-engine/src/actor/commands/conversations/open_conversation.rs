use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_open_conversation(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        conversation_id: String,
    ) -> CommandHandlerResult {
        let (_, runtime_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| runtime.open_conversation(conversation_id.clone()),
            |_| json_response(true),
        )?;
        let _ = self.queue_peer_probe(&conversation_id);
        Ok((json_response(true)?, runtime_events, None))
    }
}
