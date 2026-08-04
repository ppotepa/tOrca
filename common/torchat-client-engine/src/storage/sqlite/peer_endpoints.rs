use super::*;

impl ClientDatabase {
    pub fn local_peer_endpoint(&self) -> EngineResult<Option<(PeerEndpointBundle, u64)>> {
        let stored = self
            .connection
            .query_row(super::sql_catalog::peer_endpoints::LOCAL, [], |row| {
                Ok((
                    row.get::<_, Vec<u8>>("bundle_json")?,
                    row.get::<_, i64>("generation")?,
                ))
            })
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
                super::sql_catalog::peer_endpoints::PUT_LOCAL,
                params![json, endpoint.sequence as i64, generation as i64],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn delete_local_peer_endpoint(&self) -> EngineResult<()> {
        self.connection
            .execute(super::sql_catalog::peer_endpoints::DELETE_LOCAL, [])
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
                super::sql_catalog::peer_endpoints::CONTACT,
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
        let removed: bool = self
            .connection
            .query_row(
                super::sql_catalog::peer_endpoints::PUT_CONTACT,
                [&endpoint.installation_id],
                |row| row.get(0),
            )
            .map_err(sqlite_error)?;
        if removed {
            return Ok(());
        }
        let json = serde_json::to_vec(endpoint).map_err(|error| {
            EngineError::Storage(format!("encode contact peer endpoint: {error}"))
        })?;
        self.connection
            .execute(
                super::sql_catalog::peer_endpoints::PUT_CONTACT_COMMAND,
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
                super::sql_catalog::peer_endpoints::ENSURE_CONTACT_CAPABILITY,
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
                super::sql_catalog::peer_endpoints::ENSURE_CONTACT_CAPABILITY_COMMAND,
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
                super::sql_catalog::peer_endpoints::REVOKE_CONTACT_CAPABILITY,
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
                super::sql_catalog::peer_endpoints::CONTACT_CAPABILITY,
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
                super::sql_catalog::peer_endpoints::PUT_CAPABILITY,
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
                super::sql_catalog::peer_endpoints::CAPABILITY_SECRET,
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
                super::sql_catalog::peer_endpoints::REVOKE_CAPABILITY,
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
                super::sql_catalog::peer_endpoints::MARK_CONNECTED,
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
                super::sql_catalog::peer_endpoints::ENQUEUE_UPDATE,
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
            .prepare(super::sql_catalog::peer_endpoints::PENDING_UPDATES)
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
                super::sql_catalog::peer_endpoints::COMPLETE_UPDATES,
                params![contact_installation_id, through_sequence as i64],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

}
