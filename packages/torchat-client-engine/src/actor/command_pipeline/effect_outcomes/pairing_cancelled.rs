use super::{RelayCommitResult, *};
use torchat_runtime::ClientRuntimeFeatureFacade;

impl ClientEngineActor {
    pub(in crate::actor) fn commit_pairing_cancelled_outcome(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        pairing_id: String,
    ) -> RelayCommitResult {
        self.with_runtime_idempotent(
            idempotency,
            |runtime| {
                runtime
                    .feature_confirm_pairing_cancelled(&pairing_id)
                    .map(|result| result.value)
            },
            |_| Ok(ResponsePayload::Empty),
        )
        .map(|(_, events)| (ResponsePayload::Empty, events))
    }
}
