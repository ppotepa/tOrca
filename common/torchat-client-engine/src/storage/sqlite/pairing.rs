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
                super::sql_catalog::pairing::PUT_PENDING_CONTACT_CONFIRMATION,
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
                super::sql_catalog::pairing::PUT_PENDING_PAIRING_ACKNOWLEDGEMENT,
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
            .prepare(super::sql_catalog::pairing::DUE_PENDING_PAIRING_ACKNOWLEDGEMENTS)
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
                super::sql_catalog::pairing::CLAIM_PENDING_PAIRING_ACKNOWLEDGEMENT,
                params![next_attempt_at, last_error, pairing_id, now_ms],
            )
            .map_err(sqlite_error)?;
        Ok(changed > 0)
    }

    pub fn complete_pending_pairing_acknowledgement(&self, pairing_id: &str) -> EngineResult<()> {
        self.connection
            .execute(
                super::sql_catalog::pairing::COMPLETE_PENDING_PAIRING_ACKNOWLEDGEMENT,
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
                super::sql_catalog::pairing::NEXT_PENDING_PAIRING_ACKNOWLEDGEMENT_RETRY,
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
            .prepare(super::sql_catalog::pairing::DUE_PENDING_CONTACT_CONFIRMATIONS)
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
                super::sql_catalog::pairing::CLAIM_PENDING_CONTACT_CONFIRMATION,
                params![next_attempt_at, last_error, pairing_id, unix_ms()],
            )
            .map_err(sqlite_error)?;
        Ok(changed == 1)
    }

    pub fn complete_pending_contact_confirmation(&self, pairing_id: &str) -> EngineResult<()> {
        self.connection
            .execute(
                super::sql_catalog::pairing::COMPLETE_PENDING_CONTACT_CONFIRMATION,
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
                super::sql_catalog::pairing::RECORD_PENDING_CONTACT_CONFIRMATION_ERROR,
                params![error, pairing_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn next_pending_contact_confirmation_retry_deadline_ms(&self) -> EngineResult<Option<i64>> {
        self.connection
            .query_row(
                super::sql_catalog::pairing::NEXT_PENDING_CONTACT_CONFIRMATION_RETRY,
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
                super::sql_catalog::pairing::PUT_PENDING_LOCAL_INVITE_MLS,
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
                super::sql_catalog::pairing::PENDING_LOCAL_INVITE_MLS,
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
                super::sql_catalog::pairing::DELETE_EXPIRED_PENDING_LOCAL_INVITE_MLS,
                [now_secs],
            )
            .map_err(sqlite_error)
    }

    pub fn pending_welcomes(&self, now_secs: i64) -> EngineResult<Vec<PendingWelcomeRecord>> {
        let mut statement = self
            .connection
            .prepare(super::sql_catalog::pairing::PENDING_WELCOMES)
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
                super::sql_catalog::pairing::PENDING_WELCOME,
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
                super::sql_catalog::pairing::PUT_PENDING_WELCOME,
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
                super::sql_catalog::pairing::REMOVE_PENDING_WELCOME,
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
                super::sql_catalog::pairing::PUT_PENDING_PEER_ENDPOINT_INBOX,
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
                super::sql_catalog::pairing::PENDING_PEER_ENDPOINT_INBOX,
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
                super::sql_catalog::pairing::REMOVE_PENDING_PEER_ENDPOINT_INBOX,
                [contact_installation_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }
}
