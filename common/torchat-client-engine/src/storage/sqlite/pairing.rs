use super::*;

impl ClientDatabase {
    pub fn put_pending_contact_confirmation(
        &self,
        pairing_id: &str,
        peer_installation_id: &str,
        capability: &str,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "INSERT INTO pending_contact_confirmations (
                    pairing_id, peer_installation_id, capability, attempt_count,
                    next_attempt_at, last_error, created_at, updated_at
                 ) VALUES (?1, ?2, ?3, 0, 0, NULL, unixepoch(), unixepoch())
                 ON CONFLICT(pairing_id) DO UPDATE SET
                    peer_installation_id = excluded.peer_installation_id,
                    capability = excluded.capability,
                    attempt_count = 0,
                    next_attempt_at = 0,
                    last_error = NULL,
                    updated_at = unixepoch();",
                params![pairing_id, peer_installation_id, capability],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn put_pending_pairing_acknowledgement(
        &self,
        pairing_id: &str,
        last_error: Option<&str>,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "INSERT INTO pending_pairing_acknowledgements (
                    pairing_id, attempt_count, next_attempt_at, last_error
                 ) VALUES (?1, 0, 0, ?2)
                 ON CONFLICT(pairing_id) DO UPDATE SET
                    next_attempt_at = 0,
                    last_error = excluded.last_error;",
                params![pairing_id, last_error],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn due_pending_pairing_acknowledgements(
        &self,
        now_ms: i64,
    ) -> EngineResult<Vec<(String, u32)>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT pairing_id, attempt_count
                 FROM pending_pairing_acknowledgements
                 WHERE next_attempt_at <= ?1
                 ORDER BY next_attempt_at ASC, pairing_id ASC;",
            )
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map([now_ms], |row| {
                Ok((
                    row.get::<_, String>("pairing_id")?,
                    row.get::<_, i64>("attempt_count")? as u32,
                ))
            })
            .map_err(sqlite_error)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(sqlite_error)
    }

    pub fn claim_pending_pairing_acknowledgement_attempt(
        &self,
        pairing_id: &str,
        next_attempt_at: i64,
        last_error: Option<&str>,
    ) -> EngineResult<bool> {
        let now_ms = unix_ms();
        let changed = self
            .connection
            .execute(
                "UPDATE pending_pairing_acknowledgements
                 SET attempt_count = attempt_count + 1,
                     next_attempt_at = ?1,
                     last_error = ?2
                 WHERE pairing_id = ?3
                   AND next_attempt_at <= ?4;",
                params![next_attempt_at, last_error, pairing_id, now_ms],
            )
            .map_err(sqlite_error)?;
        Ok(changed > 0)
    }

    pub fn complete_pending_pairing_acknowledgement(&self, pairing_id: &str) -> EngineResult<()> {
        self.connection
            .execute(
                "DELETE FROM pending_pairing_acknowledgements
                 WHERE pairing_id = ?1;",
                [pairing_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn next_pending_pairing_acknowledgement_retry_deadline_ms(
        &self,
    ) -> EngineResult<Option<i64>> {
        self.connection
            .query_row(
                "SELECT MIN(next_attempt_at)
                 FROM pending_pairing_acknowledgements;",
                [],
                |row| row.get(0),
            )
            .optional()
            .map(|value| value.flatten())
            .map_err(sqlite_error)
    }

    pub fn due_pending_contact_confirmations(
        &self,
        now_ms: i64,
    ) -> EngineResult<Vec<PendingContactConfirmationRecord>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT pairing_id, peer_installation_id, capability, attempt_count,
                        next_attempt_at, last_error
                 FROM pending_contact_confirmations
                 WHERE next_attempt_at <= ?1
                 ORDER BY next_attempt_at ASC, pairing_id ASC;",
            )
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map([now_ms], |row| {
                Ok(PendingContactConfirmationRecord {
                    pairing_id: row.get("pairing_id")?,
                    peer_installation_id: row.get("peer_installation_id")?,
                    capability: row.get("capability")?,
                    attempt_count: row.get::<_, i64>("attempt_count")? as u32,
                    next_attempt_at: row.get("next_attempt_at")?,
                    last_error: row.get("last_error")?,
                })
            })
            .map_err(sqlite_error)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(sqlite_error)
    }

    pub fn claim_pending_contact_confirmation_attempt(
        &self,
        pairing_id: &str,
        next_attempt_at: i64,
        last_error: Option<&str>,
    ) -> EngineResult<bool> {
        let changed = self
            .connection
            .execute(
                "UPDATE pending_contact_confirmations
                 SET attempt_count = attempt_count + 1,
                     next_attempt_at = ?1,
                     last_error = ?2,
                     updated_at = unixepoch()
                 WHERE pairing_id = ?3
                   AND next_attempt_at <= ?4;",
                params![next_attempt_at, last_error, pairing_id, unix_ms()],
            )
            .map_err(sqlite_error)?;
        Ok(changed == 1)
    }

    pub fn complete_pending_contact_confirmation(&self, pairing_id: &str) -> EngineResult<()> {
        self.connection
            .execute(
                "DELETE FROM pending_contact_confirmations
                 WHERE pairing_id = ?1;",
                [pairing_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn record_pending_contact_confirmation_error(
        &self,
        pairing_id: &str,
        error: &str,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "UPDATE pending_contact_confirmations
                 SET last_error = ?1,
                     updated_at = unixepoch()
                 WHERE pairing_id = ?2;",
                params![error, pairing_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn next_pending_contact_confirmation_retry_deadline_ms(&self) -> EngineResult<Option<i64>> {
        self.connection
            .query_row(
                "SELECT MIN(next_attempt_at) AS next_attempt_at
                 FROM pending_contact_confirmations;",
                [],
                |row| row.get("next_attempt_at"),
            )
            .map_err(sqlite_error)
    }
    pub fn put_pending_local_invite_mls(
        &self,
        record: &PendingLocalInviteMlsRecord,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "INSERT INTO pending_local_invite_mls (
                    invite_id, recipient_installation_id, snapshot, expires_at
                 ) VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(invite_id) DO UPDATE SET
                    recipient_installation_id = excluded.recipient_installation_id,
                    snapshot = excluded.snapshot,
                    expires_at = excluded.expires_at;",
                params![
                    record.invite_id,
                    record.recipient_installation_id,
                    record.snapshot,
                    record.expires_at,
                ],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn pending_local_invite_mls(
        &self,
        invite_id: &str,
        now_secs: i64,
    ) -> EngineResult<Option<PendingLocalInviteMlsRecord>> {
        self.connection
            .query_row(
                "SELECT invite_id, recipient_installation_id, snapshot, expires_at
                 FROM pending_local_invite_mls
                 WHERE invite_id = ?1 AND expires_at >= ?2;",
                params![invite_id, now_secs],
                |row| {
                    Ok(PendingLocalInviteMlsRecord {
                        invite_id: row.get("invite_id")?,
                        recipient_installation_id: row.get("recipient_installation_id")?,
                        snapshot: row.get("snapshot")?,
                        expires_at: row.get("expires_at")?,
                    })
                },
            )
            .optional()
            .map_err(sqlite_error)
    }

    pub fn delete_expired_pending_local_invite_mls(&self, now_secs: i64) -> EngineResult<usize> {
        self.connection
            .execute(
                "DELETE FROM pending_local_invite_mls WHERE expires_at < ?1;",
                [now_secs],
            )
            .map_err(sqlite_error)
    }

    pub fn pending_welcomes(&self, now_secs: i64) -> EngineResult<Vec<PendingWelcomeRecord>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT invite_id, recipient_installation_id, payload, expires_at,
                        attempt_count, next_attempt_at, last_error
                 FROM pending_welcomes
                 WHERE expires_at >= ?1
                 ORDER BY expires_at ASC, invite_id ASC;",
            )
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map([now_secs], |row| {
                Ok(PendingWelcomeRecord {
                    invite_id: row.get("invite_id")?,
                    recipient_installation_id: row.get("recipient_installation_id")?,
                    payload: row.get("payload")?,
                    expires_at: row.get("expires_at")?,
                    attempt_count: row.get::<_, i64>("attempt_count")? as u32,
                    next_attempt_at: row.get("next_attempt_at")?,
                    last_error: row.get("last_error")?,
                })
            })
            .map_err(sqlite_error)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(sqlite_error)
    }

    pub fn pending_welcome(&self, invite_id: &str) -> EngineResult<Option<PendingWelcomeRecord>> {
        self.connection
            .query_row(
                "SELECT invite_id, recipient_installation_id, payload, expires_at,
                        attempt_count, next_attempt_at, last_error
                 FROM pending_welcomes
                 WHERE invite_id = ?1;",
                [invite_id],
                |row| {
                    Ok(PendingWelcomeRecord {
                        invite_id: row.get("invite_id")?,
                        recipient_installation_id: row.get("recipient_installation_id")?,
                        payload: row.get("payload")?,
                        expires_at: row.get("expires_at")?,
                        attempt_count: row.get::<_, i64>("attempt_count")? as u32,
                        next_attempt_at: row.get("next_attempt_at")?,
                        last_error: row.get("last_error")?,
                    })
                },
            )
            .optional()
            .map_err(sqlite_error)
    }

    pub fn put_pending_welcome(&self, record: &PendingWelcomeRecord) -> EngineResult<()> {
        self.connection
            .execute(
                "INSERT INTO pending_welcomes (
                    invite_id, recipient_installation_id, payload, expires_at,
                    attempt_count, next_attempt_at, last_error
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                 ON CONFLICT(invite_id) DO UPDATE SET
                    recipient_installation_id = excluded.recipient_installation_id,
                    payload = excluded.payload,
                    expires_at = excluded.expires_at,
                    attempt_count = excluded.attempt_count,
                    next_attempt_at = excluded.next_attempt_at,
                    last_error = excluded.last_error;",
                params![
                    record.invite_id,
                    record.recipient_installation_id,
                    record.payload,
                    record.expires_at,
                    i64::from(record.attempt_count),
                    record.next_attempt_at,
                    record.last_error,
                ],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn remove_pending_welcome(&self, invite_id: &str) -> EngineResult<()> {
        self.connection
            .execute(
                "DELETE FROM pending_welcomes
                 WHERE invite_id = ?1;",
                [invite_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn put_pending_peer_endpoint_inbox(
        &self,
        record: &PendingPeerEndpointInboxRecord,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "INSERT INTO pending_peer_endpoint_inbox (
                    contact_installation_id, payload, endpoint_sequence, received_at
                 ) VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(contact_installation_id) DO UPDATE SET
                    payload = excluded.payload,
                    endpoint_sequence = excluded.endpoint_sequence,
                    received_at = excluded.received_at
                 WHERE excluded.endpoint_sequence > pending_peer_endpoint_inbox.endpoint_sequence;",
                params![
                    record.contact_installation_id,
                    record.payload,
                    record.endpoint_sequence as i64,
                    record.received_at,
                ],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn pending_peer_endpoint_inbox(
        &self,
        contact_installation_id: &str,
    ) -> EngineResult<Option<PendingPeerEndpointInboxRecord>> {
        self.connection
            .query_row(
                "SELECT contact_installation_id, payload, endpoint_sequence, received_at
                 FROM pending_peer_endpoint_inbox
                 WHERE contact_installation_id = ?1;",
                [contact_installation_id],
                |row| {
                    Ok(PendingPeerEndpointInboxRecord {
                        contact_installation_id: row.get("contact_installation_id")?,
                        payload: row.get("payload")?,
                        endpoint_sequence: row.get::<_, i64>("endpoint_sequence")? as u64,
                        received_at: row.get("received_at")?,
                    })
                },
            )
            .optional()
            .map_err(sqlite_error)
    }

    pub fn remove_pending_peer_endpoint_inbox(
        &self,
        contact_installation_id: &str,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "DELETE FROM pending_peer_endpoint_inbox
                 WHERE contact_installation_id = ?1;",
                [contact_installation_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }
}
