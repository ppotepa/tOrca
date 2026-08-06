use super::*;

impl ClientEngineActor {
    pub(crate) fn prepare_pairing_response_payload(
        &mut self,
        effect: &torchat_runtime::PairingSendEffect,
    ) -> EngineResult<Option<(String, String)>> {
        let Some(stored) = self
            .database
            .pairing_response_retry_record(&effect.pairing_id, self.clock.now_ms() / 1_000)?
        else {
            return Ok(None);
        };
        let next_attempt_at = self.clock.now_ms() + pairing_retry_backoff_ms(stored.attempt_count);
        if !self.database.claim_pairing_response_attempt(
            &effect.pairing_id,
            next_attempt_at,
            None,
        )? {
            return Ok(None);
        }
        let ciphertext = encode_pairing_response_payload(effect, &stored)?;
        Ok(Some((stored.recipient_installation_id, ciphertext)))
    }

    pub(crate) fn queue_welcome_applied(
        &mut self,
        recipient_installation_id: &str,
        invite_id: &str,
    ) -> EngineResult<()> {
        let profile = self.runtime_profile()?;
        let nickname = protocol_nickname(&self.identity.installation_id(), &profile.nickname);
        let payload = RelayPayloadV1::welcome_applied(
            &self.identity,
            &nickname,
            recipient_installation_id.to_owned(),
            invite_id.to_owned(),
        )
        .encode()
        .map_err(EngineError::InvalidCommand)?;
        self.queue_relay_envelope(uuid::Uuid::new_v4(), recipient_installation_id, &payload)
    }

    pub(crate) fn build_contact_invite(
        &mut self,
        recipient_installation_id: Option<String>,
    ) -> EngineResult<String> {
        let profile = self.runtime_profile()?;
        let nickname = protocol_nickname(&self.identity.installation_id(), &profile.nickname);
        let invite_id = uuid::Uuid::new_v4().to_string();
        let expires_at = self.clock.now_ms() / 1_000 + 15 * 60;
        let member = self.fresh_mls_member()?;
        let key_package = member
            .key_package()
            .map_err(|error| EngineError::Storage(format!("create MLS key package: {error}")))?;
        let snapshot = member
            .snapshot()
            .map_err(|error| EngineError::Storage(format!("snapshot invite MLS state: {error}")))?;
        let payload = self
            .identity
            .contact_invite_payload(
                Some(nickname),
                recipient_installation_id.clone(),
                URL_SAFE_NO_PAD.encode(key_package),
                invite_id.clone(),
                expires_at as u64,
            )
            .map_err(|error| EngineError::Serialization(error.to_string()))?;
        let mut invite = ContactInvite::parse(&payload).map_err(EngineError::InvalidCommand)?;
        let local_peer_endpoint = self.local_peer_endpoint.clone().ok_or_else(|| {
            EngineError::Transport(
                "peer endpoint is not ready; wait for onion service before creating a pairing code"
                    .to_owned(),
            )
        })?;
        let local_capability_id = uuid::Uuid::new_v4().simple().to_string()[..16].to_owned();
        let local_capability_secret = uuid::Uuid::new_v4().as_bytes().to_vec();
        invite.peer_endpoint =
            Some(self.endpoint_with_capability(&local_peer_endpoint, &local_capability_id));
        invite.peer_capability_id = Some(local_capability_id.clone());
        invite.peer_capability_secret = Some(URL_SAFE_NO_PAD.encode(&local_capability_secret));
        invite
            .sign(&self.identity)
            .map_err(|error| EngineError::Serialization(error.to_string()))?;
        let encoded = serde_json::to_string(&invite).map_err(EngineError::from)?;
        self.database
            .delete_expired_pending_local_invite_mls(self.clock.now_ms() / 1_000)?;
        self.database
            .put_pending_local_invite_mls(&PendingLocalInviteMlsRecord {
                invite_id,
                recipient_installation_id,
                snapshot,
                local_capability_id,
                local_capability_secret,
                expires_at,
            })?;
        Ok(encoded)
    }

