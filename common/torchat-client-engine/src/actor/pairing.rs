use super::*;

impl ClientEngineActor {
    pub(super) fn prepare_pairing_response_payload(
        &mut self,
        effect: &torchat_client_runtime::PairingSendEffect,
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

    pub(super) fn send_contact_confirmation(
        &mut self,
        record: PendingContactConfirmationRecord,
    ) -> EngineResult<()> {
        self.enqueue_contact_confirmation(&record);
        Ok(())
    }

    pub(super) fn queue_welcome_applied(
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
        self.queue_relay_envelope(
            uuid::Uuid::new_v4(),
            recipient_installation_id,
            &payload,
            PendingRelayDelivery::Ephemeral {
                installation_id: recipient_installation_id.to_owned(),
                delivery_id: None,
            },
        )
    }

    pub(super) fn acknowledge_pairing_request(&mut self, pairing_id: &str) -> EngineResult<()> {
        self.enqueue_pairing_acknowledgement(pairing_id);
        Ok(())
    }

    pub(super) fn build_contact_invite(
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
        // Pairing must remain possible while the local onion service is still
        // starting (or when Android is in a power-saving mode). The signed
        // invite can omit the endpoint; the contact is then relay-only until
        // a later endpoint exchange succeeds.
        invite.peer_endpoint = self.local_peer_endpoint.clone();
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
                expires_at,
            })?;
        Ok(encoded)
    }

    pub(super) fn retry_pending_welcomes(&mut self) -> EngineResult<()> {
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
                PendingRelayDelivery::Welcome {
                    invite_id: pending.invite_id.clone(),
                },
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

    pub(super) fn retry_pending_contact_confirmations(&mut self) -> EngineResult<()> {
        if self.connection_state != ConnectionState::Connected {
            return Ok(());
        }
        for record in self
            .database
            .due_pending_contact_confirmations(self.clock.now_ms())?
        {
            let next_attempt_at =
                self.clock.now_ms() + pairing_retry_backoff_ms(record.attempt_count);
            if !self.database.claim_pending_contact_confirmation_attempt(
                &record.pairing_id,
                next_attempt_at,
                None,
            )? {
                continue;
            }
            if let Err(error) = self.send_contact_confirmation(record.clone()) {
                self.database.record_pending_contact_confirmation_error(
                    &record.pairing_id,
                    &format!("{}: {error}", super::retry_error_code(&error.to_string())),
                )?;
                self.pending_engine_events.push(EngineEvent::Log {
                    log: EngineLogEvent {
                        level: "warn".to_owned(),
                        message: format!(
                            "contact confirmation retry failed pairing_id={} error={error}",
                            record.pairing_id
                        ),
                    },
                });
            } else {
                // Completion is performed by the relay-control worker after the
                // HTTP effect succeeds; keep the durable row until then.
            }
        }
        Ok(())
    }

    pub(super) fn retry_pending_pairing_acknowledgements(&mut self) -> EngineResult<()> {
        if self.connection_state != ConnectionState::Connected {
            return Ok(());
        }
        for (pairing_id, attempt_count) in self
            .database
            .due_pending_pairing_acknowledgements(self.clock.now_ms())?
        {
            let next_attempt_at = self.clock.now_ms() + pairing_retry_backoff_ms(attempt_count);
            if !self
                .database
                .claim_pending_pairing_acknowledgement_attempt(&pairing_id, next_attempt_at, None)?
            {
                continue;
            }
            if let Err(error) = self.acknowledge_pairing_request(&pairing_id) {
                self.pending_engine_events.push(EngineEvent::Log {
                    log: EngineLogEvent {
                        level: "warn".to_owned(),
                        message: format!(
                            "pairing acknowledgement retry failed pairing_id={} error={error}",
                            pairing_id
                        ),
                    },
                });
            }
        }
        Ok(())
    }

    pub(super) fn accept_invite(
        &mut self,
        invite_payload: &str,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
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
                    PendingRelayDelivery::Welcome {
                        invite_id: pending.invite_id,
                    },
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
        let ciphertext = RelayPayloadV1::welcome_with_endpoint(
            &self.identity,
            &protocol_nickname,
            card.installation_id.clone(),
            invite.invite_id.clone(),
            &welcome,
            &tree,
            self.local_peer_endpoint.clone(),
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
            runtime_events.extend(self.apply_peer_endpoint(peer_endpoint)?);
        }
        self.pending_welcomes
            .insert(invite.invite_id.clone(), pending.clone());

        if let Err(error) = self.queue_relay_envelope(
            envelope_id,
            &card.installation_id,
            &ciphertext,
            PendingRelayDelivery::Welcome {
                invite_id: invite.invite_id.clone(),
            },
        ) {
            self.database
                .record_pending_welcome_error(&invite.invite_id, &error.to_string())?;
        }
        Ok(runtime_events)
    }

    pub(super) fn apply_pairing_peer_outcome(
        &mut self,
        pairing_id: &str,
        outcome: PairingPeerOutcome,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        let (_, runtime_events) =
            self.with_runtime(|runtime| runtime.apply_pairing_peer_outcome(pairing_id, outcome))?;
        Ok(runtime_events)
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn commit_contact_with_conversation(
        &mut self,
        card: torchat_core::relay::ContactCard,
        conversation: DirectConversation,
        pairing_invite_id: Option<&str>,
        consume_invite_id: Option<&str>,
        pending_welcome: Option<&PendingWelcomeRecord>,
        remove_pending_local_invite_id: Option<&str>,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        let conversation_snapshot = conversation
            .snapshot()
            .map_err(|error| EngineError::Storage(error.to_string()))?;
        let boundary_at = self.clock.now_ms();
        let (result, mut runtime_events): (WelcomeAcceptedResult, _) =
            self.with_runtime(|runtime| {
                if let Some(invite_id) = consume_invite_id
                    && !runtime.storage_mut().consume_invite(invite_id)?
                {
                    return Err(RuntimeError::Conflict(
                        "contact invite was already consumed".to_owned(),
                    ));
                }
                let result = runtime.welcome_accepted(
                    contact_record_from_card(&card, false),
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
        if let Some(confirm) = result.confirm_contact {
            self.database.put_pending_contact_confirmation(
                &confirm.pairing_id,
                &confirm.peer_installation_id,
                &confirm.capability,
            )?;
            // The canonical SQL/MLS transition is already committed. Relay
            // confirmation is an external side effect and must not roll back
            // or desynchronize in-memory MLS state when the network is down.
            if let Err(error) = self.send_contact_confirmation(PendingContactConfirmationRecord {
                pairing_id: confirm.pairing_id.clone(),
                peer_installation_id: confirm.peer_installation_id.clone(),
                capability: confirm.capability.clone(),
                attempt_count: 0,
                next_attempt_at: 0,
                last_error: None,
            }) {
                self.database.record_pending_contact_confirmation_error(
                    &confirm.pairing_id,
                    &format!("{}: {error}", super::retry_error_code(&error.to_string())),
                )?;
                self.pending_engine_events.push(EngineEvent::Log {
                    log: EngineLogEvent {
                        level: "warn".to_owned(),
                        message: format!(
                            "contact confirmation enqueue failed pairing_id={} error={error}",
                            confirm.pairing_id
                        ),
                    },
                });
            }
        }
        let _ = self.queue_relay_endpoint_bootstraps();
        // Exchange the per-contact endpoint secret only after the MLS
        // conversation has been committed. The offer is MLS-encrypted.
        if let Err(error) = self.send_capability_offer(&card.installation_id) {
            self.pending_engine_events.push(EngineEvent::Log {
                log: EngineLogEvent {
                    level: "warn".to_owned(),
                    message: format!(
                        "capability offer deferred contact={} error={error}",
                        card.installation_id
                    ),
                },
            });
        }
        Ok(runtime_events)
    }
}
