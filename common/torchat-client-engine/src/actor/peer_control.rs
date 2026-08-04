use super::*;

impl ClientEngineActor {
    pub(super) fn queue_peer_payload(
        &mut self,
        message_id: uuid::Uuid,
        recipient: &str,
        conversation_id: &str,
        sequence: u64,
        ciphertext: Vec<u8>,
        delivery: PeerDeliveryTag,
    ) -> EngineResult<()> {
        // Ciphertext is encoded as URL-safe base64 in the JSON peer envelope.
        // Keep enough room for envelope metadata and signatures below the
        // authenticated frame limit.
        if ciphertext.len() > MAX_TRANSPORT_CIPHERTEXT_BYTES {
            return Err(EngineError::Transport(format!(
                "peer payload exceeds safe frame budget ({} bytes)",
                ciphertext.len()
            )));
        }
        if !self.network_online {
            return Err(EngineError::Transport(
                "peer transport is paused while the network is offline".to_owned(),
            ));
        }
        let socks5_url = self.socks5_url.clone().ok_or_else(|| {
            EngineError::Transport("Tor SOCKS endpoint is not available".to_owned())
        })?;
        let local_endpoint = self.local_peer_endpoint.clone().ok_or_else(|| {
            EngineError::Transport("local onion service is not available".to_owned())
        })?;
        let endpoint = self
            .database
            .contact_peer_endpoint(recipient)?
            .ok_or_else(|| {
                EngineError::Transport(format!(
                    "verified peer endpoint is missing for contact {recipient}"
                ))
            })?;
        if self.crypto_blocked_peers.contains(recipient) {
            return Err(EngineError::Transport(
                "peer MLS session is inconsistent; pair the contact again".to_owned(),
            ));
        }
        endpoint
            .validate(self.clock.now_ms() / 1_000)
            .map_err(|error| {
                EngineError::Transport(format!("peer endpoint validation failed: {error}"))
            })?;
        if endpoint.installation_id != recipient {
            return Err(EngineError::Transport(
                "peer endpoint does not belong to the requested contact".to_owned(),
            ));
        }

        if let PeerDeliveryTag::Message {
            message_id: delivery_message_id,
        } = &delivery
        {
            let now = self.clock.now_ms();
            let ack_deadline = now + 60_000;
            if !self.database.claim_outbound_delivery(
                delivery_message_id,
                ack_deadline,
                ack_deadline,
            )? {
                if self
                    .database
                    .outbound_delivery(delivery_message_id)?
                    .is_some_and(|record| record.state.eq_ignore_ascii_case("IN_FLIGHT"))
                {
                    // A repeated runtime flush observed the same active lease.
                    // The command is already owned by the peer actor; treating
                    // this as a transport failure would requeue it and inflate
                    // exponential backoff without a network attempt.
                    return Ok(());
                }
                return Err(EngineError::Transport(
                    "outbound delivery is no longer queued".to_owned(),
                ));
            }
        }

        let local_endpoint = self.local_endpoint_for_contact(recipient, &local_endpoint)?;
        let command = PeerOutboundCommand {
            peer_public_key: endpoint.identity_public_key.clone(),
            capability_id: endpoint_capability_id(&endpoint),
            capability_secret: self.peer_capability_secret(recipient, &endpoint)?,
            endpoint,
            local_endpoint,
            endpoint_updates: self.database.pending_endpoint_updates(recipient)?,
            message_id,
            conversation_id: conversation_id.to_owned(),
            sequence,
            created_at: self.clock.now_ms() / 1_000,
            ciphertext,
            delivery,
            socks5_url,
        };
        self.peer_transport
            .as_ref()
            .ok_or_else(|| EngineError::Transport("peer listener is not running".to_owned()))?
            .try_send(command)
    }

    pub(super) fn queue_endpoint_update_probes(&mut self) -> EngineResult<()> {
        if !self.network_online {
            return Ok(());
        }
        let Some(socks5_url) = self.socks5_url.clone() else {
            return Ok(());
        };
        let Some(local_endpoint) = self.local_peer_endpoint.clone() else {
            return Ok(());
        };
        let Some(transport) = self.peer_transport.clone() else {
            return Ok(());
        };
        let contacts = self.list_contacts()?;
        let now = Instant::now();
        for contact in &contacts {
            if self
                .database
                .contact_peer_endpoint(&contact.installation_id)?
                .is_some()
            {
                self.probe_coordinator
                    .ensure(ProbeKey::contact(contact.installation_id.clone()), now);
            }
        }
        let due_contacts: HashSet<String> = self
            .probe_coordinator
            .begin_due(now)
            .into_iter()
            .filter_map(|key| key.target_id)
            .collect();
        for contact in contacts {
            if !due_contacts.contains(&contact.installation_id) {
                continue;
            }
            self.pending_engine_events.push(EngineEvent::Log {
                log: EngineLogEvent {
                    level: "debug".to_owned(),
                    message: format!(
                        "contact_probe_started contact_id_hash={} source=peer_scheduler",
                        pseudonymous_target_id(&contact.installation_id)
                    ),
                },
            });
            let updates = self
                .database
                .pending_endpoint_updates(&contact.installation_id)?;
            let Some(endpoint) = self
                .database
                .contact_peer_endpoint(&contact.installation_id)?
            else {
                continue;
            };
            let probe_id = uuid::Uuid::new_v4();
            let local_endpoint_for_contact =
                self.local_endpoint_for_contact(&contact.installation_id, &local_endpoint)?;
            transport.try_send(PeerOutboundCommand {
                peer_public_key: endpoint.identity_public_key.clone(),
                capability_id: endpoint_capability_id(&endpoint),
                capability_secret: self
                    .peer_capability_secret(&contact.installation_id, &endpoint)?,
                endpoint,
                local_endpoint: local_endpoint_for_contact,
                endpoint_updates: updates,
                message_id: probe_id,
                conversation_id: contact.installation_id,
                sequence: stable_message_sequence(probe_id),
                created_at: self.clock.now_ms() / 1_000,
                ciphertext: Vec::new(),
                // Endpoint updates are sent by the same command, but the
                // delivery itself must remain a probe so a successful Ping
                // reports peer reachability instead of an endpoint-only ACK.
                delivery: PeerDeliveryTag::Probe,
                socks5_url: socks5_url.clone(),
            })?;
        }
        Ok(())
    }

