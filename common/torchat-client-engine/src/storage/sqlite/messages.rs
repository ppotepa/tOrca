use super::*;

impl ClientDatabase {
    pub fn enqueue_outbound_delivery(
        &self,
        message_id: &str,
        contact_installation_id: &str,
        sequence: u64,
        created_at: i64,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "INSERT INTO outbound_deliveries (
                    message_id, contact_installation_id, sequence, state,
                    attempt_count, next_attempt_at, created_at, updated_at
                 ) VALUES (?1, ?2, ?3, 'QUEUED', 0, 0, ?4, unixepoch())
                 ON CONFLICT(message_id) DO NOTHING;",
                params![
                    message_id,
                    contact_installation_id,
                    sequence as i64,
                    created_at,
                ],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn due_outbound_deliveries(
        &self,
        now_ms: i64,
        limit: usize,
    ) -> EngineResult<Vec<OutboundDeliveryRecord>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT message_id, contact_installation_id, sequence, state,
                        attempt_count, next_attempt_at, ack_deadline, last_error, created_at
                 FROM outbound_deliveries
                 WHERE UPPER(state) IN ('QUEUED', 'IN_FLIGHT')
                   AND next_attempt_at <= ?1
                 ORDER BY created_at ASC, message_id ASC
                 LIMIT ?2;",
            )
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map(params![now_ms, limit as i64], |row| {
                Ok(OutboundDeliveryRecord {
                    message_id: row.get("message_id")?,
                    contact_installation_id: row.get("contact_installation_id")?,
                    sequence: row.get::<_, i64>("sequence")? as u64,
                    state: row.get("state")?,
                    attempt_count: row.get::<_, i64>("attempt_count")? as u32,
                    next_attempt_at: row.get("next_attempt_at")?,
                    ack_deadline: row.get("ack_deadline")?,
                    last_error: row.get("last_error")?,
                    created_at: row.get("created_at")?,
                })
            })
            .map_err(sqlite_error)?;
        rows.collect::<rusqlite::Result<Vec<_>>>()
            .map_err(sqlite_error)
    }

    pub fn outbound_delivery(
        &self,
        message_id: &str,
    ) -> EngineResult<Option<OutboundDeliveryRecord>> {
        self.connection
            .query_row(
                "SELECT message_id, contact_installation_id, sequence, state,
                        attempt_count, next_attempt_at, ack_deadline, last_error, created_at
                 FROM outbound_deliveries
                 WHERE message_id = ?1;",
                [message_id],
                |row| {
                    Ok(OutboundDeliveryRecord {
                        message_id: row.get("message_id")?,
                        contact_installation_id: row.get("contact_installation_id")?,
                        sequence: row.get::<_, i64>("sequence")? as u64,
                        state: row.get("state")?,
                        attempt_count: row.get::<_, i64>("attempt_count")? as u32,
                        next_attempt_at: row.get("next_attempt_at")?,
                        ack_deadline: row.get("ack_deadline")?,
                        last_error: row.get("last_error")?,
                        created_at: row.get("created_at")?,
                    })
                },
            )
            .optional()
            .map_err(sqlite_error)
    }

    pub fn next_contact_peer_retry_deadline_ms(
        &self,
        installation_id: &str,
    ) -> EngineResult<Option<i64>> {
        self.connection
            .query_row(
                "SELECT MIN(next_attempt_at)
                 FROM outbound_deliveries
                 WHERE contact_installation_id = ?1
                   AND UPPER(state) = 'QUEUED';",
                [installation_id],
                |row| row.get(0),
            )
            .optional()
            .map(|value| value.flatten())
            .map_err(sqlite_error)
    }

    pub fn next_contact_receipt_retry_deadline_ms(
        &self,
        installation_id: &str,
    ) -> EngineResult<Option<i64>> {
        self.connection
            .query_row(
                "SELECT MIN(next_attempt_at)
                 FROM delivery_receipts
                 WHERE original_sender = ?1
                   AND UPPER(state) = 'PENDING';",
                [installation_id],
                |row| row.get(0),
            )
            .optional()
            .map(|value| value.flatten())
            .map_err(sqlite_error)
    }

    pub fn claim_outbound_delivery(
        &self,
        message_id: &str,
        next_attempt_at: i64,
        ack_deadline: i64,
    ) -> EngineResult<bool> {
        self.connection
            .execute(
                "UPDATE outbound_deliveries
                 SET state = 'IN_FLIGHT',
                     attempt_count = attempt_count + 1,
                     next_attempt_at = ?2,
                     ack_deadline = ?3,
                     last_error = NULL,
                     updated_at = unixepoch()
                 WHERE message_id = ?1
                   AND (
                       UPPER(state) = 'QUEUED'
                       OR (
                           UPPER(state) = 'IN_FLIGHT'
                           AND COALESCE(ack_deadline, 0) <= ?4
                       )
                   );",
                params![message_id, next_attempt_at, ack_deadline, unix_ms()],
            )
            .map(|changed| changed > 0)
            .map_err(sqlite_error)
    }

    pub fn requeue_outbound_delivery(
        &self,
        message_id: &str,
        next_attempt_at: i64,
        error: &str,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "UPDATE outbound_deliveries
                 SET state = 'QUEUED', next_attempt_at = ?2, ack_deadline = NULL,
                     last_error = ?3, updated_at = unixepoch()
                 WHERE message_id = ?1;",
                params![message_id, next_attempt_at, error],
            )
            .map_err(sqlite_error)?;
        self.connection
            .execute(
                "UPDATE outbound_deliveries SET claimed_until = NULL, last_error_code = NULL WHERE message_id = ?1;",
                [message_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn complete_outbound_delivery(&self, message_id: &str) -> EngineResult<()> {
        self.connection
            .execute(
                "DELETE FROM outbound_deliveries WHERE message_id = ?1;",
                [message_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn expedite_peer_deliveries(&self, installation_id: &str) -> EngineResult<()> {
        self.connection
            .execute(
                "UPDATE outbound_deliveries
                 SET state = 'QUEUED', next_attempt_at = 0, ack_deadline = NULL,
                     updated_at = unixepoch()
                 WHERE contact_installation_id = ?1;",
                [installation_id],
            )
            .map_err(sqlite_error)?;
        self.connection
            .execute(
                "UPDATE messages
                 SET state = CASE
                         WHEN UPPER(state) = 'SENDING' THEN 'QUEUED'
                         ELSE state
                     END,
                     next_attempt_at = 0,
                     ack_deadline = NULL
                 WHERE conversation_id = ?1
                   AND outgoing = 1
                   AND UPPER(state) IN ('QUEUED', 'SENDING');",
                [installation_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn requeue_peer_deliveries(&self, now_ms: i64) -> EngineResult<()> {
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(sqlite_error)?;
        transaction
            .execute(
                "UPDATE outbound_deliveries
                 SET state = 'QUEUED', next_attempt_at = ?1, ack_deadline = NULL,
                     claimed_until = NULL,
                     updated_at = unixepoch()
                 WHERE UPPER(state) = 'IN_FLIGHT';",
                [now_ms],
            )
            .map_err(sqlite_error)?;
        transaction
            .execute(
                "UPDATE messages
                 SET state = 'QUEUED',
                     next_attempt_at = ?1,
                     ack_deadline = NULL,
                     claimed_until = NULL
                 WHERE outgoing = 1
                   AND UPPER(state) = 'SENDING'
                   AND id IN (
                        SELECT message_id
                        FROM outbound_deliveries
                        WHERE UPPER(state) = 'QUEUED'
                   );",
                [now_ms],
            )
            .map_err(sqlite_error)?;
        transaction.commit().map_err(sqlite_error)?;
        Ok(())
    }

    pub fn store_inbound_peer_envelope(
        &self,
        envelope: &PeerMessageEnvelope,
        received_at: i64,
    ) -> EngineResult<InboundEnvelopeStoreResult> {
        let hash = envelope.ciphertext_hash().to_vec();
        if let Some((existing_hash, state)) = self
            .connection
            .query_row(
                "SELECT ciphertext_hash, state
                 FROM inbound_peer_envelopes
                 WHERE sender_installation_id = ?1 AND message_id = ?2;",
                params![
                    envelope.sender_installation_id,
                    envelope.message_id.to_string(),
                ],
                |row| {
                    Ok((
                        row.get::<_, Vec<u8>>("ciphertext_hash")?,
                        row.get::<_, String>("state")?,
                    ))
                },
            )
            .optional()
            .map_err(sqlite_error)?
        {
            if existing_hash != hash {
                return Err(EngineError::InvalidCommand(
                    "duplicate peer envelope has different ciphertext".to_owned(),
                ));
            }
            return Ok(InboundEnvelopeStoreResult::Duplicate {
                delivered: state.eq_ignore_ascii_case("DELIVERED"),
            });
        }
        self.connection
            .execute(
                "INSERT INTO inbound_peer_envelopes (
                    sender_installation_id, message_id, conversation_id, sequence,
                    ciphertext, ciphertext_hash, state, received_at, updated_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'PERSISTED', ?7, unixepoch());",
                params![
                    envelope.sender_installation_id,
                    envelope.message_id.to_string(),
                    envelope.conversation_id,
                    envelope.sequence as i64,
                    envelope.ciphertext,
                    hash,
                    received_at,
                ],
            )
            .map_err(sqlite_error)?;
        Ok(InboundEnvelopeStoreResult::Stored)
    }

    pub fn pending_inbound_peer_envelopes(&self) -> EngineResult<Vec<InboundPeerEnvelopeRecord>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT sender_installation_id, message_id, conversation_id, sequence,
                        ciphertext, ciphertext_hash, state, received_at
                 FROM inbound_peer_envelopes
                 WHERE UPPER(state) = 'PERSISTED'
                 ORDER BY received_at ASC, message_id ASC;",
            )
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map([], |row| {
                Ok(InboundPeerEnvelopeRecord {
                    sender_installation_id: row.get("sender_installation_id")?,
                    message_id: row.get("message_id")?,
                    conversation_id: row.get("conversation_id")?,
                    sequence: row.get::<_, i64>("sequence")? as u64,
                    ciphertext: row.get("ciphertext")?,
                    ciphertext_hash: row.get("ciphertext_hash")?,
                    state: row.get("state")?,
                    received_at: row.get("received_at")?,
                })
            })
            .map_err(sqlite_error)?;
        rows.collect::<rusqlite::Result<Vec<_>>>()
            .map_err(sqlite_error)
    }

    pub fn rejected_inbound_peer_senders(&self) -> EngineResult<HashSet<String>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT DISTINCT sender_installation_id
                 FROM inbound_peer_envelopes
                 WHERE UPPER(state) = 'REJECTED';",
            )
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(sqlite_error)?;
        rows.collect::<rusqlite::Result<HashSet<_>>>()
            .map_err(sqlite_error)
    }

    pub fn complete_inbound_peer_envelope(
        &self,
        sender_installation_id: &str,
        message_id: &str,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "UPDATE inbound_peer_envelopes
                 SET state = 'DELIVERED', updated_at = unixepoch()
                 WHERE sender_installation_id = ?1 AND message_id = ?2;",
                params![sender_installation_id, message_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn reject_inbound_peer_envelope(
        &self,
        sender_installation_id: &str,
        message_id: &str,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "UPDATE inbound_peer_envelopes
                 SET state = 'REJECTED', updated_at = unixepoch()
                 WHERE sender_installation_id = ?1 AND message_id = ?2;",
                params![sender_installation_id, message_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }
}
