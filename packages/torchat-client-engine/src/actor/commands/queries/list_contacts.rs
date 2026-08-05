use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_list_contacts(&mut self) -> CommandHandlerResult {
        Ok((json_response(self.list_contacts()?)?, Vec::new(), None))
    }
}
