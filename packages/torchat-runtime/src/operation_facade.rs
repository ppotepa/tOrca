use crate::{
    ClientRuntime, DurableOperation, FeatureResult, OperationId, OperationStorage, OperationType,
    PointLookupStorage, RetryClass, RuntimeClock, RuntimeErrorCode, RuntimeResult, RuntimeTransport,
    features::operations::OperationsFeature,
};

pub trait ClientOperationFeatureFacade {
    fn feature_ensure_operation(
        &mut self,
        operation_id: &str,
        operation_type: OperationType,
        entity_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>>;
    fn feature_begin_operation(
        &mut self,
        operation_id: &str,
        operation_type: OperationType,
        entity_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>>;
    fn feature_complete_operation(
        &mut self,
        operation_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>>;
    fn feature_retry_operation(
        &mut self,
        operation_id: &str,
        retry_class: RetryClass,
        error_code: RuntimeErrorCode,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>>;
    fn feature_fail_operation(
        &mut self,
        operation_id: &str,
        error_code: RuntimeErrorCode,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>>;
    fn feature_pending_operations(&mut self) -> RuntimeResult<Vec<DurableOperation>>;
}

impl<S, T, C> ClientOperationFeatureFacade for ClientRuntime<S, T, C>
where
    S: OperationStorage + PointLookupStorage,
    T: RuntimeTransport,
    C: RuntimeClock,
{
    fn feature_ensure_operation(
        &mut self,
        operation_id: &str,
        operation_type: OperationType,
        entity_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>> {
        let operation_id = OperationId::parse(operation_id.to_owned())?;
        OperationsFeature::new(self.storage_mut()).ensure(
            operation_id,
            operation_type,
            entity_id,
            now_ms,
        )
    }

    fn feature_begin_operation(
        &mut self,
        operation_id: &str,
        operation_type: OperationType,
        entity_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>> {
        let operation_id = OperationId::parse(operation_id.to_owned())?;
        OperationsFeature::new(self.storage_mut()).begin(
            operation_id,
            operation_type,
            entity_id,
            now_ms,
        )
    }

    fn feature_complete_operation(
        &mut self,
        operation_id: &str,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>> {
        let operation_id = OperationId::parse(operation_id.to_owned())?;
        OperationsFeature::new(self.storage_mut()).complete(&operation_id, now_ms)
    }

    fn feature_retry_operation(
        &mut self,
        operation_id: &str,
        retry_class: RetryClass,
        error_code: RuntimeErrorCode,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>> {
        let operation_id = OperationId::parse(operation_id.to_owned())?;
        OperationsFeature::new(self.storage_mut()).schedule_retry(
            &operation_id,
            retry_class,
            error_code,
            now_ms,
        )
    }

    fn feature_fail_operation(
        &mut self,
        operation_id: &str,
        error_code: RuntimeErrorCode,
        now_ms: i64,
    ) -> RuntimeResult<FeatureResult<DurableOperation>> {
        let operation_id = OperationId::parse(operation_id.to_owned())?;
        OperationsFeature::new(self.storage_mut()).fail(&operation_id, error_code, now_ms)
    }

    fn feature_pending_operations(&mut self) -> RuntimeResult<Vec<DurableOperation>> {
        OperationsFeature::new(self.storage_mut()).pending()
    }
}
