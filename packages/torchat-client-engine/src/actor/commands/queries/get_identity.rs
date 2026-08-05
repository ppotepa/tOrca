use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_get_identity(&mut self) -> CommandHandlerResult {
        Ok((json_response(self.runtime_identity()?)?, Vec::new(), None))
    }
}
