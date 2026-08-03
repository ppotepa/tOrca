use super::*;

impl ClientEngineActor {
    pub(super) fn queue_relay_endpoint_bootstraps(&mut self) -> EngineResult<()> {
        if self.connection_state != ConnectionState::Connected {
            return Ok(());
        }
        let Some(local_endpoint) = self.local_peer_endpoint.clone() else {
            return Ok(());
        };
        let profile = self.runtime_profile()?;
        let protocol_nickname =
            protocol_nickname(&self.identity.installation_id(), &profile.nickname);
        for contact in self.list_contacts()? {
            let local_endpoint_for_contact =
                self.local_endpoint_for_contact(&contact.installation_id, &local_endpoint)?;
            let payload = RelayPayloadV1::peer_endpoint_bootstrap(
                &self.identity,
                &protocol_nickname,
                contact.installation_id.clone(),
                local_endpoint_for_contact.clone(),
            )
            .encode()
            .map_err(EngineError::InvalidCommand)?;
            self.database.put_peer_endpoint_bootstrap(
                &contact.installation_id,
                payload.as_bytes(),
                local_endpoint_for_contact.sequence,
            )?;
            if let Err(error) = self.send_peer_endpoint_bootstrap(PeerEndpointBootstrapRecord {
                contact_installation_id: contact.installation_id.clone(),
                payload: payload.into_bytes(),
                endpoint_sequence: local_endpoint_for_contact.sequence,
                attempt_count: 0,
                next_attempt_at: 0,
                last_error: None,
            }) {
                self.database.record_peer_endpoint_bootstrap_error(
                    &contact.installation_id,
                    local_endpoint_for_contact.sequence,
                    &format!("{}: {error}", super::retry_error_code(&error.to_string())),
                )?;
                self.pending_engine_events.push(EngineEvent::Log {
                    log: EngineLogEvent {
                        level: "warn".to_owned(),
                        message: format!(
                            "peer endpoint bootstrap enqueue failed contact={} error={error}",
                            contact.installation_id
                        ),
                    },
                });
            }
        }
        Ok(())
    }

    pub(super) fn local_endpoint_for_contact(
        &mut self,
        contact_installation_id: &str,
        endpoint: &PeerEndpointBundle,
    ) -> EngineResult<PeerEndpointBundle> {
        let capability_id = self
            .database
            .ensure_contact_endpoint_capability(contact_installation_id)?;
        let marker = format!("contact_endpoint_v1:{capability_id}");
        let mut endpoint = endpoint.clone();
        if !endpoint.capabilities.iter().any(|value| value == &marker) {
            endpoint.sequence = endpoint.sequence.saturating_add(1);
            endpoint.capabilities.push(marker);
            endpoint.signature = self.identity.sign(&endpoint.signing_bytes());
        }
        Ok(endpoint)
    }

    pub(super) fn send_peer_endpoint_bootstrap(
        &mut self,
        record: PeerEndpointBootstrapRecord,
    ) -> EngineResult<()> {
        let installation_id = record.contact_installation_id.clone();
        let recipient = installation_id.clone();
        let sequence = record.endpoint_sequence;
        let payload = String::from_utf8(record.payload).map_err(|error| {
            EngineError::Storage(format!(
                "stored peer endpoint bootstrap payload is invalid UTF-8: {error}"
            ))
        })?;
        self.queue_relay_envelope(
            uuid::Uuid::new_v4(),
            &recipient,
            &payload,
            PendingRelayDelivery::PeerEndpointBootstrap {
                installation_id,
                sequence,
            },
        )
    }
}

