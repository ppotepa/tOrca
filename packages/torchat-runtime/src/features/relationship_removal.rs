use crate::{
    ChangeSections, ChangeSet, DurableOperation, FeatureResult, OperationId, OperationState,
    OperationStorage, OperationType, RelationshipStorage, RelationshipTransition, RuntimeError,
    RuntimeResult,
};

pub struct RelationshipRemovalFeature<'a, S> {
    storage: &'a mut S,
}

impl<'a, S> RelationshipRemovalFeature<'a, S>
where
    S: RelationshipStorage + OperationStorage,
{
    pub fn new(storage: &'a mut S) -> Self {
        Self { storage }
    }

    #[allow(clippy::too_many_arguments)]
    pub fn request(
        &mut self,
        operation_id: &str,
        command_descriptor: &str,
        installation_id: &str,
        preserve_history: bool,
        removal_id: &str,
        removed_at: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>> {
        if installation_id.trim().is_empty() {
            return Err(RuntimeError::InvalidParams(
                "installation id must not be empty".to_owned(),
            ));
        }
        if removal_id.trim().is_empty() {
            return Err(RuntimeError::InvalidParams(
                "removal id must not be empty".to_owned(),
            ));
        }
        if command_descriptor.trim().is_empty() {
            return Err(RuntimeError::InvalidParams(
                "relationship removal descriptor must not be empty".to_owned(),
            ));
        }

        let operation_id = OperationId::parse(operation_id.to_owned())?;
        let mut operation = self
            .storage
            .operation_by_id(&operation_id)?
            .unwrap_or_else(|| {
                DurableOperation::pending(
                    operation_id.clone(),
                    OperationType::RelationshipRemoval,
                    installation_id,
                    removed_at,
                )
                .with_command_descriptor(command_descriptor)
            });

        self.validate_existing_operation(
            &operation,
            installation_id,
            command_descriptor,
        )?;

        if operation.state == OperationState::Completed {
            return Ok(FeatureResult::unchanged(operation));
        }
        if matches!(
            operation.state,
            OperationState::Cancelled | OperationState::FailedPermanent
        ) {
            return Err(RuntimeError::Conflict(
                "relationship removal operation is already terminal".to_owned(),
            ));
        }

        operation.operation_type = OperationType::RelationshipRemoval;
        operation.command_descriptor = Some(command_descriptor.to_owned());
        operation.begin_attempt(removed_at);
        self.storage.put_operation(operation.clone())?;

        let relationship_epoch = self
            .storage
            .current_relationship_epoch(installation_id)?
            .saturating_add(1);
        self.storage
            .apply_relationship_transition(RelationshipTransition::Remove {
                installation_id: installation_id.to_owned(),
                removed_at,
                preserve_history,
                removal_id: removal_id.to_owned(),
                relationship_epoch,
            })?;

        operation.complete(removed_at);
        self.storage.put_operation(operation.clone())?;

        let mut changes = ChangeSet::section(
            ChangeSections::OPERATIONS
                .union(ChangeSections::RELATIONSHIPS)
                .union(ChangeSections::CONTACTS)
                .union(ChangeSections::CONVERSATIONS)
                .union(ChangeSections::MESSAGES),
        );
        changes
            .entities
            .operation_ids
            .insert(operation.operation_id.as_str().to_owned());
        changes
            .entities
            .contact_ids
            .insert(installation_id.to_owned());

        Ok(FeatureResult::changed(operation, changes))
    }

    fn validate_existing_operation(
        &self,
        operation: &DurableOperation,
        installation_id: &str,
        command_descriptor: &str,
    ) -> RuntimeResult<()> {
        if operation.operation_type != OperationType::RelationshipRemoval
            || operation.entity_id != installation_id
        {
            return Err(RuntimeError::Conflict(
                "operation id is already bound to another entity".to_owned(),
            ));
        }
        if let Some(existing_descriptor) = operation.command_descriptor.as_deref()
            && existing_descriptor != command_descriptor
        {
            return Err(RuntimeError::Conflict(
                "operation id is already bound to a different command payload".to_owned(),
            ));
        }
        Ok(())
    }
}
