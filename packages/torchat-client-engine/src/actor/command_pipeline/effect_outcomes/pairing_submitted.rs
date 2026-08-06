use super::{RelayCommitResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn commit_pairing_submitted_outcome(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        item: PairingItem,
    ) -> RelayCommitResult {
        self.with_runtime_idempotent(
            idempotency,
            |runtime| {
                torchat_runtime::ClientPairingFeatureFacade::feature_commit_submitted_pairing(
                    runtime,
                    item.clone(),
                )
                .map(|result| result.value)
            },
            |value| json_response(value),
        )
        .and_then(|(value, events)| Ok((json_response(value)?, events)))
    }
}
