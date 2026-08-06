use crate::{
    ChangeSet, DurableOperation, FeatureResult, OperationId, OperationState, OperationStorage,
    OperationType, RetryClass, RetryPolicy, RuntimeError, RuntimeErrorCode, RuntimeResult,
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

    pub fn with_retry_policy(storage: &'a mut S, retry_policy: RetryPolicy) -> Self {
        Self {
            storage,
            retry_policy,
        }
    }

    pub fn begin(
        &mut self,
        operation_id: OperationId,
        operation_type: OperationType,
        entity_id: impl Into<String>,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>> {
        let entity_id = entity_id.into();
        let mut operation = match self.storage.operation_by_id(&operation_id)? {
            Some(existing) => {
                if existing.operation_type != operation_type || existing.entity_id != entity_id {
                    return Err(RuntimeError::Conflict(
                        "operation id is already assigned to another workflow".to_owned(),
                    ));
                }
                if existing.state.is_terminal() {
                    return Ok(FeatureResult::unchanged(existing));
                }
                existing
            }
            None => DurableOperation::pending(
                operation_id,
                operation_type,
                entity_id,
                now_ms,
            ),
        };
        operation.begin_attempt(now_ms);
        self.storage.put_operation(operation.clone())?;
        Ok(changed(operation))
    }

    pub fn complete(
        &mut self,
        operation_id: &OperationId,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>> {
        let mut operation = self.require(operation_id)?;
        if operation.state == OperationState::Completed {
            return Ok(FeatureResult::unchanged(operation));
        }
        if operation.state.is_terminal() {
            return Err(RuntimeError::Conflict(
                "terminal operation cannot be completed".to_owned(),
            ));
        }
        operation.complete(now_ms);
        self.storage.put_operation(operation.clone())?;
        Ok(changed(operation))
    }

    pub fn schedule_retry(
        &mut self,
        operation_id: &OperationId,
        class: RetryClass,
        error_code: RuntimeErrorCode,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>> {
        let mut operation = self.require(operation_id)?;
        if operation.state.is_terminal() {
            return Ok(FeatureResult::unchanged(operation));
        }
        let decision = self.retry_policy.decide(
            class,
            now_ms,
            operation.attempt_count,
            retry_jitter_seed(operation.operation_id.as_str(), operation.attempt_count),
        );
        if decision.terminal {
            operation.fail_permanently(error_code, now_ms);
        } else if let Some(retry_at) = decision.retry_at {
            operation.schedule_retry(retry_at, error_code, now_ms);
        } else {
            operation.state = OperationState::WaitingForRetry;
            operation.updated_at = now_ms;
            operation.retry_at = None;
            operation.error_code = Some(error_code);
        }
        self.storage.put_operation(operation.clone())?;
        Ok(changed(operation))
    }

    pub fn fail(
        &mut self,
        operation_id: &OperationId,
        error_code: RuntimeErrorCode,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>> {
        let mut operation = self.require(operation_id)?;
        if operation.state.is_terminal() {
            return Ok(FeatureResult::unchanged(operation));
        }
        operation.fail_permanently(error_code, now_ms);
        self.storage.put_operation(operation.clone())?;
        Ok(changed(operation))
    }

    pub fn pending(&self) -> RuntimeResult<Vec<DurableOperation>> {
        self.storage.pending_operations()
    }

    fn require(&self, operation_id: &OperationId) -> RuntimeResult<DurableOperation> {
        self.storage
            .operation_by_id(operation_id)?
            .ok_or_else(|| RuntimeError::NotFound("operation does not exist".to_owned()))
    }
}

fn changed(operation: DurableOperation) -> FeatureResult<DurableOperation> {
    FeatureResult::changed(
        operation.clone(),
        ChangeSet::default().with_operation(operation.operation_id.to_string()),
    )
}
