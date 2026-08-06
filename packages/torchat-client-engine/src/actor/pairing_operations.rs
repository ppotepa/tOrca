use super::*;

impl ClientEngineActor {
    pub(super) fn apply_pairing_peer_outcome_with_operation(
        &mut self,
        pairing_id: &str,
        outcome: PairingPeerOutcome,
    ) -> EngineResult<Vec<torchat_runtime::RuntimeEvent>> {
        let now_ms = self.clock.now_ms();
        let (_, runtime_events) = self.with_runtime(|runtime| {
            torchat_runtime::ClientPairingFeatureFacade::feature_apply_pairing_peer_outcome(
                runtime,
                pairing_id,
                outcome,
            )?;
            ensure_pairing_operation(runtime, pairing_id, now_ms)?;
            match outcome {
                PairingPeerOutcome::OfferReceived => {}
                PairingPeerOutcome::WelcomePrepared => {
                    torchat_runtime::ClientOperationFeatureFacade::feature_complete_operation(
                        runtime,
                        pairing_id,
                        now_ms,
                    )?;
                }
                PairingPeerOutcome::RejectionReceived => {
                    torchat_runtime::ClientOperationFeatureFacade::feature_fail_operation(
                        runtime,
                        pairing_id,
                        torchat_runtime::RuntimeErrorCode::Conflict,
                        now_ms,
                    )?;
                }
            }
            Ok(())
        })?;
        Ok(runtime_events)
    }

    pub(super) fn finalize_pairing_with_operation(
        &mut self,
        pairing_id: &str,
    ) -> EngineResult<Vec<torchat_runtime::RuntimeEvent>> {
        let now_ms = self.clock.now_ms();
        let (_, runtime_events) = self.with_runtime(|runtime| {
            torchat_runtime::ClientPairingFeatureFacade::feature_finalize_pairing(
                runtime,
                pairing_id,
            )?;
            ensure_pairing_operation(runtime, pairing_id, now_ms)?;
            torchat_runtime::ClientOperationFeatureFacade::feature_complete_operation(
                runtime,
                pairing_id,
                now_ms,
            )?;
            Ok(())
        })?;
        Ok(runtime_events)
    }

    pub(super) fn reconcile_outbox_pairing_contact_with_operations(
        &mut self,
        installation_id: &str,
    ) -> EngineResult<Vec<torchat_runtime::RuntimeEvent>> {
        let now_ms = self.clock.now_ms();
        let (_, runtime_events) = self.with_runtime(|runtime| {
            let pairing_ids = torchat_runtime::ClientPairingFeatureFacade::feature_reconcile_outbox_pairing_contact(
                runtime,
                installation_id,
            )?
            .value;
            for pairing_id in pairing_ids {
                ensure_pairing_operation(runtime, &pairing_id, now_ms)?;
                torchat_runtime::ClientOperationFeatureFacade::feature_complete_operation(
                    runtime,
                    &pairing_id,
                    now_ms,
                )?;
            }
            Ok(())
        })?;
        Ok(runtime_events)
    }

    pub(super) fn retry_pairing_operation(
        &mut self,
        pairing_id: &str,
    ) -> EngineResult<Vec<torchat_runtime::RuntimeEvent>> {
        let now_ms = self.clock.now_ms();
        let (_, runtime_events) = self.with_runtime(|runtime| {
            ensure_pairing_operation(runtime, pairing_id, now_ms)?;
            torchat_runtime::ClientOperationFeatureFacade::feature_retry_operation(
                runtime,
                pairing_id,
                torchat_runtime::RetryClass::NetworkBackoff,
                torchat_runtime::RuntimeErrorCode::TransportUnavailable,
                now_ms,
            )?;
            Ok(())
        })?;
        Ok(runtime_events)
    }

    pub(super) fn fail_pairing_operation(
        &mut self,
        pairing_id: &str,
        error_code: torchat_runtime::RuntimeErrorCode,
    ) -> EngineResult<Vec<torchat_runtime::RuntimeEvent>> {
        let now_ms = self.clock.now_ms();
        let (_, runtime_events) = self.with_runtime(|runtime| {
            ensure_pairing_operation(runtime, pairing_id, now_ms)?;
            torchat_runtime::ClientOperationFeatureFacade::feature_fail_operation(
                runtime,
                pairing_id,
                error_code,
                now_ms,
            )?;
            Ok(())
        })?;
        Ok(runtime_events)
    }
}

fn ensure_pairing_operation<S, T, C>(
    runtime: &mut torchat_runtime::ClientRuntime<S, T, C>,
    pairing_id: &str,
    now_ms: i64,
) -> torchat_runtime::RuntimeResult<()>
where
    S: torchat_runtime::RuntimeStorage
        + torchat_runtime::OperationStorage
        + torchat_runtime::PointLookupStorage,
    T: torchat_runtime::RuntimeTransport,
    C: torchat_runtime::RuntimeClock,
{
    torchat_runtime::ClientOperationFeatureFacade::feature_ensure_operation(
        runtime,
        pairing_id,
        torchat_runtime::OperationType::Pairing,
        pairing_id,
        now_ms,
    )
    .map(|_| ())
}
