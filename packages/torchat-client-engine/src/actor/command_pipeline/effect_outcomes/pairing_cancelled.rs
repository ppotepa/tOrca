use super::{RelayCommitResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn commit_pairing_cancelled_outcome(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        pairing_id: String,
    ) -> RelayCommitResult {
        self.with_runtime_idempotent(
            idempotency,
            |runtime| runtime.confirm_pairing_cancelled(&pairing_id),
            |_| Ok(ResponsePayload::Empty),
        )
        .map(|(_, events)| (ResponsePayload::Empty, events))
    }
}
