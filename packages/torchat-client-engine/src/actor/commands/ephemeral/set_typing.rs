use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_set_typing(
        &mut self,
        conversation_id: String,
        typing: bool,
    ) -> CommandHandlerResult {
        self.queue_peer_typing(&conversation_id, typing)?;
        Ok((ResponsePayload::Empty, Vec::new(), None))
    }
}
