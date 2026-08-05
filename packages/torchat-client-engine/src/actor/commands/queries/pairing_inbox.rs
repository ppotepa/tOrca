use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_pairing_inbox(&mut self) -> CommandHandlerResult {
        let (inbox, _) = self.with_runtime(|runtime| runtime.local_pairing_lists())?;
        Ok((json_response(inbox)?, Vec::new(), None))
    }
}
