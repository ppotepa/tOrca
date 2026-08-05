use super::{RelayCommitResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn commit_pairing_submitted_outcome(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        item: PairingItem,
    ) -> RelayCommitResult {
        self.with_runtime_idempotent(
            idempotency,
            |runtime| runtime.commit_submitted_pairing(item.clone()),
            |value| json_response(value),
        )
        .and_then(|(value, events)| Ok((json_response(value)?, events)))
    }
}