    pub(crate) fn retry_pending_welcomes(&mut self) -> EngineResult<()> {
        let now_ms = self.clock.now_ms();
        let now_secs = now_ms / 1_000;
        self.database.delete_expired_pending_welcomes(now_secs)?;
        self.pending_welcomes
            .retain(|_, pending| pending.expires_at >= now_secs);
        for pending in self.database.due_pending_welcomes(now_ms, now_secs)? {
            let next_attempt_at = now_ms + pairing_retry_backoff_ms(pending.attempt_count);
            if !self.database.claim_pending_welcome_attempt(
                &pending.invite_id,
                next_attempt_at,
                None,
                now_secs,
            )? {
                continue;
            }
            let envelope_id = uuid::Uuid::parse_str(&pending.invite_id)
                .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
            let ciphertext = String::from_utf8(pending.payload.clone()).map_err(|error| {
                EngineError::Storage(format!("stored MLS Welcome is not UTF-8: {error}"))
            })?;
            if let Err(error) = self.queue_relay_envelope(
                envelope_id,
                &pending.recipient_installation_id,
                &ciphertext,
            ) {
                self.database.record_pending_welcome_error(
                    &pending.invite_id,
                    &format!("{}: {error}", super::retry_error_code(&error.to_string())),
                )?;
                self.pending_engine_events.push(EngineEvent::Log {
                    log: EngineLogEvent {
                        level: "warn".to_owned(),
                        message: format!(
                            "pending welcome retry failed invite_id={} error={error}",
                            pending.invite_id
                        ),
                    },
                });
            }
        }
        Ok(())
    }

    pub(crate) fn accept_invite(
        &mut self,
        invite_payload: &str,
    ) -> EngineResult<Vec<torchat_runtime::RuntimeEvent>> {
        let invite =
            ContactInvite::parse(invite_payload.trim()).map_err(EngineError::InvalidCommand)?;
        if invite.installation_id == self.identity.installation_id() {
            return Err(EngineError::InvalidCommand(
                "cannot accept self invite".to_owned(),
            ));
        }
        let peer_endpoint = invite.peer_endpoint.clone();
        let envelope_id = uuid::Uuid::parse_str(&invite.invite_id)
            .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
        if self.database.invite_used(&invite.invite_id)? {
            let pending = self
                .pending_welcomes
                .get(&invite.invite_id)
                .cloned()
                .or_else(|| {
                    self.database
                        .pending_welcome(&invite.invite_id)
                        .ok()
                        .flatten()
                });
            if let Some(pending) = pending {
                self.pending_welcomes
                    .insert(invite.invite_id.clone(), pending.clone());
                let ciphertext = String::from_utf8(pending.payload.clone()).map_err(|error| {
                    EngineError::Storage(format!("stored MLS Welcome is not UTF-8: {error}"))
                })?;
                if let Err(error) = self.queue_relay_envelope(
                    envelope_id,
                    &pending.recipient_installation_id,
                    &ciphertext,
                ) {
                    self.database.record_pending_welcome_error(
                        &invite.invite_id,
                        &format!("{}: {error}", super::retry_error_code(&error.to_string())),
                    )?;
                    self.pending_engine_events.push(EngineEvent::Log {
                        log: EngineLogEvent {
                            level: "warn".to_owned(),
                            message: format!(
                                "welcome resend enqueue deferred invite_id={} error={error}",
                                invite.invite_id
                            ),
                        },
                    });
                }
            } else {
                self.pending_engine_events.push(EngineEvent::Log {
                    log: EngineLogEvent {
                        level: "warn".to_owned(),
                        message: format!(
                            "duplicate invite has no pending welcome invite_id={}",
                            invite.invite_id
                        ),
                    },
                });
            }
            return Ok(Vec::new());
        }
        if self
            .list_contacts()?
            .iter()
            .any(|contact| contact.installation_id == invite.installation_id && !contact.blocked)
        {
            return Err(EngineError::InvalidCommand(
                "contact already exists; remove it before pairing again".to_owned(),
            ));
        }

        let card = contact_card_from_invite(&invite);
        let member = self.fresh_mls_member()?;
        let mut conversation = member
            .create_conversation()
            .map_err(EngineError::InvalidCommand)?;
        let key_package = URL_SAFE_NO_PAD.decode(invite.key_package).map_err(|_| {
            EngineError::InvalidCommand("invalid contact invite key package".to_owned())
        })?;
        let (welcome, tree) = conversation
            .invite(&key_package)
            .map_err(EngineError::InvalidCommand)?;
        let profile = self.runtime_profile()?;
        let protocol_nickname =
            protocol_nickname(&self.identity.installation_id(), &profile.nickname);
        let _ = self
            .database
            .ensure_contact_endpoint_capability(&card.installation_id)?;
        let (local_capability_id, local_capability_secret) =
            self.local_capability_credentials(&card.installation_id)?;
        let welcome_endpoint = self
            .local_peer_endpoint
            .clone()
            .map(|endpoint| self.endpoint_with_capability(&endpoint, &local_capability_id));
        let ciphertext = RelayPayloadV1::welcome_with_endpoint(
            &self.identity,
            &protocol_nickname,
            card.installation_id.clone(),
            invite.invite_id.clone(),
            &welcome,
            &tree,
            welcome_endpoint,
            Some(local_capability_id),
            Some(URL_SAFE_NO_PAD.encode(local_capability_secret)),
        )
        .encode()
        .map_err(EngineError::InvalidCommand)?;
        let pending = PendingWelcomeRecord {
            invite_id: invite.invite_id.clone(),
            recipient_installation_id: card.installation_id.clone(),
            payload: ciphertext.clone().into_bytes(),
            expires_at: invite.expires_at as i64,
            attempt_count: 0,
            next_attempt_at: 0,
            last_error: None,
        };

        let mut runtime_events = self.commit_contact_with_conversation(
            card.clone(),
            conversation,
            None,
            Some(&invite.invite_id),
            Some(&pending),
            None,
        )?;
        if let Some(peer_endpoint) = peer_endpoint {
            if let (Some(capability_id), Some(secret)) = (
                invite.peer_capability_id.as_deref(),
                invite.peer_capability_secret.as_deref(),
            ) {
                let secret = URL_SAFE_NO_PAD.decode(secret).map_err(|_| {
                    EngineError::InvalidCommand("invalid invite capability secret".to_owned())
                })?;
                self.database.put_peer_endpoint_capability(
                    &card.installation_id,
                    capability_id,
                    &secret,
                    peer_endpoint.sequence,
                    self.clock.now_ms() / 1_000,
                    peer_endpoint.expires_at,
                )?;
            }
            runtime_events.extend(self.apply_peer_endpoint(peer_endpoint)?);
        }
        self.pending_welcomes
            .insert(invite.invite_id.clone(), pending.clone());

        if let Err(error) =
            self.queue_relay_envelope(envelope_id, &card.installation_id, &ciphertext)
        {
            self.database
                .record_pending_welcome_error(&invite.invite_id, &error.to_string())?;
        }
        Ok(runtime_events)
    }

