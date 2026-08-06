use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_reject_pairing(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        pairing_id: String,
    ) -> CommandHandlerResult {
        let now_ms = self.clock.now_ms();
        let now_secs = now_ms / 1_000;
        let operation_id = idempotency.map(|context| context.command_id.clone());
        let (effect, mut runtime_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| {
                if let Some(operation_id) = operation_id.as_deref() {
                    torchat_runtime::ClientOperationFeatureFacade::feature_begin_operation(
                        runtime,
                        operation_id,
                        torchat_runtime::OperationType::Pairing,
                        &pairing_id,
                        now_ms,
                    )?;
                }
                torchat_runtime::ClientPairingFeatureFacade::feature_commit_reject_pairing(
                    runtime,
                    &pairing_id,
                    now_secs,
                )
                .map(|result| result.value)
            },
            |_| Ok(ResponsePayload::Empty),
        )?;
        match self.deliver_send_effect(effect) {
            Ok(()) => {
                if let Some(operation_id) = operation_id.as_deref() {
                    let completed_at = self.clock.now_ms();
                    let (_, mut events) = self.with_runtime(|runtime| {
                        torchat_runtime::ClientOperationFeatureFacade::feature_complete_operation(
                            runtime,
                            operation_id,
                            completed_at,
                        )
                        .map(|_| ())
                    })?;
                    runtime_events.append(&mut events);
                }
                Ok((ResponsePayload::Empty, runtime_events, None))
            }
            Err(error) => {
                if let Some(operation_id) = operation_id.as_deref() {
                    let failed_at = self.clock.now_ms();
                    let _ = self.with_runtime(|runtime| {
                        torchat_runtime::ClientOperationFeatureFacade::feature_retry_operation(
                            runtime,
                            operation_id,
                            torchat_runtime::RetryClass::NetworkBackoff,
                            torchat_runtime::RuntimeErrorCode::TransportUnavailable,
                            failed_at,
                        )
                        .map(|_| ())
                    });
                }
                Err(error)
            }
        }
    }
}
