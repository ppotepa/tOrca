use super::{RelayCommitResult, *};
use torchat_runtime::{
    ClientRuntimeFeatureFacade, RuntimeClock, RuntimeErrorCode,
    features::operations::ClientRuntimeOperationsFacade,
};

impl ClientEngineActor {
    pub(in crate::actor) fn commit_pairing_cancelled_outcome(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        pairing_id: String,
    ) -> RelayCommitResult {
        let idempotency = idempotency.ok_or_else(|| {
            EngineError::InvalidCommand(
                "cancel pairing outcome is missing its durable operation id".to_owned(),
            )
        })?;
        let operation_id = idempotency.command_id.clone();
        let now_ms = self.clock.now_ms();
        self.with_runtime_idempotent(
            Some(idempotency),
            |runtime| {
                let state = runtime
                    .feature_confirm_pairing_cancelled(&pairing_id)?
                    .value;
                runtime.feature_complete_pairing_operation(
                    &operation_id,
                    &pairing_id,
                    now_ms,
                )?;
                Ok(state)
            },
            |_| Ok(ResponsePayload::Empty),
        )
        .map(|(_, events)| (ResponsePayload::Empty, events))
    }

    pub(in crate::actor) fn record_pairing_cancel_failure(
        &mut self,
        operation_id: &str,
        pairing_id: &str,
    ) -> EngineResult<()> {
        let now_ms = self.clock.now_ms();
        self.with_runtime(|runtime| {
            runtime.feature_retry_pairing_operation(
                operation_id,
                pairing_id,
                RuntimeErrorCode::TransportUnavailable,
                now_ms,
            )?;
            Ok(())
        })
        .map(|_| ())
    }
}