impl ClientEngineActor {
    pub(super) fn apply_peer_endpoint(
        &mut self,
        endpoint: PeerEndpointBundle,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        let previous = self
            .database
            .contact_peer_endpoint(&endpoint.installation_id)?;
        if !peer_endpoint_requires_update(previous.as_ref(), &endpoint, self.clock.now_ms() / 1_000)
            .map_err(EngineError::InvalidCommand)?
        {
            return Ok(Vec::new());
        }
        self.database.put_contact_peer_endpoint(&endpoint)?;
        self.database
            .ensure_contact_endpoint_capability(&endpoint.installation_id)?;
        if let (Some(transport), Some(base_endpoint)) = (
            self.peer_transport.clone(),
            self.local_peer_endpoint.clone(),
        ) {
            // Endpoint delivery can race with contact creation. Mint the
            // local per-contact capability idempotently before authorizing
            // the listener; a missing row must not leave the peer unusable.
            let (capability_id, secret) =
                self.local_capability_credentials(&endpoint.installation_id)?;
            let local_endpoint =
                self.local_endpoint_for_contact(&endpoint.installation_id, &base_endpoint)?;
            transport.authorize_contact(&endpoint, local_endpoint, capability_id, secret);
        }
        let contact_id = endpoint.installation_id.clone();
        let _ = self.queue_peer_probe(&contact_id);
        Ok(vec![
            torchat_client_runtime::RuntimeEvent::PeerEndpointChanged {
                contact_id,
                status: PeerEndpointStatus::Verified,
            },
        ])
    }

    pub(super) fn apply_pending_peer_endpoint(
        &mut self,
        contact_installation_id: &str,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        let Some(record) = self
            .database
            .pending_peer_endpoint_inbox(contact_installation_id)?
        else {
            return Ok(Vec::new());
        };
        let payload = String::from_utf8(record.payload).map_err(|error| {
            EngineError::Storage(format!(
                "stored peer endpoint bootstrap is not UTF-8: {error}"
            ))
        })?;
        let payload = RelayPayloadV1::decode(&payload).map_err(EngineError::InvalidCommand)?;
        let endpoint = payload
            .verify_peer_endpoint_bootstrap(
                &record.contact_installation_id,
                &self.identity.installation_id(),
            )
            .map_err(EngineError::InvalidCommand)?;
        let runtime_events = self.apply_peer_endpoint(endpoint)?;
        self.database
            .remove_pending_peer_endpoint_inbox(contact_installation_id)?;
        Ok(runtime_events)
    }
}

impl ClientEngineActor {
    pub(super) fn retry_peer_endpoint_bootstraps(&mut self) -> EngineResult<()> {
        if self.connection_state != ConnectionState::Connected {
            return Ok(());
        }
        for record in self
            .database
            .due_peer_endpoint_bootstraps(self.clock.now_ms())?
        {
            let next_attempt_at = self.clock.now_ms() + retry_backoff_ms(record.attempt_count);
            if !self.database.claim_peer_endpoint_bootstrap_attempt(
                &record.contact_installation_id,
                record.endpoint_sequence,
                next_attempt_at,
                None,
            )? {
                continue;
            }
            if let Err(error) = self.send_peer_endpoint_bootstrap(record.clone()) {
                self.database.record_peer_endpoint_bootstrap_error(
                    &record.contact_installation_id,
                    record.endpoint_sequence,
                    &format!("{}: {error}", super::retry_error_code(&error.to_string())),
                )?;
                self.pending_engine_events.push(EngineEvent::Log {
                    log: EngineLogEvent {
                        level: "warn".to_owned(),
                        message: format!(
                            "peer endpoint bootstrap retry failed contact={} error={error}",
                            record.contact_installation_id
                        ),
                    },
                });
            }
        }
        Ok(())
    }
}

impl ClientEngineActor {
    pub(super) fn send_capability_offer(
        &mut self,
        contact_installation_id: &str,
    ) -> EngineResult<()> {
        if !self.conversations.contains_key(contact_installation_id) {
            return Err(EngineError::Transport(
                "capability bootstrap is waiting for MLS Welcome".to_owned(),
            ));
        }
        if self
            .database
            .has_capability_delivery_for_contact(contact_installation_id)?
        {
            return Ok(());
        }
        self.database
            .ensure_contact_endpoint_capability(contact_installation_id)?;
        let Some((capability_id, secret, sequence, _status)) = self
            .database
            .contact_endpoint_capability(contact_installation_id)?
        else {
            return Err(EngineError::Storage(
                "contact capability was not created".to_owned(),
            ));
        };
        self.send_ephemeral_payload(
            contact_installation_id,
            ApplicationPayloadV1::CapabilityOffer {
                version: torchat_core::PROTOCOL_VERSION,
                capability_id,
                secret: URL_SAFE_NO_PAD.encode(secret),
                sequence,
                issued_at: self.clock.now_ms() / 1_000,
                expires_at: None,
            },
        )
    }

