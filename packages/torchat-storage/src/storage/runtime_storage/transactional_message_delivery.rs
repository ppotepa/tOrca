use super::super::sqlite;
use super::SqliteRuntimeStorage;
use super::storage_error;
use torchat_runtime::{RuntimeError, RuntimeResult};

impl torchat_runtime::features::messaging::MessageDeliveryStorage for SqliteRuntimeStorage<'_> {
    fn enqueue_outbound_delivery(
        &mut self,
        message_id: &str,
        contact_installation_id: &str,
        sequence: u64,
        created_at_secs: i64,
    ) -> RuntimeResult<()> {
        self.tx()
            .execute(
                sqlite::sql_catalog::messages::ENQUEUE_OUTBOUND_DELIVERY,
                rusqlite::params![
                    message_id,
                    contact_installation_id,
                    sequence as i64,
                    created_at_secs,
                ],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    fn requeue_outbound_delivery(
        &mut self,
        message_id: &str,
        retry_at: i64,
        error: &str,
    ) -> RuntimeResult<()> {
        let changed = self
            .tx()
            .execute(
                sqlite::sql_catalog::messages::REQUEUE_OUTBOUND_DELIVERY,
                rusqlite::params![message_id, retry_at, error],
            )
            .map_err(storage_error)?;
        if changed != 1 {
            return Err(RuntimeError::Storage(format!(
                "outbound delivery {message_id} is missing while scheduling retry"
            )));
        }
        self.tx()
            .execute(
                sqlite::sql_catalog::messages::REQUEUE_OUTBOUND_DELIVERY_AFTER_DISCONNECT,
                [message_id],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    fn complete_outbound_delivery(&mut self, message_id: &str) -> RuntimeResult<()> {
        self.tx()
            .execute(
                sqlite::sql_catalog::messages::COMPLETE_OUTBOUND_DELIVERY,
                [message_id],
            )
            .map_err(storage_error)?;
        Ok(())
    }
}
