use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_list_dead_letters(&mut self) -> CommandHandlerResult {
        Ok((
            json_response(self.database.dead_letters()?)?,
            Vec::new(),
            None,
        ))
    }
}
