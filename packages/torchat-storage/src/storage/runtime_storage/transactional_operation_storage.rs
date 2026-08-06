use super::super::operation_queries;
use super::SqliteRuntimeStorage;
use torchat_runtime::{DurableOperation, OperationId, OperationStorage, RuntimeResult};

impl OperationStorage for SqliteRuntimeStorage<'_> {
    fn operation_by_id(
        &self,
        operation_id: &OperationId,
    ) -> RuntimeResult<Option<DurableOperation>> {
        operation_queries::operation_by_id(self.tx(), operation_id)
    }

    fn put_operation(&mut self, operation: DurableOperation) -> RuntimeResult<()> {
        operation_queries::put_operation(self.tx(), &operation)
    }

    fn pending_operations(&self) -> RuntimeResult<Vec<DurableOperation>> {
        operation_queries::pending_operations(self.tx())
    }
}
