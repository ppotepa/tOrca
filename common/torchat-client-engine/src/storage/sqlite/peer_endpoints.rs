use super::*;

impl ClientDatabase {
    pub fn local_peer_endpoint(&self) -> EngineResult<Option<(PeerEndpointBundle, u64)>> {
        let stored = self
            .connection
            .query_row(
                "SELECT bundle_json, generation
                 FROM local_peer_endpoint
                 WHERE singleton = 1;",
                [],
                |row| {
                    Ok((
                        row.get::<_, Vec<u8>>("bundle_json")?,
                        row.get::<_, i64>("generation")?,
                    ))
                },
            )
            .optional()
            .map_err(sqlite_error)?;
        stored
            .map(|(json, generation)| {
                serde_json::from_slice(&json)
                    .map(|endpoint| (endpoint, generation as u64))
                    .map_err(|error| {
                        EngineError::Storage(format!("decode local peer endpoint: {error}"))
                    })
            })
            .transpose()
    }

    pub fn put_local_peer_endpoint(
        &self,
        endpoint: &PeerEndpointBundle,
        generation: u64,
    ) -> EngineResult<()> {
        let json = serde_json::to_vec(endpoint).map_err(|error| {
            EngineError::Storage(format!("encode local peer endpoint: {error}"))
        })?;
        self.connection
            .execute(
                "INSERT INTO local_peer_endpoint (
                    singleton, bundle_json, sequence, generation, updated_at
                 ) VALUES (1, ?1, ?2, ?3, unixepoch())
                 ON CONFLICT(singleton) DO UPDATE SET
                    bundle_json = excluded.bundle_json,
                    sequence = excluded.sequence,
                    generation = excluded.generation,
                    updated_at = unixepoch();",
                params![json, endpoint.sequence as i64, generation as i64],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn delete_local_peer_endpoint(&self) -> EngineResult<()> {
        self.connection
            .execute("DELETE FROM local_peer_endpoint WHERE singleton = 1;", [])
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn contact_peer_endpoint(
        &self,
        installation_id: &str,
    ) -> EngineResult<Option<PeerEndpointBundle>> {
        let json = self
            .connection
            .query_row(
                "SELECT bundle_json
                 FROM contact_peer_endpoints
                 WHERE contact_installation_id = ?1;",
                [installation_id],
                |row| row.get::<_, Vec<u8>>("bundle_json"),
            )
            .optional()
            .map_err(sqlite_error)?;
        json.map(|value| {
            serde_json::from_slice(&value).map_err(|error| {
                EngineError::Storage(format!("decode contact peer endpoint: {error}"))
            })
        })
        .transpose()
    }

    pub fn put_contact_peer_endpoint(&self, endpoint: &PeerEndpointBundle) -> EngineResult<()> {
        let json = serde_json::to_vec(endpoint).map_err(|error| {
            EngineError::Storage(format!("encode contact peer endpoint: {error}"))
        })?;
        self.connection
            .execute(
                "INSERT INTO contact_peer_endpoints (
                    contact_installation_id, bundle_json, sequence, updated_at
                 ) VALUES (?1, ?2, ?3, unixepoch())
                 ON CONFLICT(contact_installation_id) DO UPDATE SET
                    bundle_json = excluded.bundle_json,
                    sequence = excluded.sequence,
                    updated_at = unixepoch()
                 WHERE excluded.sequence > contact_peer_endpoints.sequence;",
                params![endpoint.installation_id, json, endpoint.sequence as i64,],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn ensure_contact_endpoint_capability(
        &self,
        contact_installation_id: &str,
    ) -> EngineResult<String> {
        if let Some(value) = self
            .connection
            .query_row(
                "SELECT capability_id FROM contact_endpoint_capabilities
                 WHERE contact_installation_id = ?1
                   AND revoked_at IS NULL
                   AND (expires_at IS NULL OR expires_at >= unixepoch());",
                [contact_installation_id],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(sqlite_error)?
        {
            return Ok(value);
        }
        let capability_id = Uuid::new_v4().simple().to_string()[..16].to_owned();
        let secret = Uuid::new_v4().as_bytes().to_vec();
        let secret_hash = sha2::Sha256::digest(&secret).to_vec();
        self.connection
            .execute(
                "INSERT INTO contact_endpoint_capabilities (
                    contact_installation_id, capability_id, secret_hash, secret_ciphertext,
                    issued_at, updated_at
                 ) VALUES (?1, ?2, ?3, ?4, unixepoch(), unixepoch())
                 ON CONFLICT(contact_installation_id) DO UPDATE SET
                    capability_id = excluded.capability_id,
                    secret_hash = excluded.secret_hash,
                    secret_ciphertext = excluded.secret_ciphertext,
                    sequence = contact_endpoint_capabilities.sequence + 1,
                    issued_at = unixepoch(),
                    revoked_at = NULL,
                    updated_at = unixepoch();",
                params![contact_installation_id, capability_id, secret_hash, secret],
            )
            .map_err(sqlite_error)?;
        Ok(capability_id)
    }

    pub fn revoke_contact_endpoint_capability(
        &self,
        contact_installation_id: &str,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "UPDATE contact_endpoint_capabilities
                 SET revoked_at = unixepoch(), updated_at = unixepoch()
                 WHERE contact_installation_id = ?1;",
                [contact_installation_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn contact_endpoint_capability(
        &self,
        contact_installation_id: &str,
    ) -> EngineResult<Option<ContactEndpointCapability>> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|error| EngineError::Storage(error.to_string()))?
            .as_secs() as i64;
        self.connection
            .query_row(
                "SELECT capability_id, secret_ciphertext, sequence, revoked_at, expires_at
                 FROM contact_endpoint_capabilities
                 WHERE contact_installation_id = ?1;",
                [contact_installation_id],
                |row| {
                    let revoked_at: Option<i64> = row.get(3)?;
                    let expires_at: Option<i64> = row.get(4)?;
                    let status = if revoked_at.is_some() {
                        CapabilityStatus::Revoked
                    } else if expires_at.is_some_and(|value| value < now) {
                        CapabilityStatus::Expired
                    } else {
                        CapabilityStatus::Active
                    };
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, Vec<u8>>(1)?,
                        row.get::<_, i64>(2)? as u64,
                        status,
                    ))
                },
            )
            .optional()
            .map_err(sqlite_error)
    }

    pub fn put_peer_endpoint_capability(
        &self,
        contact_installation_id: &str,
        capability_id: &str,
        secret: &[u8],
        sequence: u64,
        issued_at: i64,
        expires_at: Option<i64>,
    ) -> EngineResult<()> {
        let secret_hash = sha2::Sha256::digest(secret).to_vec();
        self.connection
            .execute(
                "INSERT INTO peer_endpoint_capabilities (
                    contact_installation_id, capability_id, secret_hash,
                    secret_ciphertext, sequence, issued_at, expires_at, updated_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, unixepoch())
                 ON CONFLICT(contact_installation_id) DO UPDATE SET
                    capability_id = excluded.capability_id,
                    secret_hash = excluded.secret_hash,
                    secret_ciphertext = excluded.secret_ciphertext,
                    sequence = excluded.sequence,
                    issued_at = excluded.issued_at,
                    expires_at = excluded.expires_at,
                    revoked_at = NULL,
                    updated_at = unixepoch()
                 WHERE excluded.sequence >= peer_endpoint_capabilities.sequence;",
                params![
                    contact_installation_id,
                    capability_id,
                    secret_hash,
                    secret,
                    sequence as i64,
                    issued_at,
                    expires_at,
                ],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn peer_endpoint_capability_secret(
        &self,
        contact_installation_id: &str,
        capability_id: &str,
    ) -> EngineResult<Option<Vec<u8>>> {
        self.connection
            .query_row(
                "SELECT secret_ciphertext FROM peer_endpoint_capabilities
                 WHERE contact_installation_id = ?1
                   AND capability_id = ?2
                   AND revoked_at IS NULL
                   AND (expires_at IS NULL OR expires_at >= unixepoch());",
                params![contact_installation_id, capability_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(sqlite_error)
    }

    pub fn revoke_peer_endpoint_capability(
        &self,
        contact_installation_id: &str,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "UPDATE peer_endpoint_capabilities
                 SET revoked_at = unixepoch(), updated_at = unixepoch()
                 WHERE contact_installation_id = ?1;",
                [contact_installation_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn mark_peer_connected(
        &self,
        installation_id: &str,
        connected_at: i64,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "UPDATE contact_peer_endpoints
                 SET last_connected_at = ?2, updated_at = unixepoch()
                 WHERE contact_installation_id = ?1;",
                params![installation_id, connected_at],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn enqueue_endpoint_update_for_contacts(
        &self,
        update: &PeerEndpointUpdate,
    ) -> EngineResult<()> {
        let payload = serde_json::to_vec(update).map_err(|error| {
            EngineError::Storage(format!("encode peer endpoint update: {error}"))
        })?;
        self.connection
            .execute(
                "INSERT OR IGNORE INTO endpoint_update_outbox (
                    contact_installation_id, payload, sequence, attempt_count,
                    next_attempt_at, last_error, updated_at
                 )
                 SELECT installation_id, ?1, ?2, 0, 0, NULL, unixepoch()
                 FROM contacts;",
                params![payload, update.endpoint.sequence as i64],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn pending_endpoint_updates(
        &self,
        contact_installation_id: &str,
    ) -> EngineResult<Vec<PeerEndpointUpdate>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT payload
                 FROM endpoint_update_outbox
                 WHERE contact_installation_id = ?1
                 ORDER BY sequence ASC;",
            )
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map([contact_installation_id], |row| row.get::<_, Vec<u8>>(0))
            .map_err(sqlite_error)?;
        rows.map(|row| {
            let payload = row.map_err(sqlite_error)?;
            serde_json::from_slice(&payload).map_err(|error| {
                EngineError::Storage(format!("decode peer endpoint update: {error}"))
            })
        })
        .collect()
    }

    pub fn complete_endpoint_updates(
        &self,
        contact_installation_id: &str,
        through_sequence: u64,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "DELETE FROM endpoint_update_outbox
                 WHERE contact_installation_id = ?1 AND sequence <= ?2;",
                params![contact_installation_id, through_sequence as i64],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn put_peer_endpoint_bootstrap(
        &self,
        contact_installation_id: &str,
        payload: &[u8],
        endpoint_sequence: u64,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "INSERT INTO peer_endpoint_bootstrap_outbox (
                    contact_installation_id, payload, endpoint_sequence, attempt_count,
                    next_attempt_at, last_error, updated_at
                 ) VALUES (?1, ?2, ?3, 0, 0, NULL, unixepoch())
                 ON CONFLICT(contact_installation_id) DO UPDATE SET
                    payload = excluded.payload,
                    endpoint_sequence = excluded.endpoint_sequence,
                    attempt_count = 0,
                    next_attempt_at = 0,
                    last_error = NULL,
                    updated_at = unixepoch()
                 WHERE excluded.endpoint_sequence >= peer_endpoint_bootstrap_outbox.endpoint_sequence;",
                params![contact_installation_id, payload, endpoint_sequence as i64],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn due_peer_endpoint_bootstraps(
        &self,
        now_ms: i64,
    ) -> EngineResult<Vec<PeerEndpointBootstrapRecord>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT contact_installation_id, payload, endpoint_sequence, attempt_count,
                        next_attempt_at, last_error
                 FROM peer_endpoint_bootstrap_outbox
                 WHERE next_attempt_at <= ?1
                 ORDER BY next_attempt_at ASC, contact_installation_id ASC;",
            )
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map([now_ms], |row| {
                Ok(PeerEndpointBootstrapRecord {
                    contact_installation_id: row.get("contact_installation_id")?,
                    payload: row.get("payload")?,
                    endpoint_sequence: row.get::<_, i64>("endpoint_sequence")? as u64,
                    attempt_count: row.get::<_, i64>("attempt_count")? as u32,
                    next_attempt_at: row.get("next_attempt_at")?,
                    last_error: row.get("last_error")?,
                })
            })
            .map_err(sqlite_error)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(sqlite_error)
    }

    pub fn claim_peer_endpoint_bootstrap_attempt(
        &self,
        contact_installation_id: &str,
        endpoint_sequence: u64,
        next_attempt_at: i64,
        last_error: Option<&str>,
    ) -> EngineResult<bool> {
        let changed = self
            .connection
            .execute(
                "UPDATE peer_endpoint_bootstrap_outbox
                 SET attempt_count = attempt_count + 1,
                     next_attempt_at = ?1,
                     last_error = ?2,
                     updated_at = unixepoch()
                 WHERE contact_installation_id = ?3
                   AND endpoint_sequence = ?4
                   AND next_attempt_at <= ?5;",
                params![
                    next_attempt_at,
                    last_error,
                    contact_installation_id,
                    endpoint_sequence as i64,
                    unix_ms()
                ],
            )
            .map_err(sqlite_error)?;
        Ok(changed == 1)
    }

    pub fn complete_peer_endpoint_bootstrap(
        &self,
        contact_installation_id: &str,
        endpoint_sequence: u64,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "DELETE FROM peer_endpoint_bootstrap_outbox
                 WHERE contact_installation_id = ?1
                   AND endpoint_sequence <= ?2;",
                params![contact_installation_id, endpoint_sequence as i64],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn next_peer_endpoint_bootstrap_retry_deadline_ms(&self) -> EngineResult<Option<i64>> {
        self.connection
            .query_row(
                "SELECT MIN(next_attempt_at) AS next_attempt_at
                 FROM peer_endpoint_bootstrap_outbox;",
                [],
                |row| row.get("next_attempt_at"),
            )
            .map_err(sqlite_error)
    }
    pub fn record_peer_endpoint_bootstrap_error(
        &self,
        contact_installation_id: &str,
        endpoint_sequence: u64,
        error: &str,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "UPDATE peer_endpoint_bootstrap_outbox
                 SET last_error = ?1,
                     updated_at = unixepoch()
                 WHERE contact_installation_id = ?2
                   AND endpoint_sequence = ?3;",
                params![error, contact_installation_id, endpoint_sequence as i64],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }
}
