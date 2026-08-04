use super::*;

impl ClientDatabase {
    pub fn mark_delivery_receipt_dead_lettered(
        &self,
        error_code: &str,
        message_id: &str,
    ) -> EngineResult<()> {
        let changed = self
            .connection
            .execute(
                super::sql_catalog::receipts::MARK_DEAD_LETTERED,
                rusqlite::params![error_code, message_id],
            )
            .map_err(sqlite_error)?;
        super::affected_rows::exactly_one(changed, "mark delivery receipt dead-lettered")
    }

    pub fn received_envelope(
        &self,
        sender_installation_id: &str,
        message_id: &str,
    ) -> EngineResult<Option<ReceivedEnvelopeRecord>> {
        self.connection
            .query_row(
                super::sql_catalog::receipts::RECEIVED_ENVELOPE,
                params![sender_installation_id, message_id],
                |row| {
                    Ok(ReceivedEnvelopeRecord {
                        sender_installation_id: row.get("sender_installation_id")?,
                        message_id: row.get("message_id")?,
                        ciphertext_hash: row.get("ciphertext_hash")?,
                        received_at: row.get("received_at")?,
                        receipt_state: row.get("receipt_state")?,
                    })
                },
            )
            .optional()
            .map_err(sqlite_error)
    }

    pub fn put_received_envelope(&self, value: &ReceivedEnvelopeRecord) -> EngineResult<()> {
        self.connection
            .execute(
                super::sql_catalog::receipts::PUT_RECEIVED_ENVELOPE,
                params![
                    value.sender_installation_id,
                    value.message_id,
                    value.ciphertext_hash,
                    value.received_at,
                    value.receipt_state,
                ],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn delivery_receipt(
        &self,
        message_id: &str,
    ) -> EngineResult<Option<DeliveryReceiptRecord>> {
        self.connection
            .query_row(
                super::sql_catalog::receipts::DELIVERY_RECEIPT,
                [message_id],
                |row| {
                    Ok(DeliveryReceiptRecord {
                        envelope_id: row.get("envelope_id")?,
                        message_id: row.get("message_id")?,
                        conversation_id: row.get("conversation_id")?,
                        original_sender: row.get("original_sender")?,
                        received_at: row.get("received_at")?,
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

    pub fn put_delivery_receipt(&self, value: &DeliveryReceiptRecord) -> EngineResult<()> {
        self.connection
            .execute(
                super::sql_catalog::receipts::PUT_DELIVERY_RECEIPT,
                params![
                    value.envelope_id,
                    value.message_id,
                    value.conversation_id,
                    value.original_sender,
                    value.received_at,
                    value.wire_ciphertext,
                    value.state,
                    i64::from(value.attempt_count),
                    value.next_attempt_at,
                    value.last_error,
                    value.created_at,
                ],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn persist_receipt_encryption(
        &mut self,
        message_id: &str,
        wire_ciphertext: &[u8],
        conversation_id: &str,
        snapshot: &[u8],
        next_attempt_at: i64,
        last_error: Option<&str>,
    ) -> EngineResult<bool> {
        let now_ms = unix_ms();
        let transaction = self.connection.transaction().map_err(sqlite_error)?;
        let changed = transaction
            .execute(
                super::sql_catalog::receipts::PERSIST_RECEIPT_ENCRYPTION,
                params![
                    wire_ciphertext,
                    next_attempt_at,
                    last_error,
                    message_id,
                    now_ms
                ],
            )
            .map_err(sqlite_error)?;
        if changed == 0 {
            transaction.rollback().map_err(sqlite_error)?;
            return Ok(false);
        }
        transaction
            .execute(
                super::sql_catalog::receipts::PERSIST_RECEIPT_ENCRYPTION_RETRY,
                params![next_attempt_at, message_id],
            )
            .map_err(sqlite_error)?;
        transaction
            .execute(
                super::sql_catalog::receipts::PERSIST_RECEIPT_ENCRYPTION_CLAIM,
                params![
                    conversation_id,
                    snapshot,
                    sha2::Sha256::digest(snapshot).to_vec()
                ],
            )
            .map_err(sqlite_error)?;
        transaction
            .execute(
                super::sql_catalog::receipts::PERSIST_RECEIPT_ENCRYPTION_COMPLETE,
                [message_id],
            )
            .map_err(sqlite_error)?;
        transaction.commit().map_err(sqlite_error)?;
        Ok(true)
    }

    pub fn claim_receipt_attempt(
        &mut self,
        message_id: &str,
        next_attempt_at: i64,
        last_error: Option<&str>,
    ) -> EngineResult<bool> {
        let now_ms = unix_ms();
        let transaction = self.connection.transaction().map_err(sqlite_error)?;
        let changed = transaction
            .execute(
                super::sql_catalog::receipts::CLAIM_RECEIPT_ATTEMPT,
                params![next_attempt_at, last_error, message_id, now_ms],
            )
            .map_err(sqlite_error)?;
        if changed > 0 {
            transaction
                .execute(
                    super::sql_catalog::receipts::CLAIM_RECEIPT_ATTEMPT_RETRY,
                    params![next_attempt_at, message_id],
                )
                .map_err(sqlite_error)?;
            transaction
                .execute(
                    super::sql_catalog::receipts::CLAIM_RECEIPT_ATTEMPT_COMPLETE,
                    [message_id],
                )
                .map_err(sqlite_error)?;
        }
        transaction.commit().map_err(sqlite_error)?;
        Ok(changed > 0)
    }

    pub fn complete_delivery_receipt(&mut self, message_id: &str) -> EngineResult<()> {
        let transaction = self.connection.transaction().map_err(sqlite_error)?;
        transaction
            .execute(
                super::sql_catalog::receipts::COMPLETE_DELIVERY_RECEIPT,
                [message_id],
            )
            .map_err(sqlite_error)?;
        transaction
            .execute(
                super::sql_catalog::receipts::COMPLETE_DELIVERY_RECEIPT_FINAL,
                [message_id],
            )
            .map_err(sqlite_error)?;
        transaction.commit().map_err(sqlite_error)?;
        Ok(())
    }

    pub fn requeue_delivery_receipt(
        &mut self,
        message_id: &str,
        next_attempt_at: i64,
        last_error: &str,
    ) -> EngineResult<()> {
        let transaction = self.connection.transaction().map_err(sqlite_error)?;
        transaction
            .execute(
                super::sql_catalog::receipts::REQUEUE_DELIVERY_RECEIPT,
                params![next_attempt_at, last_error, message_id],
            )
            .map_err(sqlite_error)?;
        transaction
            .execute(
                super::sql_catalog::receipts::REQUEUE_DELIVERY_RECEIPT_FINAL,
                [message_id],
            )
            .map_err(sqlite_error)?;
        transaction.commit().map_err(sqlite_error)?;
        Ok(())
    }
}
