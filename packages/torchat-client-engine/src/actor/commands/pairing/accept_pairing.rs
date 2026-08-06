use super::super::{CommandHandlerResult, *};

impl ClientEngineActor {
    pub(in crate::actor) fn command_accept_pairing(
        &mut self,
        idempotency: Option<&IdempotencyCommitContext>,
        pairing_id: String,
    ) -> CommandHandlerResult {
        let now_ms = self.clock.now_ms();
        let now_secs = now_ms / 1_000;
        let operation_id = idempotency.map(|context| context.command_id.clone());
        let mut runtime_events = Vec::new();
        if let Some(operation_id) = operation_id.as_deref() {
            let (_, mut events) = self.with_runtime(|runtime| {
                torchat_runtime::ClientOperationFeatureFacade::feature_begin_operation(
                    runtime,
                    operation_id,
                    torchat_runtime::OperationType::Pairing,
                    &pairing_id,
                    now_ms,
                )
                .map(|_| ())
            })?;
            runtime_events.append(&mut events);
        }
        let (_preparation, mut prepare_events): (PairingPreparation, _) =
            self.with_runtime(|runtime| {
                torchat_runtime::ClientPairingFeatureFacade::feature_prepare_accept_pairing(
                    runtime,
                    &pairing_id,
                    now_secs,
                )
            })?;
        runtime_events.append(&mut prepare_events);
        let (offer, mut read_events) = self.with_runtime(|runtime| {
            torchat_runtime::ClientPairingFeatureFacade::feature_pairing_offer_payload(
                runtime,
                &pairing_id,
            )
        })?;
        runtime_events.append(&mut read_events);
        match self.accept_invite(&offer) {
            Ok(mut accept_events) => runtime_events.append(&mut accept_events),
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
                return Err(error);
            }
        }
        let completed_at = self.clock.now_ms();
        let (_, mut commit_events) = self.with_runtime_idempotent(
            idempotency,
            |runtime| {
                torchat_runtime::ClientPairingFeatureFacade::feature_accept_received_pairing(
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
        )?;
        runtime_events.append(&mut commit_events);
        Ok((ResponsePayload::Empty, runtime_events, None))
    }
}
