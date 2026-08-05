use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_retry_dead_letter(
        &mut self,
        kind: String,
        id: String,
    ) -> CommandHandlerResult {
        if !self.database.retry_dead_letter(&kind, &id)? {
            return Err(EngineError::InvalidCommand(
                "dead-letter record was not found or is not terminal".to_owned(),
            ));
        }
        Ok((ResponsePayload::Empty, Vec::new(), None))
    }
}
