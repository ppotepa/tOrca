use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_list_conversations(&mut self) -> CommandHandlerResult {
        Ok((json_response(self.list_conversations()?)?, Vec::new(), None))
    }
}
