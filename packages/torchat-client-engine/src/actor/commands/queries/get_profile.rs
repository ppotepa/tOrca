use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_get_profile(&mut self) -> CommandHandlerResult {
        Ok((json_response(self.runtime_profile()?)?, Vec::new(), None))
    }
}
