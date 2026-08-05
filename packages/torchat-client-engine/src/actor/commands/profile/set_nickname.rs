use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_set_nickname(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        nickname: String,
    ) -> CommandHandlerResult {
        let (profile, runtime_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| runtime.commit_nickname(nickname),
            |value| json_response(value),
        )?;
        Ok((json_response(profile)?, runtime_events, None))
    }
}
