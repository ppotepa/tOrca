use super::*;

impl ClientEngineActor {
    pub(crate) fn endpoint_with_capability(
        &self,
        endpoint: &PeerEndpointBundle,
        capability_id: &str,
    ) -> PeerEndpointBundle {
        let marker = format!("contact_endpoint_v1:{capability_id}");
        let mut endpoint = endpoint.clone();
        if !endpoint.capabilities.iter().any(|value| value == &marker) {
            endpoint.sequence = endpoint.sequence.saturating_add(1);
            endpoint.capabilities.push(marker);
            endpoint.signature = self.identity.sign(&endpoint.signing_bytes());
        }
        endpoint
    }

    pub(crate) fn local_endpoint_for_contact(
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
}

impl ClientEngineActor {
    pub(crate) fn apply_peer_endpoint(
        &mut self,
        endpoint: PeerEndpointBundle,
    ) -> EngineResult<Vec<torchat_runtime::RuntimeEvent>> {
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
        Ok(vec![torchat_runtime::RuntimeEvent::PeerEndpointChanged {
            contact_id,
            status: PeerEndpointStatus::Verified,
        }])
    }

    pub(crate) fn apply_pending_peer_endpoint(
        &mut self,
        contact_installation_id: &str,
    ) -> EngineResult<Vec<torchat_runtime::RuntimeEvent>> {
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
    pub(crate) fn send_capability_offer(
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

    pub(crate) fn send_capability_offers_for_contacts(&mut self) -> EngineResult<()> {
        if !self.network_online || self.socks5_url.is_none() {
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

    pub(crate) fn retry_capability_deliveries(&mut self) -> EngineResult<()> {
        if !self.network_online || self.socks5_url.is_none() {
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
            let payload = std::str::from_utf8(&record.payload)
                .map_err(|value| EngineError::Serialization(value.to_string()))?;
            if let Err(error) = self.dispatch_ephemeral_payload(
                &record.contact_installation_id,
                payload.to_owned(),
                true,
                true,
                Some(record.delivery_id.clone()),
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
    pub(crate) fn refresh_peer_authorizations(&mut self) -> EngineResult<()> {
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

    pub(crate) fn local_capability_credentials(
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

    pub(crate) fn peer_capability_secret(
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