    pub(super) fn send_capability_offers_for_contacts(&mut self) -> EngineResult<()> {
        if self.connection_state != ConnectionState::Connected {
            return Ok(());
        }
        for contact in self.list_contacts()? {
            let remote_capability_ready = self
                .database
                .contact_peer_endpoint(&contact.installation_id)?
                .map(|endpoint| {
                    self.peer_capability_secret(&contact.installation_id, &endpoint)
                        .map(|secret| !secret.is_empty())
                })
                .transpose()?
                .unwrap_or(false);
            if self.conversations.contains_key(&contact.installation_id) && !remote_capability_ready
            {
                if self
                    .database
                    .has_capability_delivery_for_contact(&contact.installation_id)?
                {
                    continue;
                }
                if let Err(error) = self.send_capability_offer(&contact.installation_id) {
                    self.pending_engine_events.push(EngineEvent::Log {
                        log: EngineLogEvent {
                            level: "warn".to_owned(),
                            message: format!(
                                "capability bootstrap deferred contact={} error={error}",
                                contact.installation_id
                            ),
                        },
                    });
                }
            }
        }
        Ok(())
    }

    pub(super) fn retry_capability_deliveries(&mut self) -> EngineResult<()> {
        if self.connection_state != ConnectionState::Connected {
            return Ok(());
        }
        for record in self
            .database
            .due_capability_deliveries(self.clock.now_ms())?
        {
            let next_attempt = self.clock.now_ms() + retry_backoff_ms(record.attempt_count);
            if !self
                .database
                .claim_capability_delivery(&record.delivery_id, next_attempt, None)?
            {
                continue;
            }
            let envelope_id =
                uuid::Uuid::parse_str(&record.delivery_id).unwrap_or_else(|_| uuid::Uuid::new_v4());
            if let Err(error) = self.queue_relay_envelope(
                envelope_id,
                &record.contact_installation_id,
                std::str::from_utf8(&record.payload)
                    .map_err(|value| EngineError::Serialization(value.to_string()))?,
                PendingRelayDelivery::Ephemeral {
                    installation_id: record.contact_installation_id.clone(),
                    delivery_id: Some(record.delivery_id.clone()),
                },
            ) {
                self.database.record_capability_delivery_error(
                    &record.delivery_id,
                    next_attempt,
                    &format!("{}: {error}", super::retry_error_code(&error.to_string())),
                )?;
            }
        }
        Ok(())
    }
}

impl ClientEngineActor {
    pub(super) fn refresh_peer_authorizations(&mut self) -> EngineResult<()> {
        let Some(transport) = self.peer_transport.clone() else {
            return Ok(());
        };
        let Some(base_endpoint) = self.local_peer_endpoint.clone() else {
            return Ok(());
        };
        for contact in self.list_contacts()? {
            let Some(endpoint) = self
                .database
                .contact_peer_endpoint(&contact.installation_id)?
            else {
                continue;
            };
            self.database
                .ensure_contact_endpoint_capability(&contact.installation_id)?;
            let (capability_id, secret) =
                self.local_capability_credentials(&contact.installation_id)?;
            let local_endpoint =
                self.local_endpoint_for_contact(&contact.installation_id, &base_endpoint)?;
            transport.authorize_contact(&endpoint, local_endpoint, capability_id, secret);
        }
        Ok(())
    }

    pub(super) fn local_capability_credentials(
        &self,
        contact_installation_id: &str,
    ) -> EngineResult<(String, Vec<u8>)> {
        self.database
            .contact_endpoint_capability(contact_installation_id)?
            .map(|(id, secret, _, _)| (id, secret))
            .ok_or_else(|| {
                EngineError::Storage(format!(
                    "local endpoint capability is missing for contact {contact_installation_id}"
                ))
            })
    }

    pub(super) fn peer_capability_secret(
        &self,
        contact_installation_id: &str,
        endpoint: &PeerEndpointBundle,
    ) -> EngineResult<Vec<u8>> {
        Ok(self
            .database
            .peer_endpoint_capability_secret(
                contact_installation_id,
                &endpoint_capability_id(endpoint),
            )?
            .unwrap_or_default())
    }
}
