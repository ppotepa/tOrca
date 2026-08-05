use super::{RelayCommitResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn commit_pairing_code_outcome(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        code: torchat_runtime::InviteCode,
    ) -> RelayCommitResult {
        self.with_runtime_idempotent(
            idempotency,
            |runtime| {
                runtime.commit_pairing_code(code.clone())?;
                Ok(code.clone())
            },
            |value| json_response(value),
        )
        .and_then(|(value, events)| Ok((json_response(value)?, events)))
    }
}
