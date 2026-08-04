use super::*;

impl ClientEngineActor {
    pub(super) fn handle_command(
        &mut self,
        command: EngineCommand,
        idempotency: Option<&IdempotencyCommitContext>,
    ) -> EngineResult<(
        ResponsePayload,
        Vec<torchat_client_runtime::RuntimeEvent>,
        Option<ConnectionSnapshot>,
    )> {
        match command {
            EngineCommand::Bootstrap => {
                let (bootstrapped, mut runtime_events) = self.with_runtime_idempotent(
                    idempotency,
                    |runtime| runtime.bootstrap_runtime(),
                    |bootstrapped| json_response(bootstrapped),
                )?;
                runtime_events.push(transport_status_event(
                    torchat_client_runtime::TransportComponent::Engine,
                    torchat_client_runtime::TransportProbeState::Ready,
                    "engine and local storage ready",
                    None,
                    None,
                    0,
                    None,
                    self.connection_generation,
                    None,
                    self.clock.now_ms(),
                ));
                Ok((json_response(bootstrapped)?, runtime_events, None))
            }
            EngineCommand::GetIdentity => {
                Ok((json_response(self.runtime_identity()?)?, Vec::new(), None))
            }
            EngineCommand::GetProfile => {
                Ok((json_response(self.runtime_profile()?)?, Vec::new(), None))
            }
            EngineCommand::GetStartupReadiness => Ok((
                json_response(StartupReadinessSnapshot {
                    engine_ready: true,
                    local_data_ready: true,
                    tor_ready: self.socks5_url.is_some(),
                    peer_listener_ready: self.peer_transport.is_some(),
                    onion_service_ready: self.local_peer_endpoint.is_some(),
                    generation: self.connection_generation,
                    detail: self.tor_status.detail.clone(),
                })?,
                Vec::new(),
                None,
            )),
            EngineCommand::GetApplicationSnapshot => Ok((
                json_response(self.application_snapshot()?)?,
                Vec::new(),
                None,
            )),
            EngineCommand::ListPairings => {
                let ((inbox, outbox), runtime_events) =
                    self.with_runtime(|runtime| runtime.local_pairing_lists())?;
                Ok((
                    json_response(crate::PairingList { inbox, outbox })?,
                    runtime_events,
                    None,
                ))
            }
            EngineCommand::PairingOutbox => {
                let (result, runtime_events) =
                    self.with_runtime(|runtime| runtime.pairing_outbox())?;
                Ok((json_response(result)?, runtime_events, None))
            }
            EngineCommand::PairingInbox => {
                let (inbox, _) = self.with_runtime(|runtime| runtime.local_pairing_lists())?;
                Ok((json_response(inbox)?, Vec::new(), None))
            }
            EngineCommand::ListContacts => {
                Ok((json_response(self.list_contacts()?)?, Vec::new(), None))
            }
            EngineCommand::ListConversations => {
                Ok((json_response(self.list_conversations()?)?, Vec::new(), None))
            }
            EngineCommand::ListMessages { conversation_id } => Ok((
                json_response(self.list_messages(&conversation_id)?)?,
                Vec::new(),
                None,
            )),
            EngineCommand::GetPeerEndpoint => Ok((
                json_response(self.local_peer_endpoint.clone())?,
                Vec::new(),
                None,
            )),
            EngineCommand::RetryPeerConnection { installation_id } => {
                if self
                    .database
                    .contact_peer_endpoint(&installation_id)?
                    .is_some()
                {
                    // Retrying a peer connection must perform an actual
                    // authenticated probe. Expediting the message queue alone
                    // leaves the contact displayed as offline until a new
                    // message happens to open a session.
                    let _ = self.queue_peer_probe(&installation_id);
                    self.database.expedite_peer_deliveries(&installation_id)?;
                    self.flush_pending_send_effects()?;
                } else {
                }
                Ok((ResponsePayload::Empty, Vec::new(), None))
            }
            EngineCommand::RotatePeerEndpoint => {
                self.expected_onion_generation = self.expected_onion_generation.saturating_add(1);
                self.pending_engine_events
                    .push(EngineEvent::PlatformAction {
                        action: PlatformAction::RotateOnionService {
                            generation: self.expected_onion_generation,
                        },
                    });
                Ok((ResponsePayload::Empty, Vec::new(), None))
            }
            EngineCommand::GetContactEndpointCapability { installation_id } => {
                let capability_id = self
                    .database
                    .ensure_contact_endpoint_capability(&installation_id)?;
                let (_, _, sequence, status) = self
                    .database
                    .contact_endpoint_capability(&installation_id)?
                    .ok_or_else(|| EngineError::Storage("capability was not persisted".into()))?;
                Ok((
                    json_response(ContactCapabilityStatusResponse {
                        contact_id: installation_id,
                        capability_id,
                        sequence,
                        status,
                    })?,
                    Vec::new(),
                    None,
                ))
            }
            EngineCommand::RotateContactEndpointCapability { installation_id } => {
                self.database
                    .revoke_contact_endpoint_capability(&installation_id)?;
                let capability_id = self
                    .database
                    .ensure_contact_endpoint_capability(&installation_id)?;
                let _ = self.send_capability_offer(&installation_id);
                let (_, _, sequence, status) = self
                    .database
                    .contact_endpoint_capability(&installation_id)?
                    .ok_or_else(|| EngineError::Storage("capability was not persisted".into()))?;
                let events = vec![
                    torchat_client_runtime::RuntimeEvent::ContactCapabilityChanged {
                        contact_id: installation_id.clone(),
                        capability_id: capability_id.clone(),
                        sequence,
                        status,
                    },
                ];
                Ok((
                    json_response(ContactCapabilityStatusResponse {
                        contact_id: installation_id,
                        capability_id,
                        sequence,
                        status,
                    })?,
                    events,
                    None,
                ))
            }
            EngineCommand::RevokeContactEndpointCapability { installation_id } => {
                if let Some((capability_id, _, sequence, _)) = self
                    .database
                    .contact_endpoint_capability(&installation_id)?
                {
                    let _ = self.send_ephemeral_payload(
                        &installation_id,
                        ApplicationPayloadV1::CapabilityRevoked {
                            version: torchat_core::PROTOCOL_VERSION,
                            capability_id,
                            sequence,
                            revoked_at: self.clock.now_ms() / 1_000,
                        },
                    );
                }
                self.database
                    .revoke_contact_endpoint_capability(&installation_id)?;
                self.database
                    .complete_capability_deliveries_for_contact(&installation_id)?;
                self.active_peer_sessions.remove(&installation_id);
                Ok((
                    ResponsePayload::Empty,
                    vec![
                        torchat_client_runtime::RuntimeEvent::ContactCapabilityChanged {
                            contact_id: installation_id,
                            capability_id: String::new(),
                            sequence: 0,
                            status: torchat_client_runtime::CapabilityStatus::Revoked,
                        },
                    ],
                    None,
                ))
            }
            EngineCommand::SetNickname { nickname } => {
                let (profile, runtime_events) = self.with_runtime_idempotent(
                    idempotency,
                    |runtime| runtime.commit_nickname(nickname),
                    |profile| json_response(profile),
                )?;
                Ok((json_response(profile)?, runtime_events, None))
            }
            EngineCommand::RefreshPairingCode => {
                let code = self.relay.refresh_pairing_code().map_err(runtime_error)?;
                let (value, runtime_events) = self.with_runtime_idempotent(
                    idempotency,
                    |runtime| {
                        runtime.prepare_refresh_pairing_code()?;
                        runtime.commit_pairing_code(code.clone())?;
                        Ok(code.clone())
                    },
                    |value| json_response(value),
                )?;
                Ok((json_response(value)?, runtime_events, None))
            }
            EngineCommand::SubmitPairingCode { code } => {
                let (normalized, mut runtime_events) =
                    self.with_runtime(|runtime| runtime.prepare_submit_pairing_code(code))?;
                let pairing_id = uuid::Uuid::new_v4();
                let invite = self.build_contact_invite(None)?;
                let payload =
                    RelayPayloadV1::pairing_offer(pairing_id.to_string(), String::new(), invite)
                        .encode()
                        .map_err(EngineError::InvalidCommand)?;
                let item = self
                    .relay
                    .submit_pairing_code_with_offer(&normalized, pairing_id, payload)
                    .map_err(runtime_error)?;
                let (value, mut commit_events) = self.with_runtime_idempotent(
                    idempotency,
                    |runtime| runtime.commit_submitted_pairing(item.clone()),
                    |value| json_response(value),
                )?;
                runtime_events.append(&mut commit_events);
                Ok((json_response(value)?, runtime_events, None))
            }
            EngineCommand::AcceptPairing { pairing_id } => {
                let (preparation, mut runtime_events): (PairingPreparation, _) =
                    self.with_runtime(|runtime| runtime.prepare_accept_pairing(&pairing_id))?;
                let invite =
                    self.build_contact_invite(Some(preparation.recipient_installation_id.clone()))?;
                let invite_id = ContactInvite::parse(&invite)
                    .map_err(EngineError::InvalidCommand)?
                    .invite_id;
                let payload = RelayPayloadV1::pairing_offer(
                    pairing_id.clone(),
                    preparation.capability,
                    invite,
                )
                .encode()
                .map_err(EngineError::InvalidCommand)?;
                let (effect, mut commit_events) = self.with_runtime_idempotent(
                    idempotency,
                    |runtime| runtime.commit_accept_pairing(&pairing_id, invite_id, payload),
                    |_| Ok(ResponsePayload::Empty),
                )?;
                self.deliver_send_effect(effect)?;
                runtime_events.append(&mut commit_events);
                Ok((ResponsePayload::Empty, runtime_events, None))
            }
            EngineCommand::RejectPairing { pairing_id } => {
                let (effect, runtime_events) = self.with_runtime_idempotent(
                    idempotency,
                    |runtime| runtime.commit_reject_pairing(&pairing_id),
                    |_| Ok(ResponsePayload::Empty),
                )?;
                self.deliver_send_effect(effect)?;
                Ok((ResponsePayload::Empty, runtime_events, None))
            }
            EngineCommand::CancelPairing { pairing_id } => {
                self.relay
                    .cancel_pairing(&pairing_id)
                    .map_err(runtime_error)?;
                let (_, mut runtime_events) =
                    self.with_runtime(|runtime| runtime.prepare_cancel_pairing(&pairing_id))?;
                let (_, confirm_events) = self.with_runtime_idempotent(
                    idempotency,
                    |runtime| runtime.confirm_pairing_cancelled(&pairing_id),
                    |_| Ok(ResponsePayload::Empty),
                )?;
                runtime_events.extend(confirm_events);
                Ok((ResponsePayload::Empty, runtime_events, None))
            }
            EngineCommand::ArchivePairing { pairing_id } => {
                let (_, runtime_events) = self.with_runtime_idempotent(
                    idempotency,
                    |runtime| runtime.archive_pairing(&pairing_id),
                    |_| json_response(true),
                )?;
                Ok((json_response(true)?, runtime_events, None))
            }
            EngineCommand::VerifyContact { installation_id } => {
                let (_, runtime_events) = self.with_runtime_idempotent(
                    idempotency,
                    |runtime| runtime.verify_contact(&installation_id),
                    |_| json_response(true),
                )?;
                Ok((json_response(true)?, runtime_events, None))
            }
            EngineCommand::UpdateContactSettings {
                installation_id,
                local_alias,
                muted,
                blocked,
                transport_policy,
            } => {
                let (contact, runtime_events) = self.with_runtime_idempotent(
                    idempotency,
                    |runtime| {
                        let mut contact = runtime.update_contact_settings(
                            &installation_id,
                            local_alias,
                            muted,
                            blocked,
                        )?;
                        if let Some(policy) = transport_policy {
                            contact =
                                runtime.set_contact_transport_policy(&installation_id, policy)?;
                        }
                        Ok(contact)
                    },
                    |contact| json_response(contact),
                )?;
                Ok((json_response(contact)?, runtime_events, None))
            }
            EngineCommand::RequestRelationshipRemoval {
                installation_id,
                preserve_history,
            } => {
                let (_, runtime_events) = self.with_runtime_idempotent(
                    idempotency,
                    |runtime| runtime.remove_relationship(&installation_id, preserve_history),
                    |_| Ok(ResponsePayload::Empty),
                )?;
                self.conversations.remove(&installation_id);
                self.crypto_blocked_peers.remove(&installation_id);
                self.active_peer_sessions.remove(&installation_id);
                Ok((ResponsePayload::Empty, runtime_events, None))
            }
            EngineCommand::StartConversation { contact_id } => {
                let (created, runtime_events) = self.with_runtime_idempotent(
                    idempotency,
                    |runtime| runtime.start_conversation(&contact_id),
                    |created| json_response(created),
                )?;
                // Conversation activation also initializes direct reachability.
                // Peer readiness must not depend on both users opening the UI.
                let _ = self.queue_peer_probe(&contact_id);
                Ok((json_response(created)?, runtime_events, None))
            }
            EngineCommand::OpenConversation { conversation_id } => {
                let (_, runtime_events) = self.with_runtime_idempotent(
                    idempotency,
                    |runtime| runtime.open_conversation(conversation_id.clone()),
                    |_| json_response(true),
                )?;
                let _ = self.queue_peer_probe(&conversation_id);
                Ok((json_response(true)?, runtime_events, None))
            }
            EngineCommand::CloseConversation => {
                let (_, runtime_events) = self.with_runtime_idempotent(
                    idempotency,
                    |runtime| {
                        runtime.close_conversation();
                        Ok(())
                    },
                    |_| json_response(true),
                )?;
                Ok((json_response(true)?, runtime_events, None))
            }
            EngineCommand::SendMessage {
                conversation_id,
                body,
                reply_to_message_id,
            } => {
                let (effect, runtime_events) = self.send_message_command(
                    idempotency,
                    &conversation_id,
                    body,
                    reply_to_message_id.as_deref(),
                )?;
                Ok((json_response(effect)?, runtime_events, None))
            }
            EngineCommand::RetryMessage { message_id } => {
                let (effect, runtime_events) = self.with_runtime_idempotent(
                    idempotency,
                    |runtime| runtime.retry_message(&message_id),
                    |_| Ok(ResponsePayload::Empty),
                )?;
                self.deliver_send_effect(effect.into())?;
                Ok((ResponsePayload::Empty, runtime_events, None))
            }
            EngineCommand::RetryDeadLetter { kind, id } => {
                if !self.database.retry_dead_letter(&kind, &id)? {
                    return Err(EngineError::InvalidCommand(
                        "dead-letter record was not found or is not terminal".to_owned(),
                    ));
                }
                Ok((ResponsePayload::Empty, Vec::new(), None))
            }
            EngineCommand::ListDeadLetters => Ok((
                json_response(self.database.dead_letters()?)?,
                Vec::new(),
                None,
            )),
            EngineCommand::DeleteMessageLocal { message_id } => {
                let (_, runtime_events) = self.with_runtime_idempotent(
                    idempotency,
                    |runtime| runtime.delete_message_local(&message_id),
                    |_| Ok(ResponsePayload::Empty),
                )?;
                Ok((ResponsePayload::Empty, runtime_events, None))
            }
            EngineCommand::SetTyping {
                conversation_id,
                typing,
            } => {
                self.queue_peer_typing(&conversation_id, typing)?;
                Ok((ResponsePayload::Empty, Vec::new(), None))
            }
            EngineCommand::SetConversationFocus {
                conversation_id,
                focused,
            } => {
                let (_, runtime_events) = self.with_runtime(|runtime| {
                    runtime.set_conversation_focus(&conversation_id, focused)
                })?;
                self.queue_peer_conversation_focus(&conversation_id, focused)?;
                Ok((ResponsePayload::Empty, runtime_events, None))
            }
            EngineCommand::SetPresence { online } => {
                let peers = self.conversations.keys().cloned().collect::<Vec<_>>();
                for peer in peers {
                    self.queue_peer_presence(&peer, online)?;
                }
                Ok((ResponsePayload::Empty, Vec::new(), None))
            }
            EngineCommand::SendReadReceipts { conversation_id } => {
                let message_ids = self
                    .list_messages(&conversation_id)?
                    .into_iter()
                    .filter(|message| !message.outgoing)
                    .filter_map(|message| uuid::Uuid::parse_str(&message.id).ok())
                    .collect::<Vec<_>>();
                if !message_ids.is_empty() {
                    self.queue_read_receipts(&conversation_id, message_ids)?;
                }
                Ok((ResponsePayload::Empty, Vec::new(), None))
            }
            EngineCommand::Connect => {
                if self.connect_requested && self.connection_state == ConnectionState::Connected {
                    let (connected, runtime_events) =
                        self.with_runtime(|runtime| runtime.connect())?;
                    return Ok((
                        json_response(connected)?,
                        runtime_events,
                        Some(
                            self.connection_snapshot("connect requested; local transport ready"),
                        ),
                    ));
                }
                self.advance_connection_generation();
                // Connect is the local runtime boundary. Never perform an
                // onion HTTP/WebSocket request on the command path: doing so
                // starves profile/storage queries behind Tor's circuit
                // timeout. Pairing opens the rendezvous connection lazily.
                self.connect_requested = true;
                self.connection_state = if self.socks5_url.is_some() {
                    ConnectionState::Connecting
                } else {
                    ConnectionState::WaitingForTor
                };
                let (connected, runtime_events) = self.with_runtime(|runtime| runtime.connect())?;
                self.flush_pending_send_effects()?;
                self.flush_pending_receipt_effects()?;
                Ok((
                    json_response(connected)?,
                    runtime_events,
                    Some(self.connection_snapshot("connect requested")),
                ))
            }
            EngineCommand::PlatformFact { fact } => {
                let runtime_events = self.apply_platform_fact(fact)?;
                Ok((
                    ResponsePayload::Empty,
                    runtime_events,
                    Some(self.connection_snapshot("platform fact applied")),
                ))
            }
            EngineCommand::Shutdown => {
                self.advance_connection_generation();
                self.relay.shutdown();
                self.connection_state = ConnectionState::Stopped;
                Ok((
                    ResponsePayload::Empty,
                    Vec::new(),
                    Some(self.connection_snapshot("shutdown requested")),
                ))
            }
        }
    }
}
