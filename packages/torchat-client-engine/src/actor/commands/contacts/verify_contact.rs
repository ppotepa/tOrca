use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_verify_contact(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        installation_id: String,
    ) -> CommandHandlerResult {
        let (_, runtime_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| runtime.verify_contact(&installation_id),
            |_| json_response(true),
        )?;
        Ok((json_response(true)?, runtime_events, None))
    }
}
