use crate::{
    ChangeSections, ChangeSet, ClientRuntime, DurableOperation, FeatureResult, OperationId,
    OperationState, OperationStorage, OperationType, RetryClass, RetryPolicy, RuntimeClock,
    RuntimeError, RuntimeErrorCode, RuntimeResult, RuntimeStorage, RuntimeTransport,
    retry_jitter_seed,
};

pub struct OperationsFeature<'a, S> {
    storage: &'a mut S,
    retry_policy: RetryPolicy,
}

impl<'a, S> OperationsFeature<'a, S>
where
    S: OperationStorage,
{
    pub fn new(storage: &'a mut S) -> Self {
        Self {
            storage,
            retry_policy: RetryPolicy::default(),
        }
    }

    pub fn begin_pairing(
        &mut self,
        operation_id: &str,
        pairing_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>> {
        let operation_id = OperationId::parse(operation_id.to_owned())?;
        let mut operation = self
            .storage
            .operation_by_id(&operation_id)?
            .unwrap_or_else(|| {
                DurableOperation::pending(
                    operation_id.clone(),
                    OperationType::Pairing,
                    pairing_id,
                    now_ms,
                )
            });
        if operation.operation_type != OperationType::Pairing
            || operation.entity_id != pairing_id
        {
            return Err(RuntimeError::Conflict(
                "operation id is already bound to a different workflow".to_owned(),
            ));
        }
        if operation.state == OperationState::Completed {
            return Ok(FeatureResult::unchanged(operation));
        }
        if matches!(
            operation.state,
            OperationState::Cancelled | OperationState::FailedPermanent
        ) {
            return Err(RuntimeError::Conflict(
                "pairing operation is already terminal".to_owned(),
            ));
        }
        operation.begin_attempt(now_ms);
        self.storage.put_operation(operation.clone())?;
        Ok(FeatureResult::changed(
            operation.clone(),
            operation_changes(operation.operation_id.as_str()),
        ))
    }

    pub fn complete_pairing(
        &mut self,
        operation_id: &str,
        pairing_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>> {
        let operation_id = OperationId::parse(operation_id.to_owned())?;
        let mut operation = self
            .storage
            .operation_by_id(&operation_id)?
            .ok_or_else(|| RuntimeError::NotFound("pairing operation does not exist".to_owned()))?;
        ensure_pairing_entity(&operation, pairing_id)?;
        if operation.state == OperationState::Completed {
            return Ok(FeatureResult::unchanged(operation));
        }
        operation.complete(now_ms);
        self.storage.put_operation(operation.clone())?;
        Ok(FeatureResult::changed(
            operation.clone(),
            operation_changes(operation.operation_id.as_str()),
        ))
    }

    pub fn retry_pairing(
        &mut self,
        operation_id: &str,
        pairing_id: &str,
        error_code: RuntimeErrorCode,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>> {
        let operation_id = OperationId::parse(operation_id.to_owned())?;
        let mut operation = self
            .storage
            .operation_by_id(&operation_id)?
            .ok_or_else(|| RuntimeError::NotFound("pairing operation does not exist".to_owned()))?;
        ensure_pairing_entity(&operation, pairing_id)?;
        if operation.state.is_terminal() {
            return Ok(FeatureResult::unchanged(operation));
        }
        let decision = self.retry_policy.decide(
            RetryClass::NetworkBackoff,
            now_ms,
            operation.attempt_count,
            retry_jitter_seed(pairing_id, operation.attempt_count),
        );
        if decision.terminal {
            operation.fail_permanently(error_code, now_ms);
        } else {
            operation.schedule_retry(
                decision.retry_at.unwrap_or(now_ms),
                error_code,
                now_ms,
            );
        }
        self.storage.put_operation(operation.clone())?;
        Ok(FeatureResult::changed(
            operation.clone(),
            operation_changes(operation.operation_id.as_str()),
        ))
    }
}

/// Narrow lifecycle boundary for restartable workflows.
///
/// It is intentionally separate from `ClientRuntimeFeatureFacade` so ordinary
/// domain features do not acquire an unnecessary `OperationStorage` bound.
pub trait ClientRuntimeOperationsFacade {
    fn feature_begin_pairing_operation(
        &mut self,
        operation_id: &str,
        pairing_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>>;

    fn feature_complete_pairing_operation(
        &mut self,
        operation_id: &str,
        pairing_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>>;

    fn feature_retry_pairing_operation(
        &mut self,
        operation_id: &str,
        pairing_id: &str,
        error_code: RuntimeErrorCode,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>>;
}

impl<S, T, C> ClientRuntimeOperationsFacade for ClientRuntime<S, T, C>
where
    S: RuntimeStorage + OperationStorage,
    T: RuntimeTransport,
    C: RuntimeClock,
{
    fn feature_begin_pairing_operation(
        &mut self,
        operation_id: &str,
        pairing_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>> {
        OperationsFeature::new(self.storage_mut()).begin_pairing(
            operation_id,
            pairing_id,
            now_ms,
        )
    }

    fn feature_complete_pairing_operation(
        &mut self,
        operation_id: &str,
        pairing_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>> {
        OperationsFeature::new(self.storage_mut()).complete_pairing(
            operation_id,
            pairing_id,
            now_ms,
        )
    }

    fn feature_retry_pairing_operation(
        &mut self,
        operation_id: &str,
        pairing_id: &str,
        error_code: RuntimeErrorCode,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>> {
        OperationsFeature::new(self.storage_mut()).retry_pairing(
            operation_id,
            pairing_id,
            error_code,
            now_ms,
        )
    }
}

fn ensure_pairing_entity(operation: &DurableOperation, pairing_id: &str) -> RuntimeResult<()> {
    if operation.operation_type == OperationType::Pairing && operation.entity_id == pairing_id {
        return Ok(());
    }
    Err(RuntimeError::Conflict(
        "operation does not belong to the requested pairing".to_owned(),
    ))
}

fn operation_changes(operation_id: &str) -> ChangeSet {
    let mut changes = ChangeSet::section(ChangeSections::OPERATIONS);
    changes
        .entities
        .operation_ids
        .insert(operation_id.to_owned());
    changes
}
