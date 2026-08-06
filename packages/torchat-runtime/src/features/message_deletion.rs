use crate::{
    ChangeSections, ChangeSet, ClientRuntime, ContactStorage, ConversationStorage, FeatureResult,
    MessageStorage, OperationState, OperationStorage, PointLookupStorage, RuntimeClock,
    RuntimeEvent, RuntimeResult, RuntimeStorage, RuntimeTransport,
    features::{
        messaging::{MessageDeliveryStorage, MessagingFeature},
        operations::OperationsFeature,
    },
};

pub trait ClientRuntimeMessageDeletionFacade {
    fn feature_delete_message_delivery(
        &mut self,
        message_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<()>>;
}

impl<S, T, C> ClientRuntimeMessageDeletionFacade for ClientRuntime<S, T, C>
where
    S: RuntimeStorage
        + MessageStorage
        + ConversationStorage
        + ContactStorage
        + PointLookupStorage
        + OperationStorage
        + MessageDeliveryStorage,
    T: RuntimeTransport,
    C: RuntimeClock,
{
    fn feature_delete_message_delivery(
        &mut self,
        message_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<()>> {
        let deleted = MessagingFeature::new(self.storage_mut()).delete_with_context(message_id)?;
        let mut changes = deleted.changes;
        if let Some(mut operation) =
            OperationsFeature::new(self.storage_mut()).active_message_delivery(message_id)?
        {
            operation.state = OperationState::Cancelled;
            operation.updated_at = now_ms;
            operation.retry_at = None;
            operation.error_code = None;
            let operation_id = operation.operation_id.as_str().to_owned();
            OperationStorage::put_operation(self.storage_mut(), operation)?;
            let mut operation_changes = ChangeSet::section(ChangeSections::OPERATIONS);
            operation_changes
                .entities
                .operation_ids
                .insert(operation_id);
            changes.merge(operation_changes);
        }
        self.storage_mut().complete_outbound_delivery(message_id)?;
        self.session_mut()
            .push_event(RuntimeEvent::MessageStateChanged {
                message_id: Some(deleted.value.message_id),
                conversation_id: Some(deleted.value.conversation_id),
                state: None,
            });
        Ok(FeatureResult {
            value: (),
            changes,
            effects: deleted.effects,
        })
    }
}
