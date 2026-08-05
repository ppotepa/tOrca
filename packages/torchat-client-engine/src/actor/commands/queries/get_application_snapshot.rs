use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_get_application_snapshot(&mut self) -> CommandHandlerResult {
        Ok((json_response(self.application_snapshot()?)?, Vec::new(), None))
    }
}
