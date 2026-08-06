use super::{RelayCommitResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn commit_pairing_cancelled_outcome(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        pairing_id: String,
    ) -> RelayCommitResult {
        let completed_at = self.clock.now_ms();
        let operation_id = idempotency.map(|context| context.command_id.clone());
        self.with_runtime_idempotent(
            idempotency,
            |runtime| {
                torchat_runtime::ClientPairingFeatureFacade::feature_confirm_pairing_cancelled(
                    runtime,
                    &pairing_id,
                )?;
                if let Some(operation_id) = operation_id.as_deref() {
                    torchat_runtime::ClientOperationFeatureFacade::feature_complete_operation(
                        runtime,
                        operation_id,
                        completed_at,
                    )?;
                }
                Ok(())
            },
            |_| Ok(ResponsePayload::Empty),
        )
        .map(|(_, events)| (ResponsePayload::Empty, events))
    }
}
