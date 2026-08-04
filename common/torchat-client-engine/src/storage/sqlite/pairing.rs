use super::*;

impl ClientDatabase {
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
                    record.local_capability_id,
                    record.local_capability_secret,
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
                        local_capability_id: row.get("local_capability_id")?,
                        local_capability_secret: row.get("local_capability_secret")?,
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
