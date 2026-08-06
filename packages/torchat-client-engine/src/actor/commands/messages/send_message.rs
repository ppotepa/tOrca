use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_send_message(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        conversation_id: String,
        body: String,
        reply_to_message_id: Option<String>,
    ) -> CommandHandlerResult {
        let (effect, runtime_events) = self.send_message_feature_command(
            idempotency,
            &conversation_id,
            body,
            reply_to_message_id.as_deref(),
        )?;
        Ok((json_response(effect)?, runtime_events, None))
    }
}