    pub(crate) fn apply_pairing_peer_outcome(
        &mut self,
        pairing_id: &str,
        outcome: PairingPeerOutcome,
    ) -> EngineResult<Vec<torchat_runtime::RuntimeEvent>> {
        let (_, runtime_events) =
            self.with_runtime(|runtime| runtime.apply_pairing_peer_outcome(pairing_id, outcome))?;
        Ok(runtime_events)
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn commit_contact_with_conversation(
        &mut self,
        card: torchat_core::relay::ContactCard,
        conversation: DirectConversation,
        pairing_invite_id: Option<&str>,
        consume_invite_id: Option<&str>,
        pending_welcome: Option<&PendingWelcomeRecord>,
        remove_pending_local_invite_id: Option<&str>,
    ) -> EngineResult<Vec<torchat_runtime::RuntimeEvent>> {
        let conversation_snapshot = conversation
            .snapshot()
            .map_err(|error| EngineError::Storage(error.to_string()))?;
        let boundary_at = self.clock.now_ms();
        let (_result, mut runtime_events): (WelcomeAcceptedResult, _) =
            self.with_runtime(|runtime| {
                if let Some(invite_id) = consume_invite_id
                    && !runtime.storage_mut().consume_invite(invite_id)?
                {
                    return Err(RuntimeError::Conflict(
                        "contact invite was already consumed".to_owned(),
                    ));
                }
                let result = runtime.welcome_accepted(
                    contact_record_from_card(&card, true),
                    true,
                    pairing_invite_id.map(str::to_owned),
                )?;
                runtime.storage_mut().apply_relationship_transition(
                    crate::storage::runtime_storage::RelationshipTransition::BeginVerified {
                        installation_id: card.installation_id.clone(),
                        boundary_at,
                    },
                )?;
                runtime.storage_mut().put_conversation_mls_snapshot(
                    &result.conversation.id,
                    &conversation_snapshot,
                )?;
                if let Some(pending) = pending_welcome {
                    runtime.storage_mut().put_pending_welcome(pending)?;
                }
                if let Some(invite_id) = remove_pending_local_invite_id {
                    runtime
                        .storage_mut()
                        .remove_pending_local_invite_mls(invite_id)?;
                }
                Ok(result)
            })?;
        self.conversations
            .insert(card.installation_id.clone(), conversation);
        self.crypto_blocked_peers.remove(&card.installation_id);
        runtime_events.extend(self.apply_pending_peer_endpoint(&card.installation_id)?);
        // A capability or message frame may have arrived through the relay
        // while Welcome was still being committed. Replay those frames now
        // that the MLS conversation is available.
        runtime_events.extend(self.drain_pending_pre_welcome(&card.installation_id)?);
        // Fresh pairings carry both endpoint capabilities in the signed
        // invite/Welcome. Sending a first capability offer here would create
        // a circular dependency: that offer itself requires the remote
        // capability to open the first P2P connection.
        Ok(runtime_events)
    }
}
