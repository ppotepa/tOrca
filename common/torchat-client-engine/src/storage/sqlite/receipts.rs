use super::*;

impl ClientDatabase {
    pub fn received_envelope(
        &self,
        sender_installation_id: &str,
        message_id: &str,
    ) -> EngineResult<Option<ReceivedEnvelopeRecord>> {
        self.connection
            .query_row(
                "SELECT sender_installation_id, message_id, ciphertext_hash, received_at, receipt_state
                 FROM received_envelopes
                 WHERE sender_installation_id = ?1 AND message_id = ?2;",
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
                "INSERT OR REPLACE INTO received_envelopes (
                    sender_installation_id, message_id, ciphertext_hash, received_at, receipt_state
                 ) VALUES (?1, ?2, ?3, ?4, ?5);",
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
                "SELECT envelope_id, message_id, conversation_id, original_sender, received_at,
                        relay_payload, state, attempt_count, next_attempt_at, last_error, created_at
                 FROM delivery_receipts
                 WHERE message_id = ?1;",
                [message_id],
                |row| {
                    Ok(DeliveryReceiptRecord {
                        envelope_id: row.get("envelope_id")?,
                        message_id: row.get("message_id")?,
                        conversation_id: row.get("conversation_id")?,
                        original_sender: row.get("original_sender")?,
                        received_at: row.get("received_at")?,
                        relay_payload: row.get("relay_payload")?,
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
                "INSERT OR REPLACE INTO delivery_receipts (
                    envelope_id, message_id, conversation_id, original_sender, received_at,
                    relay_payload, state, attempt_count, next_attempt_at, last_error, created_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11);",
                params![
                    value.envelope_id,
                    value.message_id,
                    value.conversation_id,
                    value.original_sender,
                    value.received_at,
                    value.relay_payload,
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
        relay_payload: &[u8],
        conversation_id: &str,
        snapshot: &[u8],
        next_attempt_at: i64,
        last_error: Option<&str>,
    ) -> EngineResult<bool> {
        let now_ms = unix_ms();
        let transaction = self.connection.transaction().map_err(sqlite_error)?;
        let changed = transaction
            .execute(
                "UPDATE delivery_receipts
                 SET relay_payload = COALESCE(relay_payload, ?1),
                     state = 'SENT',
                     attempt_count = attempt_count + 1,
                     next_attempt_at = ?2,
                     last_error = ?3
                 WHERE message_id = ?4
                   AND UPPER(state) IN ('PENDING', 'SENT')
                   AND next_attempt_at <= ?5;",
                params![
                    relay_payload,
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
                "UPDATE delivery_receipts SET claimed_until = ?1, last_error_code = NULL WHERE message_id = ?2;",
                params![next_attempt_at, message_id],
            )
            .map_err(sqlite_error)?;
        transaction
            .execute(
                "INSERT INTO conversation_mls (conversation_id, snapshot, state_version, snapshot_hash, updated_at)
                 VALUES (?1, ?2, 1, ?3, unixepoch())
                 ON CONFLICT(conversation_id) DO UPDATE SET
                    snapshot = excluded.snapshot,
                    state_version = conversation_mls.state_version + 1,
                    snapshot_hash = excluded.snapshot_hash,
                    updated_at = unixepoch();",
                params![conversation_id, snapshot, sha2::Sha256::digest(snapshot).to_vec()],
            )
            .map_err(sqlite_error)?;
        transaction
            .execute(
                "UPDATE received_envelopes
                 SET receipt_state = 'SENT'
                 WHERE message_id = ?1;",
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
                "UPDATE delivery_receipts
                 SET state = 'SENT',
                     attempt_count = attempt_count + 1,
                     next_attempt_at = ?1,
                     last_error = ?2
                 WHERE message_id = ?3
                   AND UPPER(state) IN ('PENDING', 'SENT')
                   AND next_attempt_at <= ?4;",
                params![next_attempt_at, last_error, message_id, now_ms],
            )
            .map_err(sqlite_error)?;
        if changed > 0 {
            transaction
                .execute(
                    "UPDATE delivery_receipts SET claimed_until = ?1, last_error_code = NULL WHERE message_id = ?2;",
                    params![next_attempt_at, message_id],
                )
                .map_err(sqlite_error)?;
            transaction
                .execute(
                    "UPDATE received_envelopes
                     SET receipt_state = 'SENT'
                     WHERE message_id = ?1;",
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
                "UPDATE delivery_receipts
                 SET state = 'DELIVERED', next_attempt_at = 0, last_error = NULL
                 WHERE message_id = ?1;",
                [message_id],
            )
            .map_err(sqlite_error)?;
        transaction
            .execute(
                "UPDATE received_envelopes
                 SET receipt_state = 'DELIVERED'
                 WHERE message_id = ?1;",
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
                "UPDATE delivery_receipts
                 SET state = 'PENDING', next_attempt_at = ?1, last_error = ?2
                 WHERE message_id = ?3;",
                params![next_attempt_at, last_error, message_id],
            )
            .map_err(sqlite_error)?;
        transaction
            .execute(
                "UPDATE received_envelopes
                 SET receipt_state = 'PENDING'
                 WHERE message_id = ?1;",
                [message_id],
            )
            .map_err(sqlite_error)?;
        transaction.commit().map_err(sqlite_error)?;
        Ok(())
    }
}
