use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_list_messages(
        &mut self,
        conversation_id: String,
    ) -> CommandHandlerResult {
        Ok((
            json_response(self.list_messages(&conversation_id)?)?,
            Vec::new(),
            None,
        ))
    }
}
