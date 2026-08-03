use super::*;

impl ClientDatabase {
    pub fn next_read_receipt_retry_deadline(&self, _now_ms: i64) -> EngineResult<Option<i64>> {
        self.connection
            .query_row(super::sql_catalog::read_receipts::NEXT_RETRY, [], |row| {
                row.get(0)
            })
            .map_err(sqlite_error)
    }

    pub fn enqueue_read_receipt(
        &self,
        contact_installation_id: &str,
        conversation_id: &str,
        message_ids_json: &str,
        read_at: i64,
        now_ms: i64,
    ) -> EngineResult<String> {
        let message_ids_json = canonical_message_ids_json(message_ids_json)?;
        let receipt_id = uuid::Uuid::new_v4().to_string();
        self.connection
            .execute(
                super::sql_catalog::read_receipts::ENQUEUE,
                rusqlite::params![
                    receipt_id,
                    contact_installation_id,
                    conversation_id,
                    message_ids_json,
                    read_at,
                    now_ms,
                ],
            )
            .map_err(sqlite_error)?;
        let id: String = self
            .connection
            .query_row(
                super::sql_catalog::read_receipts::GET_ID,
                rusqlite::params![contact_installation_id, conversation_id, message_ids_json],
                |row| row.get(0),
            )
            .map_err(sqlite_error)?;
        Ok(id)
    }

    pub fn due_read_receipts(&self, now_ms: i64) -> EngineResult<Vec<ReadReceiptOutboxRecord>> {
        let mut statement = self
            .connection
            .prepare(super::sql_catalog::read_receipts::LIST_DUE)
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map([now_ms], |row| {
                Ok(ReadReceiptOutboxRecord {
                    receipt_id: row.get("receipt_id")?,
                    contact_installation_id: row.get("contact_installation_id")?,
                    conversation_id: row.get("conversation_id")?,
                    message_ids_json: row.get("message_ids_json")?,
                    read_at: row.get("read_at")?,
                    wire_ciphertext: row.get("wire_ciphertext")?,
                    state: row.get("state")?,
                    attempt_count: row.get::<_, i64>("attempt_count")? as u32,
                    next_attempt_at: row.get("next_attempt_at")?,
                    last_error: row.get("last_error")?,
                    created_at: row.get("created_at")?,
                })
            })
            .map_err(sqlite_error)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(sqlite_error)
    }

    pub fn read_receipt(&self, receipt_id: &str) -> EngineResult<Option<ReadReceiptOutboxRecord>> {
        self.connection
            .query_row(
                super::sql_catalog::read_receipts::GET,
                [receipt_id],
                |row| {
                    Ok(ReadReceiptOutboxRecord {
                        receipt_id: row.get("receipt_id")?,
                        contact_installation_id: row.get("contact_installation_id")?,
                        conversation_id: row.get("conversation_id")?,
                        message_ids_json: row.get("message_ids_json")?,
                        read_at: row.get("read_at")?,
                        wire_ciphertext: row.get("wire_ciphertext")?,
                        state: row.get("state")?,
                        attempt_count: row.get::<_, i64>("attempt_count")? as u32,
                        next_attempt_at: row.get("next_attempt_at")?,
                        last_error: row.get("last_error")?,
                        created_at: row.get("created_at")?,
                    })
                },
            )
            .optional()
            .map_err(sqlite_error)
    }

    pub fn persist_read_receipt_encryption(
        &self,
        receipt_id: &str,
        wire_ciphertext: &[u8],
        conversation_id: &str,
        snapshot: &[u8],
        next_attempt_at: i64,
    ) -> EngineResult<bool> {
        let changed = self
            .connection
            .execute(
                super::sql_catalog::read_receipts::PERSIST_ENCRYPTION,
                rusqlite::params![wire_ciphertext, next_attempt_at, unix_ms(), receipt_id],
            )
            .map_err(sqlite_error)?;
        if changed == 0 {
            return Ok(false);
        }
        self.connection
            .execute(
                super::sql_catalog::mls::UPSERT_SNAPSHOT,
                rusqlite::params![
                    conversation_id,
                    snapshot,
                    sha2::Sha256::digest(snapshot).to_vec()
                ],
            )
            .map_err(sqlite_error)?;
        Ok(true)
    }

    pub fn complete_read_receipt(&self, receipt_id: &str) -> EngineResult<()> {
        self.connection
            .execute(super::sql_catalog::read_receipts::COMPLETE, [receipt_id])
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn requeue_read_receipt(
        &self,
        receipt_id: &str,
        next_attempt_at: i64,
        error: &str,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                super::sql_catalog::read_receipts::REQUEUE,
                rusqlite::params![receipt_id, next_attempt_at, error],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }
}

fn canonical_message_ids_json(message_ids_json: &str) -> EngineResult<String> {
    let mut ids: Vec<uuid::Uuid> = serde_json::from_str(message_ids_json).map_err(|error| {
        EngineError::InvalidCommand(format!("invalid read receipt IDs: {error}"))
    })?;
    ids.sort_unstable();
    ids.dedup();
    serde_json::to_string(&ids)
        .map_err(|error| EngineError::InvalidCommand(format!("encode read receipt IDs: {error}")))
}
