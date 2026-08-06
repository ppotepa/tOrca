use torchat_runtime::{DurableOperation, OperationId, OperationStorage, RuntimeResult};

use super::{ClientDatabase, operation_queries};

impl ClientDatabase {
    pub fn operation_by_id(
        &self,
        operation_id: &OperationId,
    ) -> RuntimeResult<Option<DurableOperation>> {
        operation_queries::operation_by_id(self.connection(), operation_id)
    }

    pub fn put_operation(&self, operation: &DurableOperation) -> RuntimeResult<()> {
        operation_queries::put_operation(self.connection(), operation)
    }

    pub fn pending_operations(&self) -> RuntimeResult<Vec<DurableOperation>> {
        operation_queries::pending_operations(self.connection())
    }
}

impl OperationStorage for ClientDatabase {
    fn operation_by_id(
        &self,
        operation_id: &OperationId,
    ) -> RuntimeResult<Option<DurableOperation>> {
        ClientDatabase::operation_by_id(self, operation_id)
    }

    fn put_operation(&mut self, operation: DurableOperation) -> RuntimeResult<()> {
        ClientDatabase::put_operation(self, &operation)
    }

    fn pending_operations(&self) -> RuntimeResult<Vec<DurableOperation>> {
        ClientDatabase::pending_operations(self)
    }
}
