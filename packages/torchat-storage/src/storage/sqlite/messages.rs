use super::*;

impl ClientDatabase {
    pub fn mark_message_dead_lettered(
        &self,
        error_code: &str,
        message_id: &str,
    ) -> EngineResult<()> {
        let changed = self
            .connection
            .execute(
                super::sql_catalog::messages::MARK_DEAD_LETTERED,
                rusqlite::params![error_code, message_id],
            )
            .map_err(sqlite_error)?;
        super::affected_rows::exactly_one(changed, "mark message dead-lettered")
    }

    pub fn enqueue_outbound_delivery(
        &self,
        message_id: &str,
        contact_installation_id: &str,
        sequence: u64,
        created_at: i64,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                super::sql_catalog::messages::ENQUEUE_OUTBOUND_DELIVERY,
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
            .prepare(super::sql_catalog::messages::DUE_OUTBOUND_DELIVERIES)
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
                super::sql_catalog::messages::OUTBOUND_DELIVERY,
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
                super::sql_catalog::messages::NEXT_CONTACT_PEER_RETRY_DEADLINE_MS,
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
                super::sql_catalog::messages::NEXT_CONTACT_RECEIPT_RETRY_DEADLINE_MS,
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
                super::sql_catalog::messages::CLAIM_OUTBOUND_DELIVERY,
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
                super::sql_catalog::messages::REQUEUE_OUTBOUND_DELIVERY,
                params![message_id, next_attempt_at, error],
            )
            .map_err(sqlite_error)?;
        self.connection
            .execute(
                super::sql_catalog::messages::REQUEUE_OUTBOUND_DELIVERY_AFTER_DISCONNECT,
                [message_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn complete_outbound_delivery(&self, message_id: &str) -> EngineResult<()> {
        self.connection
            .execute(
                super::sql_catalog::messages::COMPLETE_OUTBOUND_DELIVERY,
                [message_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn expedite_peer_deliveries(&self, installation_id: &str) -> EngineResult<()> {
        self.connection
            .execute(
                super::sql_catalog::messages::EXPEDITE_PEER_DELIVERIES,
                [installation_id],
            )
            .map_err(sqlite_error)?;
        self.connection
            .execute(
                super::sql_catalog::messages::EXPEDITE_PEER_DELIVERIES_BY_CONTACT,
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
                super::sql_catalog::messages::REQUEUE_PEER_DELIVERIES,
                [now_ms],
            )
            .map_err(sqlite_error)?;
        transaction
            .execute(
                super::sql_catalog::messages::REQUEUE_PEER_DELIVERIES_AFTER_DISCONNECT,
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
                super::sql_catalog::messages::STORE_INBOUND_PEER_ENVELOPE,
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
                super::sql_catalog::messages::STORE_INBOUND_PEER_ENVELOPE_STATE,
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
            .prepare(super::sql_catalog::messages::PENDING_INBOUND_PEER_ENVELOPES)
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
            .prepare(super::sql_catalog::messages::REJECTED_INBOUND_PEER_SENDERS)
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
                super::sql_catalog::messages::COMPLETE_INBOUND_PEER_ENVELOPE,
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
                super::sql_catalog::messages::REJECT_INBOUND_PEER_ENVELOPE,
                params![sender_installation_id, message_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }
}