    pub(super) fn queue_presence_heartbeats(&mut self) -> EngineResult<()> {
        if !self.network_online || self.socks5_url.is_none() || self.local_peer_endpoint.is_none() {
            return Ok(());
        }
        let online = self.app_foreground && !self.background_restricted;
        let contacts = self.list_contacts()?;
        let now = Instant::now();
        for contact in &contacts {
            self.probe_coordinator.ensure(
                ProbeKey::contact_presence(contact.installation_id.clone()),
                now,
            );
        }
        let due: HashSet<String> = self
            .probe_coordinator
            .begin_due(now)
            .into_iter()
            .filter_map(|key| match key.kind {
                ProbeKind::ContactPresence => key.target_id,
                _ => None,
            })
            .collect();
        for contact in contacts {
            if due.contains(&contact.installation_id) {
                let _ = self.queue_peer_presence(&contact.installation_id, online);
            }
        }
        Ok(())
    }

    pub(super) fn queue_peer_probe(&mut self, recipient: &str) -> EngineResult<()> {
        if !self.network_online {
            return Ok(());
        }
        let Some(socks5_url) = self.socks5_url.clone() else {
            return Ok(());
        };
        let Some(local_endpoint) = self.local_peer_endpoint.clone() else {
            return Ok(());
        };
        let Some(endpoint) = self.database.contact_peer_endpoint(recipient)? else {
            return Ok(());
        };
        let probe_id = uuid::Uuid::new_v4();
        let local_endpoint = self.local_endpoint_for_contact(recipient, &local_endpoint)?;
        let command = PeerOutboundCommand {
            peer_public_key: endpoint.identity_public_key.clone(),
            capability_id: endpoint_capability_id(&endpoint),
            capability_secret: self.peer_capability_secret(recipient, &endpoint)?,
            endpoint,
            local_endpoint,
            endpoint_updates: self.database.pending_endpoint_updates(recipient)?,
            message_id: probe_id,
            conversation_id: recipient.to_owned(),
            sequence: stable_message_sequence(probe_id),
            created_at: self.clock.now_ms() / 1_000,
            ciphertext: Vec::new(),
            delivery: PeerDeliveryTag::Probe,
            socks5_url,
        };
        self.peer_transport
            .as_ref()
            .ok_or_else(|| EngineError::Transport("peer listener is not running".to_owned()))?
            .try_send(command)
    }

    pub(super) fn queue_peer_presence(
        &mut self,
        recipient: &str,
        online: bool,
    ) -> EngineResult<()> {
        self.queue_peer_control(recipient, PeerDeliveryTag::Presence { online })
    }

    pub(super) fn queue_peer_typing(&mut self, recipient: &str, typing: bool) -> EngineResult<()> {
        self.queue_peer_control(recipient, PeerDeliveryTag::Typing { typing })
    }

    pub(super) fn queue_peer_conversation_focus(
        &mut self,
        recipient: &str,
        focused: bool,
    ) -> EngineResult<()> {
        self.queue_peer_control(recipient, PeerDeliveryTag::ConversationFocus { focused })
    }

    fn queue_peer_control(
        &mut self,
        recipient: &str,
        delivery: PeerDeliveryTag,
    ) -> EngineResult<()> {
        if !self.network_online {
            return Ok(());
        }
        let Some(socks5_url) = self.socks5_url.clone() else {
            return Ok(());
        };
        let Some(local_endpoint) = self.local_peer_endpoint.clone() else {
            return Ok(());
        };
        let Some(endpoint) = self.database.contact_peer_endpoint(recipient)? else {
            return Ok(());
        };
        let control_id = uuid::Uuid::new_v4();
        let local_endpoint = self.local_endpoint_for_contact(recipient, &local_endpoint)?;
        let command = PeerOutboundCommand {
            peer_public_key: endpoint.identity_public_key.clone(),
            capability_id: endpoint_capability_id(&endpoint),
            capability_secret: self.peer_capability_secret(recipient, &endpoint)?,
            endpoint,
            local_endpoint,
            endpoint_updates: self.database.pending_endpoint_updates(recipient)?,
            message_id: control_id,
            conversation_id: recipient.to_owned(),
            sequence: stable_message_sequence(control_id),
            created_at: self.clock.now_ms() / 1_000,
            ciphertext: Vec::new(),
            delivery,
            socks5_url,
        };
        self.peer_transport
            .as_ref()
            .ok_or_else(|| EngineError::Transport("peer listener is not running".to_owned()))?
            .try_send(command)
    }
}
