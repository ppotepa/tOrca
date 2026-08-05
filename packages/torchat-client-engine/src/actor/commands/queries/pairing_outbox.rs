use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_pairing_outbox(&mut self) -> CommandHandlerResult {
        let (result, runtime_events) = self.with_runtime(|runtime| runtime.pairing_outbox())?;
        Ok((json_response(result)?, runtime_events, None))
    }
}
