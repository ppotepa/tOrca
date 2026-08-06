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
        command_descriptor: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>> {
        if command_descriptor.trim().is_empty() {
            return Err(RuntimeError::InvalidParams(
                "durable pairing command descriptor must not be empty".to_owned(),
            ));
        }
        let operation_id = OperationId::parse(operation_id.to_owned())?;
        let mut operation = self
            .storage
            .operation_by_id(&operation_id)?
            .unwrap_or_else(|| {
                DurableOperation::pending(
                    operation_id.clone(),
                    OperationType::PairingCancellation,
                    pairing_id,
                    now_ms,
                )
                .with_command_descriptor(command_descriptor)
            });
        ensure_pairing_entity(&operation, pairing_id)?;
        if let Some(existing_descriptor) = operation.command_descriptor.as_deref() {
            if existing_descriptor != command_descriptor {
                return Err(RuntimeError::Conflict(
                    "operation id is already bound to a different command payload".to_owned(),
                ));
            }
        } else {
            operation.command_descriptor = Some(command_descriptor.to_owned());
        }
        operation.operation_type = OperationType::PairingCancellation;
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
        self.persist_changed(operation)
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
        self.persist_changed(operation)
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
        self.persist_changed(operation)
    }

    pub fn fail_pairing(
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
        operation.fail_permanently(error_code, now_ms);
        self.persist_changed(operation)
    }

    pub fn begin_message_delivery(
        &mut self,
        requested_operation_id: &str,
        message_id: &str,
        command_descriptor: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>> {
        if command_descriptor.trim().is_empty() {
            return Err(RuntimeError::InvalidParams(
                "durable message command descriptor must not be empty".to_owned(),
            ));
        }
        let requested_id = OperationId::parse(requested_operation_id.to_owned())?;
        let requested = self.storage.operation_by_id(&requested_id)?;
        let active = self.active_message_delivery(message_id)?;
        let bound_to_requested_id = requested.is_some();
        let mut operation = match requested.or(active) {
            Some(operation) => operation,
            None => DurableOperation::pending(
                requested_id,
                OperationType::MessageDelivery,
                message_id,
                now_ms,
            )
            .with_command_descriptor(command_descriptor),
        };
        ensure_message_entity(&operation, message_id)?;
        if bound_to_requested_id {
            if let Some(existing_descriptor) = operation.command_descriptor.as_deref() {
                if existing_descriptor != command_descriptor {
                    return Err(RuntimeError::Conflict(
                        "operation id is already bound to a different command payload".to_owned(),
                    ));
                }
            } else {
                operation.command_descriptor = Some(command_descriptor.to_owned());
            }
        } else if operation.command_descriptor.is_none() {
            operation.command_descriptor = Some(command_descriptor.to_owned());
        }
        if operation.state == OperationState::Completed {
            return Ok(FeatureResult::unchanged(operation));
        }
        if matches!(
            operation.state,
            OperationState::Cancelled | OperationState::FailedPermanent
        ) {
            return Err(RuntimeError::Conflict(
                "message delivery operation is already terminal".to_owned(),
            ));
        }
        operation.operation_type = OperationType::MessageDelivery;
        operation.begin_attempt(now_ms);
        self.persist_changed(operation)
    }

    pub fn complete_message_delivery(
        &mut self,
        message_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<Option<DurableOperation>>> {
        let Some(mut operation) = self.active_message_delivery(message_id)? else {
            return Ok(FeatureResult::unchanged(None));
        };
        operation.complete(now_ms);
        let changed = self.persist_changed(operation)?;
        Ok(FeatureResult {
            value: Some(changed.value),
            changes: changed.changes,
            effects: changed.effects,
        })
    }

    pub fn retry_message_delivery(
        &mut self,
        message_id: &str,
        retry_at: i64,
        error_code: RuntimeErrorCode,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<Option<DurableOperation>>> {
        let Some(mut operation) = self.active_message_delivery(message_id)? else {
            return Ok(FeatureResult::unchanged(None));
        };
        operation.schedule_retry(retry_at, error_code, now_ms);
        let changed = self.persist_changed(operation)?;
        Ok(FeatureResult {
            value: Some(changed.value),
            changes: changed.changes,
            effects: changed.effects,
        })
    }

    pub fn fail_message_delivery(
        &mut self,
        message_id: &str,
        error_code: RuntimeErrorCode,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<Option<DurableOperation>>> {
        let Some(mut operation) = self.active_message_delivery(message_id)? else {
            return Ok(FeatureResult::unchanged(None));
        };
        operation.fail_permanently(error_code, now_ms);
        let changed = self.persist_changed(operation)?;
        Ok(FeatureResult {
            value: Some(changed.value),
            changes: changed.changes,
            effects: changed.effects,
        })
    }

    pub fn active_message_delivery(
        &self,
        message_id: &str,
    ) -> RuntimeResult<Option<DurableOperation>> {
        Ok(self
            .storage
            .pending_operations()?
            .into_iter()
            .find(|operation| {
                operation.operation_type == OperationType::MessageDelivery
                    && operation.entity_id == message_id
                    && !operation.state.is_terminal()
            }))
    }

    fn persist_changed(
        &mut self,
        operation: DurableOperation,
    ) -> RuntimeResult<FeatureResult<DurableOperation>> {
        self.storage.put_operation(operation.clone())?;
        Ok(FeatureResult::changed(
            operation.clone(),
            operation_changes(operation.operation_id.as_str()),
        ))
    }
}

/// Narrow lifecycle boundary for restartable pairing workflows.
pub trait ClientRuntimeOperationsFacade {
    fn feature_begin_pairing_operation(
        &mut self,
        operation_id: &str,
        pairing_id: &str,
        command_descriptor: &str,
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

    fn feature_fail_pairing_operation(
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
        command_descriptor: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>> {
        OperationsFeature::new(self.storage_mut()).begin_pairing(
            operation_id,
            pairing_id,
            command_descriptor,
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

    fn feature_fail_pairing_operation(
        &mut self,
        operation_id: &str,
        pairing_id: &str,
        error_code: RuntimeErrorCode,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>> {
        OperationsFeature::new(self.storage_mut()).fail_pairing(
            operation_id,
            pairing_id,
            error_code,
            now_ms,
        )
    }
}

fn ensure_pairing_entity(operation: &DurableOperation, pairing_id: &str) -> RuntimeResult<()> {
    let is_pairing = matches!(
        operation.operation_type,
        OperationType::Pairing | OperationType::PairingCancellation
    );
    if is_pairing && operation.entity_id == pairing_id {
        return Ok(());
    }
    Err(RuntimeError::Conflict(
        "operation does not belong to the requested pairing".to_owned(),
    ))
}

fn ensure_message_entity(operation: &DurableOperation, message_id: &str) -> RuntimeResult<()> {
    if operation.operation_type == OperationType::MessageDelivery
        && operation.entity_id == message_id
    {
        return Ok(());
    }
    Err(RuntimeError::Conflict(
        "operation does not belong to the requested message".to_owned(),
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
