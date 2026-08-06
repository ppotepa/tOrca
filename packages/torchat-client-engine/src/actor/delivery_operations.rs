use super::*;

impl ClientEngineActor {
    pub(super) fn begin_message_delivery_operation(
        &mut self,
        message_id: &str,
    ) -> EngineResult<Vec<torchat_runtime::RuntimeEvent>> {
        let now_ms = self.clock.now_ms();
        let (_, events) = self.with_runtime(|runtime| {
            torchat_runtime::ClientOperationFeatureFacade::feature_begin_operation(
                runtime,
                message_id,
                torchat_runtime::OperationType::MessageDelivery,
                message_id,
                now_ms,
            )
            .map(|_| ())
        })?;
        Ok(events)
    }

    pub(super) fn complete_message_delivery_operation(
        &mut self,
        message_id: &str,
    ) -> EngineResult<Vec<torchat_runtime::RuntimeEvent>> {
        let now_ms = self.clock.now_ms();
        let (_, events) = self.with_runtime(|runtime| {
            ensure_message_delivery(runtime, message_id, now_ms)?;
            torchat_runtime::ClientOperationFeatureFacade::feature_complete_operation(
                runtime,
                message_id,
                now_ms,
            )
            .map(|_| ())
        })?;
        Ok(events)
    }

    pub(super) fn retry_message_delivery_operation(
        &mut self,
        message_id: &str,
        error_code: torchat_runtime::RuntimeErrorCode,
    ) -> EngineResult<Vec<torchat_runtime::RuntimeEvent>> {
        let now_ms = self.clock.now_ms();
        let (_, events) = self.with_runtime(|runtime| {
            ensure_message_delivery(runtime, message_id, now_ms)?;
            torchat_runtime::ClientOperationFeatureFacade::feature_retry_operation(
                runtime,
                message_id,
                torchat_runtime::RetryClass::NetworkBackoff,
                error_code,
                now_ms,
            )
            .map(|_| ())
        })?;
        Ok(events)
    }

    pub(super) fn fail_message_delivery_operation(
        &mut self,
        message_id: &str,
        error_code: torchat_runtime::RuntimeErrorCode,
    ) -> EngineResult<Vec<torchat_runtime::RuntimeEvent>> {
        let now_ms = self.clock.now_ms();
        let (_, events) = self.with_runtime(|runtime| {
            ensure_message_delivery(runtime, message_id, now_ms)?;
            torchat_runtime::ClientOperationFeatureFacade::feature_fail_operation(
                runtime,
                message_id,
                error_code,
                now_ms,
            )
            .map(|_| ())
        })?;
        Ok(events)
    }
}

fn ensure_message_delivery<S, T, C>(
    runtime: &mut torchat_runtime::ClientRuntime<S, T, C>,
    message_id: &str,
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
        message_id,
        torchat_runtime::OperationType::MessageDelivery,
        message_id,
        now_ms,
    )
    .map(|_| ())
}
