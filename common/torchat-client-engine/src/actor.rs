use std::{
    collections::{HashMap, HashSet},
    mem,
};

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use sha2::{Digest, Sha256};
use tokio::sync::mpsc;
use tokio::time::{Duration, Instant};
use tokio_util::sync::CancellationToken;
use torchat_client_runtime::{
    ClientRuntime, ContactTransportPolicy, MessageSendEffect, MessageTransportOutcome, PairingPeerOutcome,
    PairingPreparation, PairingSendKind, PairingSyncResult, PeerConnectionStatus,
    PeerEndpointStatus, RuntimeClock, RuntimeError, RuntimeIdentity, RuntimeProfile,
    RuntimeSendEffect, RuntimeSession, RuntimeStatusPhase, RuntimeStorage, RuntimeTorStatus,
    RuntimeTransport, SystemRuntimeClock, WelcomeAcceptedResult, contact_card_from_invite,
    contact_record_from_card,
};
use torchat_core::{
    ContactInvite, Identity,
    application::{ApplicationPayloadV1, ApplicationReply},
    mls::{DirectConversation, MlsMember},
    peer_protocol::{
        PEER_VIRTUAL_PORT, PeerAck, PeerAckKind, PeerCiphertextPayload, PeerEndpointBundle,
        PeerEndpointUpdate,
    },
    relay::{RelayEnvelope, RelayPayloadV1},
};

use crate::{
    ClientDatabase, EngineCommand, EngineCommandEnvelope, EngineConfig, EngineError, EngineEvent,
    EngineLogEvent, EngineResult, PlatformAction, PlatformFact,
    event::{
        ConnectionSnapshot, ConnectionState, NotificationRequest, ResponsePayload, ResponseResult,
    },
    peer::{PeerDeliveryTag, PeerOutboundCommand, PeerTransportEvent, PeerTransportHandle},
    relay::{EngineRelay, RelayEvent, SharedRelayActor},
    storage::{
        DeliveryReceiptRecord, InboundEnvelopeStoreResult, PairingResponseRecord,
        PeerEndpointBootstrapRecord, PendingContactConfirmationRecord,
        PendingPeerEndpointInboxRecord, PendingWelcomeRecord, ReceivedEnvelopeRecord,
        RetryDeadline, RetryKind, SqliteRuntimeStorage,
    },
};

#[derive(Clone, Debug)]
enum PendingRelayDelivery {
    PairingResponse { pairing_id: String },
    Welcome { invite_id: String },
    Message { message_id: String },
    Receipt { message_id: String },
    Ephemeral { installation_id: String },
    PeerEndpointBootstrap { installation_id: String, sequence: u64 },
}

pub struct ClientEngineActor {
    pub config: EngineConfig,
    pub database: ClientDatabase,
    pub identity: Identity,
    pub mls_inbox: MlsMember,
    pub conversations: HashMap<String, DirectConversation>,
    pub pending_welcomes: HashMap<String, PendingWelcomeRecord>,
    pending_relay_deliveries: HashMap<uuid::Uuid, PendingRelayDelivery>,
    pending_engine_events: Vec<EngineEvent>,
    active_peer_sessions: HashMap<String, HashSet<uuid::Uuid>>,
    connection_generation: u64,
    app_foreground: bool,
    pub session: RuntimeSession,
    pub clock: SystemRuntimeClock,
    pub connection_state: ConnectionState,
    pub tor_status: RuntimeTorStatus,
    pub socks5_url: Option<String>,
    pub relay: Box<dyn EngineRelay>,
    peer_transport: Option<PeerTransportHandle>,
    local_peer_endpoint: Option<PeerEndpointBundle>,
    expected_onion_generation: u64,
    network_online: bool,
    battery_saver: bool,
    device_idle: bool,
    background_restricted: bool,
    relay_retry_at: Option<Instant>,
    relay_retry_attempt: u32,
}

const RELAY_POLL_INTERVAL: Duration = Duration::from_millis(100);

impl ClientEngineActor {
    pub fn new(config: EngineConfig) -> EngineResult<Self> {
        let identity = identity_from_config(&config)?;
        let mut database = ClientDatabase::open(&config.database_path, &config.database_key)?;
        seed_runtime_identity(&mut database, &identity)?;
        database.delete_expired_pending_welcomes(unix_secs())?;
        let (mls_inbox, conversations, pending_welcomes) =
            load_engine_technical_state(&database, &identity)?;
        let relay_identity = identity_from_config(&config)?;
        let (local_peer_endpoint, stored_onion_generation) =
            database.local_peer_endpoint()?.unzip();
        let initial_socks5_url = config.initial_socks5_url.as_ref().map(ToString::to_string);
        let relay_onion_url = config.relay_onion_url.clone();
        let initial_connection_state = if initial_socks5_url.is_some() {
            ConnectionState::Disconnected
        } else {
            ConnectionState::WaitingForTor
        };
        Ok(Self {
            config,
            database,
            identity,
            mls_inbox,
            conversations,
            pending_welcomes,
            pending_relay_deliveries: HashMap::new(),
            pending_engine_events: Vec::new(),
            active_peer_sessions: HashMap::new(),
            connection_generation: 0,
            app_foreground: true,
            session: RuntimeSession::new(),
            clock: SystemRuntimeClock,
            connection_state: initial_connection_state,
            tor_status: RuntimeTorStatus {
                phase: RuntimeStatusPhase::Starting,
                label: "starting".to_owned(),
                detail: "engine initialized".to_owned(),
                progress: None,
                latency_ms: None,
                retry_attempt: 0,
            },
            socks5_url: initial_socks5_url.clone(),
            relay: Box::new(SharedRelayActor::new(
                relay_onion_url,
                initial_socks5_url,
                relay_identity,
            )),
            peer_transport: None,
            local_peer_endpoint,
            expected_onion_generation: stored_onion_generation.unwrap_or(0).saturating_add(1),
            network_online: true,
            battery_saver: false,
            device_idle: false,
            background_restricted: false,
            relay_retry_at: None,
            relay_retry_attempt: 0,
        })
    }

    pub async fn run(
        mut self,
        mut commands: mpsc::Receiver<EngineCommandEnvelope>,
        events: mpsc::Sender<EngineEvent>,
        shutdown: CancellationToken,
    ) -> EngineResult<()> {
        let (peer_transport, mut peer_events) =
            PeerTransportHandle::bind(self.identity.private_key_bytes()).await?;
        if let Some(endpoint) = self.local_peer_endpoint.clone() {
            peer_transport.set_local_endpoint(endpoint);
        }
        for contact in self.list_contacts()? {
            if let Some(endpoint) = self
                .database
                .contact_peer_endpoint(&contact.installation_id)?
            {
                peer_transport.authorize_contact(&endpoint);
            }
        }
        let local_port = peer_transport.local_port();
        self.peer_transport = Some(peer_transport);
        for event in self.recover_pending_inbound_peer_envelopes()? {
            let _ = events.send(EngineEvent::Runtime { event }).await;
        }
        let _ = events
            .send(EngineEvent::PlatformAction {
                action: PlatformAction::ConfigureOnionService {
                    local_port,
                    virtual_port: PEER_VIRTUAL_PORT,
                    generation: self.expected_onion_generation,
                },
            })
            .await;
        let _ = events
            .send(EngineEvent::Connection {
                snapshot: self.connection_snapshot("engine actor initialized"),
            })
            .await;
        let _ = events
            .send(EngineEvent::Log {
                log: EngineLogEvent {
                    level: "info".to_owned(),
                    message: format!("client engine actor started for {:?}", self.config.platform),
                },
            })
            .await;

        loop {
            let relay_poll_interval = if !self.network_online {
                Duration::from_secs(30)
            } else if self.battery_saver || self.device_idle || self.background_restricted {
                Duration::from_secs(5)
            } else {
                RELAY_POLL_INTERVAL
            };
            let relay_poll_at = Instant::now() + relay_poll_interval;
            let retry_deadline = self.next_retry_deadline()?;
            let retry_wakeup_at = self.next_retry_wakeup_at(retry_deadline)?;
            let retry_sleep_deadline =
                retry_wakeup_at.unwrap_or(relay_poll_at + Duration::from_secs(3600));
            let relay_retry_wakeup_at = self
                .relay_retry_at
                .unwrap_or(relay_poll_at + Duration::from_secs(3600));
            tokio::select! {
                _ = shutdown.cancelled() => {
                    self.advance_connection_generation();
                    self.relay.shutdown();
                    self.connection_state = ConnectionState::Stopped;
                    let _ = events.send(EngineEvent::Connection {
                        snapshot: self.connection_snapshot("engine shutdown"),
                    }).await;
                    break;
                }
                _ = tokio::time::sleep_until(relay_poll_at) => {
                    self.drain_relay_events(&events).await;
                }
                _ = tokio::time::sleep_until(relay_retry_wakeup_at), if self.relay_retry_at.is_some() => {
                    self.retry_relay_bootstrap(&events).await;
                }
                _ = tokio::time::sleep_until(retry_sleep_deadline), if retry_wakeup_at.is_some() => {
                    self.run_retry_scheduler(
                        &events,
                        retry_deadline.expect("retry deadline is present"),
                    ).await;
                }
                peer_event = peer_events.recv() => {
                    if let Some(peer_event) = peer_event {
                        match self.handle_peer_event(peer_event) {
                            Ok(runtime_events) => {
                                for event in runtime_events {
                                    let _ = events.send(EngineEvent::Runtime { event }).await;
                                }
                                for event in self.pending_engine_events.drain(..) {
                                    let _ = events.send(event).await;
                                }
                            }
                            Err(error) => {
                                let _ = events.send(EngineEvent::Log {
                                    log: EngineLogEvent {
                                        level: "error".to_owned(),
                                        message: format!("peer event handling failed: {error}"),
                                    },
                                }).await;
                            }
                        }
                    }
                }
                envelope = commands.recv() => {
                    let Some(envelope) = envelope else {
                        self.relay.shutdown();
                        break;
                    };
                    let should_stop = matches!(&envelope.command, EngineCommand::Shutdown);
                    match self.handle_command(envelope.command) {
                        Ok((payload, runtime_events, connection_snapshot)) => {
                            if let Some(snapshot) = connection_snapshot {
                                let _ = events.send(EngineEvent::Connection { snapshot }).await;
                            }
                            for event in runtime_events {
                                let _ = events.send(EngineEvent::Runtime { event }).await;
                            }
                            for event in self.pending_engine_events.drain(..) {
                                let _ = events.send(event).await;
                            }
                            let _ = events.send(EngineEvent::Response {
                                request_id: envelope.request_id,
                                result: ResponseResult::Ok { payload },
                            }).await;
                        }
                        Err(error) => {
                            let _ = events.send(EngineEvent::Response {
                                request_id: envelope.request_id,
                                result: ResponseResult::Error {
                                    code: error_code(&error).to_owned(),
                                    message: error.to_string(),
                                },
                            }).await;
                        }
                    }
                    if should_stop {
                        break;
                    }
                }
            }
        }
        Ok(())
    }

    fn handle_command(
        &mut self,
        command: EngineCommand,
    ) -> EngineResult<(
        ResponsePayload,
        Vec<torchat_client_runtime::RuntimeEvent>,
        Option<ConnectionSnapshot>,
    )> {
        match command {
            EngineCommand::Bootstrap => {
                let (bootstrapped, runtime_events) =
                    self.with_runtime(|runtime| runtime.bootstrap_runtime())?;
                Ok((json_response(bootstrapped)?, runtime_events, None))
            }
            EngineCommand::GetIdentity => {
                Ok((json_response(self.runtime_identity()?)?, Vec::new(), None))
            }
            EngineCommand::GetProfile => {
                Ok((json_response(self.runtime_profile()?)?, Vec::new(), None))
            }
            EngineCommand::PairingInbox => {
                let (result, runtime_events): (PairingSyncResult, _) =
                    self.with_runtime(|runtime| runtime.pairing_inbox())?;
                for acknowledgement in &result.acknowledgements {
                    if let Err(error) =
                        self.acknowledge_pairing_request(&acknowledgement.pairing_id)
                    {
                        self.pending_engine_events.push(EngineEvent::Log {
                            log: EngineLogEvent {
                                level: "warn".to_owned(),
                                message: format!(
                                    "pairing inbox acknowledgement deferred pairing_id={} error={error}",
                                    acknowledgement.pairing_id
                                ),
                            },
                        });
                    }
                }
                Ok((json_response(result)?, runtime_events, None))
            }
            EngineCommand::PairingOutbox => {
                let (result, runtime_events) =
                    self.with_runtime(|runtime| runtime.pairing_outbox())?;
                Ok((json_response(result)?, runtime_events, None))
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
                if self.database.contact_peer_endpoint(&installation_id)?.is_some() {
                    self.database.expedite_peer_deliveries(&installation_id)?;
                    self.flush_pending_send_effects()?;
                } else {
                    self.queue_relay_endpoint_bootstraps()?;
                    self.retry_pending_contact_confirmations()?;
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
            EngineCommand::SetNickname { nickname } => {
                let (profile, runtime_events) =
                    self.with_runtime(|runtime| runtime.set_nickname(nickname))?;
                Ok((json_response(profile)?, runtime_events, None))
            }
            EngineCommand::RefreshPairingCode => {
                let (code, runtime_events) =
                    self.with_runtime(|runtime| runtime.refresh_pairing_code())?;
                Ok((json_response(code)?, runtime_events, None))
            }
            EngineCommand::SubmitPairingCode { code } => {
                let (item, runtime_events) =
                    self.with_runtime(|runtime| runtime.submit_pairing_code(code))?;
                Ok((json_response(item)?, runtime_events, None))
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
                let (effect, mut commit_events) = self.with_runtime(|runtime| {
                    runtime.commit_accept_pairing(&pairing_id, invite_id, payload)
                })?;
                self.deliver_send_effect(effect.into())?;
                runtime_events.append(&mut commit_events);
                Ok((ResponsePayload::Empty, runtime_events, None))
            }
            EngineCommand::RejectPairing { pairing_id } => {
                let (effect, runtime_events) =
                    self.with_runtime(|runtime| runtime.commit_reject_pairing(&pairing_id))?;
                self.deliver_send_effect(effect)?;
                Ok((ResponsePayload::Empty, runtime_events, None))
            }
            EngineCommand::CancelPairing { pairing_id } => {
                let (_, runtime_events) =
                    self.with_runtime(|runtime| runtime.prepare_cancel_pairing(&pairing_id))?;
                self.relay
                    .cancel_pairing(&pairing_id)
                    .map_err(runtime_error)?;
                let (_, mut confirm_events) =
                    self.with_runtime(|runtime| runtime.confirm_pairing_cancelled(&pairing_id))?;
                let mut events = runtime_events;
                events.append(&mut confirm_events);
                Ok((ResponsePayload::Empty, events, None))
            }
            EngineCommand::ArchivePairing { pairing_id } => {
                let (_, runtime_events) =
                    self.with_runtime(|runtime| runtime.archive_pairing(&pairing_id))?;
                Ok((json_response(true)?, runtime_events, None))
            }
            EngineCommand::VerifyContact { installation_id } => {
                let (_, runtime_events) =
                    self.with_runtime(|runtime| runtime.verify_contact(&installation_id))?;
                Ok((json_response(true)?, runtime_events, None))
            }
            EngineCommand::UpdateContactSettings {
                installation_id,
                local_alias,
                muted,
                blocked,
                transport_policy,
            } => {
                let (contact, runtime_events) = self.with_runtime(|runtime| {
                    let mut contact = runtime.update_contact_settings(
                        &installation_id,
                        local_alias,
                        muted,
                        blocked,
                    )?;
                    if let Some(policy) = transport_policy {
                        contact = runtime.set_contact_transport_policy(&installation_id, policy)?;
                    }
                    Ok(contact)
                })?;
                Ok((json_response(contact)?, runtime_events, None))
            }
            EngineCommand::StartConversation { contact_id } => {
                let (created, runtime_events) =
                    self.with_runtime(|runtime| runtime.start_conversation(&contact_id))?;
                Ok((json_response(created)?, runtime_events, None))
            }
            EngineCommand::OpenConversation { conversation_id } => {
                let (_, runtime_events) =
                    self.with_runtime(|runtime| runtime.open_conversation(conversation_id))?;
                Ok((json_response(true)?, runtime_events, None))
            }
            EngineCommand::CloseConversation => {
                let (_, runtime_events) = self.with_runtime(|runtime| {
                    runtime.close_conversation();
                    Ok(())
                })?;
                Ok((json_response(true)?, runtime_events, None))
            }
            EngineCommand::SendMessage {
                conversation_id,
                body,
                reply_to_message_id,
            } => {
                let (effect, runtime_events) = self.send_message_command(
                    &conversation_id,
                    body,
                    reply_to_message_id.as_deref(),
                )?;
                Ok((json_response(effect)?, runtime_events, None))
            }
            EngineCommand::RetryMessage { message_id } => {
                let (effect, runtime_events) =
                    self.with_runtime(|runtime| runtime.retry_message(&message_id))?;
                self.deliver_send_effect(effect.into())?;
                Ok((ResponsePayload::Empty, runtime_events, None))
            }
            EngineCommand::DeleteMessageLocal { message_id } => {
                let (_, runtime_events) =
                    self.with_runtime(|runtime| runtime.delete_message_local(&message_id))?;
                Ok((ResponsePayload::Empty, runtime_events, None))
            }
            EngineCommand::SetTyping {
                conversation_id,
                typing,
            } => {
                self.send_ephemeral_payload(
                    &conversation_id,
                    ApplicationPayloadV1::Typing {
                        version: torchat_core::PROTOCOL_VERSION,
                        sent_at: unix_ms(),
                        typing,
                    },
                )?;
                Ok((ResponsePayload::Empty, Vec::new(), None))
            }
            EngineCommand::SetPresence { online } => {
                let peers = self.conversations.keys().cloned().collect::<Vec<_>>();
                for peer in peers {
                    self.send_ephemeral_payload(
                        &peer,
                        ApplicationPayloadV1::Presence {
                            version: torchat_core::PROTOCOL_VERSION,
                            sent_at: unix_ms(),
                            online,
                        },
                    )?;
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
                    self.send_ephemeral_payload(
                        &conversation_id,
                        ApplicationPayloadV1::ReadReceipt {
                            version: torchat_core::PROTOCOL_VERSION,
                            message_ids,
                            read_at: unix_ms(),
                        },
                    )?;
                }
                Ok((ResponsePayload::Empty, Vec::new(), None))
            }
            EngineCommand::Connect => {
                self.advance_connection_generation();
                // An explicit connect is a new startup attempt. Internal
                // retries remain bounded, while the UI retry resets the
                // counter without touching persistent client state.
                self.relay_retry_at = None;
                self.relay_retry_attempt = 0;
                self.connection_state = if self.socks5_url.is_some() {
                    ConnectionState::Connecting
                } else {
                    ConnectionState::WaitingForTor
                };
                let relay_ready = match self.relay.ensure_session() {
                    Ok(()) => {
                        self.relay_retry_at = None;
                        self.relay_retry_attempt = 0;
                        true
                    }
                    Err(error) => {
                        self.schedule_relay_retry();
                        self.pending_engine_events.push(EngineEvent::Log {
                            log: EngineLogEvent {
                                level: "warn".to_owned(),
                                message: format!("relay bootstrap deferred: {error}"),
                            },
                        });
                        false
                    }
                };
                let profile = self.runtime_profile()?;
                if relay_ready && !profile.nickname.trim().is_empty() {
                    self.relay
                        .update_profile(&profile.nickname)
                        .map_err(runtime_error)
                        .ok();
                }
                let (connected, mut runtime_events) =
                    self.with_runtime(|runtime| runtime.connect())?;
                if relay_ready {
                    runtime_events.append(&mut self.sync_pairing_inbox()?);
                }
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

    fn with_runtime<R>(
        &mut self,
        op: impl FnOnce(
            &mut ClientRuntime<
                SqliteRuntimeStorage<'_>,
                EngineRuntimeTransport<'_>,
                SystemRuntimeClock,
            >,
        ) -> torchat_client_runtime::RuntimeResult<R>,
    ) -> EngineResult<(R, Vec<torchat_client_runtime::RuntimeEvent>)> {
        let storage = SqliteRuntimeStorage::new(self.database.transaction()?);
        let transport = EngineRuntimeTransport {
            status: self.tor_status.clone(),
            relay: self.relay.as_mut(),
        };
        let session = mem::take(&mut self.session);
        let mut runtime = ClientRuntime::with_session(storage, transport, self.clock, session);
        let session_before = runtime.session().clone();
        runtime.session_mut().begin_transaction();

        let result = match op(&mut runtime) {
            Ok(value) => match runtime.storage_mut().commit() {
                Ok(()) => {
                    runtime.session_mut().commit_transaction();
                    Ok(value)
                }
                Err(error) => {
                    runtime.session_mut().rollback_transaction();
                    runtime.restore_session(session_before);
                    Err(error)
                }
            },
            Err(error) => {
                let _ = runtime.storage_mut().rollback();
                runtime.session_mut().rollback_transaction();
                runtime.restore_session(session_before);
                Err(error)
            }
        };

        let events = if result.is_ok() {
            runtime.drain_events()
        } else {
            Vec::new()
        };
        let (_, transport, _, session) = runtime.into_parts_with_session();
        self.session = session;
        self.tor_status = transport.status;
        let value = result.map_err(runtime_error)?;
        Ok((value, events))
    }

    fn apply_platform_fact(
        &mut self,
        fact: PlatformFact,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        match fact {
            PlatformFact::TorStatus {
                phase,
                progress,
                detail,
            } => {
                let (connection_state, runtime_phase, label) = match phase {
                    crate::TorPhase::Starting => (
                        ConnectionState::WaitingForTor,
                        RuntimeStatusPhase::Starting,
                        "tor starting",
                    ),
                    crate::TorPhase::Bootstrapping => (
                        ConnectionState::WaitingForTor,
                        RuntimeStatusPhase::Bootstrapping,
                        "tor bootstrapping",
                    ),
                    crate::TorPhase::Ready => {
                        let state = match self.connection_state {
                            ConnectionState::Connected
                            | ConnectionState::Connecting
                            | ConnectionState::Authenticating
                            | ConnectionState::WaitingForReady
                            | ConnectionState::Backoff { .. } => self.connection_state.clone(),
                            _ => ConnectionState::Disconnected,
                        };
                        let phase = match &state {
                            ConnectionState::Connected => RuntimeStatusPhase::Connected,
                            ConnectionState::Backoff { .. } => RuntimeStatusPhase::Reconnecting,
                            ConnectionState::Connecting
                            | ConnectionState::Authenticating
                            | ConnectionState::WaitingForReady => RuntimeStatusPhase::Connecting,
                            _ => RuntimeStatusPhase::Offline,
                        };
                        (state, phase, "tor ready")
                    }
                    crate::TorPhase::Failed => {
                        self.advance_connection_generation();
                        self.socks5_url = None;
                        self.relay.set_socks5_url(None);
                        self.requeue_after_disconnect()?;
                        (
                            ConnectionState::Stopped,
                            RuntimeStatusPhase::Error,
                            "tor failed",
                        )
                    }
                };
                self.connection_state = connection_state;
                self.tor_status = RuntimeTorStatus {
                    phase: runtime_phase,
                    label: label.to_owned(),
                    detail,
                    progress: Some(i32::from(progress)),
                    latency_ms: None,
                    retry_attempt: 0,
                };
                let status = self.tor_status.clone();
                let (_, runtime_events) =
                    self.with_runtime(|runtime| Ok(runtime.report_tor_status(status)))?;
                Ok(runtime_events)
            }
            PlatformFact::TorEndpointAvailable { socks5_url } => {
                let endpoint_changed = self.socks5_url.as_deref() != Some(socks5_url.as_str());
                if endpoint_changed {
                    self.advance_connection_generation();
                    self.requeue_after_disconnect()?;
                    self.socks5_url = Some(socks5_url);
                    self.relay.set_socks5_url(self.socks5_url.clone());
                    self.connection_state = ConnectionState::Disconnected;
                }
                if self.tor_status.phase == RuntimeStatusPhase::Starting
                    || self.tor_status.phase == RuntimeStatusPhase::Offline
                {
                    self.tor_status.phase = RuntimeStatusPhase::Bootstrapping;
                    self.tor_status.label = "tor endpoint available".to_owned();
                    self.tor_status.detail = "SOCKS endpoint available".to_owned();
                    self.tor_status.progress = self.tor_status.progress.or(Some(0));
                }
                let status = self.tor_status.clone();
                let (_, runtime_events) =
                    self.with_runtime(|runtime| Ok(runtime.report_tor_status(status)))?;
                Ok(runtime_events)
            }
            PlatformFact::TorEndpointLost { reason } => {
                self.advance_connection_generation();
                self.socks5_url = None;
                self.relay.set_socks5_url(None);
                self.requeue_after_disconnect()?;
                self.connection_state = ConnectionState::WaitingForTor;
                self.tor_status.label = "tor unavailable".to_owned();
                self.tor_status.detail = reason;
                self.tor_status.phase = RuntimeStatusPhase::Offline;
                self.tor_status.progress = None;
                let status = self.tor_status.clone();
                let (_, runtime_events) =
                    self.with_runtime(|runtime| Ok(runtime.report_tor_status(status)))?;
                Ok(runtime_events)
            }
            PlatformFact::OnionServiceAvailable {
                onion_address,
                virtual_port,
                generation,
            } => {
                if generation != self.expected_onion_generation {
                    return Err(EngineError::InvalidCommand(
                        "stale onion service generation".to_owned(),
                    ));
                }
                if virtual_port != PEER_VIRTUAL_PORT {
                    return Err(EngineError::InvalidCommand(
                        "unsupported onion service virtual port".to_owned(),
                    ));
                }
                let sequence = self
                    .local_peer_endpoint
                    .as_ref()
                    .map(|endpoint| {
                        if endpoint.onion_address.eq_ignore_ascii_case(&onion_address) {
                            endpoint.sequence
                        } else {
                            endpoint.sequence.saturating_add(1)
                        }
                    })
                    .unwrap_or(1);
                let previous_endpoint = self.local_peer_endpoint.clone();
                let endpoint = PeerEndpointBundle::new(
                    &self.identity,
                    onion_address,
                    sequence,
                    unix_secs(),
                    None,
                );
                endpoint
                    .validate(unix_secs())
                    .map_err(EngineError::InvalidCommand)?;
                self.database
                    .put_local_peer_endpoint(&endpoint, generation)?;
                if let Some(previous) = previous_endpoint
                    && endpoint.sequence > previous.sequence
                {
                    self.database
                        .enqueue_endpoint_update_for_contacts(&PeerEndpointUpdate {
                            previous_sequence: previous.sequence,
                            endpoint: endpoint.clone(),
                        })?;
                }
                if let Some(peer) = &self.peer_transport {
                    peer.set_local_endpoint(endpoint.clone());
                }
                self.local_peer_endpoint = Some(endpoint);
                let _ = self.queue_endpoint_update_probes();
                let _ = self.queue_relay_endpoint_bootstraps();
                Ok(vec![
                    torchat_client_runtime::RuntimeEvent::PeerEndpointChanged {
                        contact_id: self.identity.installation_id(),
                        status: torchat_client_runtime::PeerEndpointStatus::Verified,
                    },
                ])
            }
            PlatformFact::OnionServiceLost { reason } => {
                self.local_peer_endpoint = None;
                self.database.delete_local_peer_endpoint()?;
                self.database.requeue_peer_deliveries(unix_ms())?;
                Ok(vec![
                    torchat_client_runtime::RuntimeEvent::PeerEndpointChanged {
                        contact_id: self.identity.installation_id(),
                        status: PeerEndpointStatus::Missing,
                    },
                    torchat_client_runtime::RuntimeEvent::RuntimeLog {
                        message: format!("onion service unavailable: {reason}"),
                    },
                ])
            }
            PlatformFact::AppVisibilityChanged { foreground } => {
                self.app_foreground = foreground;
                Ok(Vec::new())
            }
            PlatformFact::NetworkChanged { online } => {
                self.network_online = online;
                if !online {
                    self.advance_connection_generation();
                    self.requeue_after_disconnect()?;
                    self.relay.set_socks5_url(None);
                    self.connection_state = ConnectionState::WaitingForTor;
                } else if self.socks5_url.is_some() {
                    self.advance_connection_generation();
                    self.requeue_after_disconnect()?;
                    self.relay.set_socks5_url(self.socks5_url.clone());
                    self.connection_state = ConnectionState::Connecting;
                    let _ = self.queue_endpoint_update_probes();
                }
                Ok(Vec::new())
            }
            PlatformFact::PowerModeChanged {
                battery_saver,
                device_idle,
            } => {
                self.battery_saver = battery_saver;
                self.device_idle = device_idle;
                Ok(Vec::new())
            }
            PlatformFact::BackgroundExecutionRestricted { restricted } => {
                self.background_restricted = restricted;
                Ok(Vec::new())
            }
        }
    }

    fn handle_peer_event(
        &mut self,
        event: PeerTransportEvent,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        match event {
            PeerTransportEvent::InboundMessage {
                envelope,
                persisted,
                delivered,
            } => {
                self.pending_engine_events.push(EngineEvent::Log {
                    log: EngineLogEvent {
                        level: "info".to_owned(),
                        message: format!(
                            "peer message received message_id={} sender={}",
                            envelope.message_id, envelope.sender_installation_id
                        ),
                    },
                });
                let ack = |kind| PeerAck {
                    session_id: envelope.session_id,
                    message_id: envelope.message_id,
                    kind,
                    ciphertext_hash: envelope.ciphertext_hash(),
                };
                let store_result = match self
                    .database
                    .store_inbound_peer_envelope(&envelope, unix_secs())
                {
                    Ok(result) => result,
                    Err(error) => {
                        let _ = persisted.send(Err(error.to_string()));
                        let _ = delivered.send(Err(error.to_string()));
                        return Err(error);
                    }
                };
                let _ = persisted.send(Ok(ack(PeerAckKind::Persisted)));
                if matches!(
                    store_result,
                    InboundEnvelopeStoreResult::Duplicate { delivered: true }
                ) {
                    let _ = delivered.send(Ok(ack(PeerAckKind::Delivered)));
                    return Ok(Vec::new());
                }
                let ciphertext = String::from_utf8(envelope.ciphertext.clone()).map_err(|error| {
                    EngineError::InvalidCommand(format!(
                        "peer wire ciphertext is not UTF-8: {error}"
                    ))
                });
                let result = ciphertext.and_then(|wire_payload| {
                    let ciphertext = PeerCiphertextPayload::decode(&wire_payload)
                        .map_err(EngineError::InvalidCommand)?;
                    self.handle_application_envelope(
                        RelayEnvelope {
                            version: torchat_core::PROTOCOL_VERSION,
                            message_id: envelope.message_id,
                            sender: envelope.sender_installation_id.clone(),
                            recipient: self.identity.installation_id(),
                            ciphertext: wire_payload,
                        },
                        ciphertext,
                    )
                });
                match result {
                    Ok(runtime_events) => {
                        self.database.complete_inbound_peer_envelope(
                            &envelope.sender_installation_id,
                            &envelope.message_id.to_string(),
                        )?;
                        let _ = delivered.send(Ok(ack(PeerAckKind::Delivered)));
                        Ok(runtime_events)
                    }
                    Err(error) => {
                        let _ = delivered.send(Err(error.to_string()));
                        Err(error)
                    }
                }
            }
            PeerTransportEvent::Ack {
                delivery,
                kind,
                contact_installation_id,
                endpoint_sequence,
            } => {
                self.pending_engine_events.push(EngineEvent::Log {
                    log: EngineLogEvent {
                        level: "info".to_owned(),
                        message: format!(
                            "peer ack received contact={} kind={:?}",
                            contact_installation_id, kind
                        ),
                    },
                });
                if matches!(kind, PeerAckKind::Persisted | PeerAckKind::Delivered)
                    && let Some(sequence) = endpoint_sequence
                {
                    self.database
                        .complete_endpoint_updates(&contact_installation_id, sequence)?;
                }
                match delivery {
                    PeerDeliveryTag::Message { message_id } => match kind {
                        PeerAckKind::Received => Ok(Vec::new()),
                        PeerAckKind::Persisted => {
                            self.database.complete_outbound_delivery(&message_id)?;
                            self.apply_message_transport_outcome(
                                &message_id,
                                MessageTransportOutcome::PeerPersisted,
                            )
                        }
                        PeerAckKind::Delivered => self.apply_message_transport_outcome(
                            &message_id,
                            MessageTransportOutcome::PeerDelivered,
                        ),
                    },
                    PeerDeliveryTag::Receipt { message_id } => {
                        if matches!(kind, PeerAckKind::Persisted | PeerAckKind::Delivered) {
                            self.database.complete_delivery_receipt(&message_id)?;
                        }
                        Ok(Vec::new())
                    }
                    PeerDeliveryTag::Ephemeral => Ok(Vec::new()),
                    PeerDeliveryTag::EndpointUpdate => Ok(Vec::new()),
                }
            }
            PeerTransportEvent::EndpointUpdated { endpoint } => {
                let previous = self
                    .database
                    .contact_peer_endpoint(&endpoint.installation_id)?
                    .ok_or_else(|| {
                        EngineError::InvalidCommand(
                            "peer endpoint update has no known predecessor".to_owned(),
                        )
                    })?;
                endpoint
                    .validate_successor(&previous, unix_secs())
                    .map_err(EngineError::InvalidCommand)?;
                self.database.put_contact_peer_endpoint(&endpoint)?;
                if let Some(peer) = &self.peer_transport {
                    peer.authorize_contact(&endpoint);
                }
                Ok(vec![
                    torchat_client_runtime::RuntimeEvent::PeerEndpointChanged {
                        contact_id: endpoint.installation_id,
                        status: PeerEndpointStatus::Verified,
                    },
                ])
            }
            PeerTransportEvent::IngressError { error } => {
                self.pending_engine_events.push(EngineEvent::Log {
                    log: EngineLogEvent {
                        level: "warn".to_owned(),
                        message: format!("peer inbound connection failed: {error}"),
                    },
                });
                Ok(Vec::new())
            }
            PeerTransportEvent::ConnectionChanged {
                installation_id,
                session_id,
                status,
                error,
                delivery,
            } => {
                if let Some(session_id) = session_id {
                    let sessions = self
                        .active_peer_sessions
                        .entry(installation_id.clone())
                        .or_default();
                    match status {
                        PeerConnectionStatus::Connected => {
                            sessions.insert(session_id);
                        }
                        PeerConnectionStatus::Offline => {
                            sessions.remove(&session_id);
                            if !sessions.is_empty() {
                                return Ok(Vec::new());
                            }
                        }
                        _ => {}
                    }
                } else if self
                    .active_peer_sessions
                    .get(&installation_id)
                    .is_some_and(|sessions| !sessions.is_empty())
                    && matches!(
                        status,
                        PeerConnectionStatus::Connecting
                            | PeerConnectionStatus::Authenticating
                            | PeerConnectionStatus::Backoff
                    )
                {
                    return Ok(Vec::new());
                }
                if status == PeerConnectionStatus::Connected {
                    self.database
                        .mark_peer_connected(&installation_id, unix_secs())?;
                }
                let mut runtime_events = match (&status, error.as_deref(), delivery) {
                    (
                        PeerConnectionStatus::Backoff,
                        Some(error_message),
                        Some(PeerDeliveryTag::Message { message_id }),
                    ) => self.handle_failed_peer_message_delivery(
                        &installation_id,
                        &message_id,
                        error_message,
                    )?,
                    (
                        PeerConnectionStatus::Backoff,
                        Some(error_message),
                        Some(PeerDeliveryTag::Receipt { message_id }),
                    ) => {
                        self.handle_failed_peer_receipt_delivery(
                            &installation_id,
                            &message_id,
                            error_message,
                        )?;
                        Vec::new()
                    }
                    _ => Vec::new(),
                };
                let retry_in_ms = match (&status, error.as_deref()) {
                    (PeerConnectionStatus::Backoff, Some(_)) => {
                        self.peer_retry_in_ms(&installation_id)?
                    }
                    _ => None,
                };
                runtime_events.push(
                    torchat_client_runtime::RuntimeEvent::PeerConnectionChanged {
                        contact_id: installation_id,
                        status,
                        retry_in_ms,
                    },
                );
                Ok(runtime_events)
            }
        }
    }

    fn connection_snapshot(&self, detail: &str) -> ConnectionSnapshot {
        ConnectionSnapshot {
            state: self.connection_state.clone(),
            generation: self.connection_generation,
            detail: detail.to_owned(),
        }
    }

    fn recover_pending_inbound_peer_envelopes(
        &mut self,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        let mut runtime_events = Vec::new();
        for record in self.database.pending_inbound_peer_envelopes()? {
            let message_id = uuid::Uuid::parse_str(&record.message_id)
                .map_err(|error| EngineError::Storage(error.to_string()))?;
            let wire_payload = String::from_utf8(record.ciphertext).map_err(|error| {
                EngineError::Storage(format!("stored peer payload is not UTF-8: {error}"))
            })?;
            let ciphertext =
                PeerCiphertextPayload::decode(&wire_payload).map_err(EngineError::Storage)?;
            runtime_events.append(&mut self.handle_application_envelope(
                RelayEnvelope {
                    version: torchat_core::PROTOCOL_VERSION,
                    message_id,
                    sender: record.sender_installation_id.clone(),
                    recipient: self.identity.installation_id(),
                    ciphertext: wire_payload,
                },
                ciphertext,
            )?);
            self.database.complete_inbound_peer_envelope(
                &record.sender_installation_id,
                &record.message_id,
            )?;
        }
        Ok(runtime_events)
    }

    fn advance_connection_generation(&mut self) {
        self.connection_generation = self.connection_generation.wrapping_add(1);
    }

    fn schedule_relay_retry(&mut self) {
        self.relay_retry_attempt = self.relay_retry_attempt.saturating_add(1);
        let seconds = 2_u64.saturating_pow(
            self.relay_retry_attempt.saturating_sub(1).min(5),
        );
        self.relay_retry_at = Some(Instant::now() + Duration::from_secs(seconds.min(60)));
        self.connection_state = ConnectionState::Backoff {
            attempt: self.relay_retry_attempt,
            retry_in_ms: seconds.min(60_000),
        };
    }

    async fn retry_relay_bootstrap(&mut self, events: &mpsc::Sender<EngineEvent>) {
        self.relay_retry_at = None;
        if self.socks5_url.is_none() || !self.network_online {
            self.schedule_relay_retry();
            return;
        }
        match self.relay.ensure_session() {
            Ok(()) => {
                self.relay_retry_attempt = 0;
                self.connection_state = ConnectionState::Connecting;
                let _ = events
                    .send(EngineEvent::Log {
                        log: EngineLogEvent {
                            level: "info".to_owned(),
                            message: "relay bootstrap recovered".to_owned(),
                        },
                    })
                    .await;
                if let Ok(profile) = self.runtime_profile() {
                    if !profile.nickname.trim().is_empty() {
                        let _ = self.relay.update_profile(&profile.nickname);
                    }
                }
                match self.sync_pairing_inbox() {
                    Ok(runtime_events) => {
                        for event in runtime_events {
                            let _ = events.send(EngineEvent::Runtime { event }).await;
                        }
                    }
                    Err(error) => {
                        self.schedule_relay_retry();
                        let _ = events
                            .send(EngineEvent::Log {
                                log: EngineLogEvent {
                                    level: "warn".to_owned(),
                                    message: format!(
                                        "relay bootstrap recovered but pairing sync failed: {error}"
                                    ),
                                },
                            })
                            .await;
                        return;
                    }
                }
                if let Err(error) = self.flush_pending_send_effects() {
                    self.schedule_relay_retry();
                    let _ = events
                        .send(EngineEvent::Log {
                            log: EngineLogEvent {
                                level: "warn".to_owned(),
                                message: format!(
                                    "relay bootstrap recovered but send flush failed: {error}"
                                ),
                            },
                        })
                        .await;
                    return;
                }
                if let Err(error) = self.flush_pending_receipt_effects() {
                    self.schedule_relay_retry();
                    let _ = events
                        .send(EngineEvent::Log {
                            log: EngineLogEvent {
                                level: "warn".to_owned(),
                                message: format!(
                                    "relay bootstrap recovered but receipt flush failed: {error}"
                                ),
                            },
                        })
                        .await;
                    return;
                }
                let _ = events
                    .send(EngineEvent::Connection {
                        snapshot: self.connection_snapshot("relay bootstrap recovered"),
                    })
                    .await;
            }
            Err(error) => {
                if self.relay_retry_attempt >= 5 {
                    self.relay_retry_at = None;
                    self.connection_state = ConnectionState::Stopped;
                    let message = format!(
                        "relay bootstrap failed after {} attempts: {error}",
                        self.relay_retry_attempt
                    );
                    let _ = events
                        .send(EngineEvent::Runtime {
                            event: torchat_client_runtime::RuntimeEvent::RuntimeError {
                                message: message.clone(),
                            },
                        })
                        .await;
                    let _ = events
                        .send(EngineEvent::Connection {
                            snapshot: self.connection_snapshot(&message),
                        })
                        .await;
                    return;
                }
                self.schedule_relay_retry();
                let _ = events
                    .send(EngineEvent::Log {
                        log: EngineLogEvent {
                            level: "warn".to_owned(),
                            message: format!(
                                "relay bootstrap retry {} failed: {error}",
                                self.relay_retry_attempt
                            ),
                        },
                    })
                    .await;
            }
        }
    }

    fn requeue_after_disconnect(&mut self) -> EngineResult<()> {
        let now_ms = unix_ms();
        self.database.requeue_after_disconnect(now_ms)?;
        self.database.requeue_peer_deliveries(now_ms)?;
        self.pending_relay_deliveries.clear();
        Ok(())
    }

    fn queue_notification(&mut self, notification: NotificationRequest) {
        if !self.app_foreground {
            self.pending_engine_events
                .push(EngineEvent::NotificationRequested { notification });
        }
    }

    fn sync_pairing_inbox(&mut self) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        let (result, runtime_events): (PairingSyncResult, _) =
            self.with_runtime(|runtime| runtime.pairing_inbox())?;
        for acknowledgement in result.acknowledgements {
            if let Err(error) = self.acknowledge_pairing_request(&acknowledgement.pairing_id) {
                self.pending_engine_events.push(EngineEvent::Log {
                    log: EngineLogEvent {
                        level: "warn".to_owned(),
                        message: format!(
                            "pairing sync acknowledgement deferred pairing_id={} error={error}",
                            acknowledgement.pairing_id
                        ),
                    },
                });
            }
        }
        Ok(runtime_events)
    }

    async fn drain_relay_events(&mut self, events: &mpsc::Sender<EngineEvent>) {
        while let Some(event) = self.relay.poll_event() {
            match self.handle_relay_event(event) {
                Ok((runtime_events, connection_snapshot, log_event)) => {
                    if let Some(snapshot) = connection_snapshot {
                        let _ = events.send(EngineEvent::Connection { snapshot }).await;
                    }
                    if let Some(log) = log_event {
                        let _ = events.send(EngineEvent::Log { log }).await;
                    }
                    for event in runtime_events {
                        let _ = events.send(EngineEvent::Runtime { event }).await;
                    }
                    for event in self.pending_engine_events.drain(..) {
                        let _ = events.send(event).await;
                    }
                }
                Err(error) => {
                    self.pending_engine_events.clear();
                    let _ = events
                        .send(EngineEvent::Log {
                            log: EngineLogEvent {
                                level: "error".to_owned(),
                                message: format!("relay event handling failed: {error}"),
                            },
                        })
                        .await;
                }
            }
        }
    }

    async fn run_retry_scheduler(
        &mut self,
        events: &mpsc::Sender<EngineEvent>,
        deadline: RetryDeadline,
    ) {
        let control_plane_required = matches!(
            deadline.kind,
            RetryKind::PairingResponse
                | RetryKind::PendingWelcome
                | RetryKind::PeerEndpointBootstrap
                | RetryKind::ContactConfirmation
        );
        if control_plane_required && self.connection_state != ConnectionState::Connected {
            return;
        }
        if !control_plane_required && (!self.network_online || self.socks5_url.is_none()) {
            return;
        }
        let result = match deadline.kind {
            RetryKind::MessageSend | RetryKind::PairingResponse => {
                self.flush_pending_send_effects().map(|_| "send flush")
            }
            RetryKind::MessageAckDeadline => self
                .retry_expired_ack_deadlines()
                .map(|_| "ack deadline handling"),
            RetryKind::Receipt => self
                .flush_pending_receipt_effects()
                .map(|_| "receipt flush"),
            RetryKind::PendingWelcome => self.retry_pending_welcomes().map(|_| "welcome flush"),
            RetryKind::PeerEndpointBootstrap => self
                .retry_peer_endpoint_bootstraps()
                .map(|_| "peer endpoint bootstrap flush"),
            RetryKind::ContactConfirmation => self
                .retry_pending_contact_confirmations()
                .map(|_| "contact confirmation flush"),
            RetryKind::PairingAcknowledgement => self
                .retry_pending_pairing_acknowledgements()
                .map(|_| "pairing acknowledgement flush"),
        };
        if let Err(error) = result {
            let _ = events
                .send(EngineEvent::Log {
                    log: EngineLogEvent {
                        level: "warn".to_owned(),
                        message: format!(
                            "retry scheduler {:?} failed at {}: {error}",
                            deadline.kind, deadline.at_ms
                        ),
                    },
                })
                .await;
        }
    }

    fn next_retry_deadline(&self) -> EngineResult<Option<RetryDeadline>> {
        self.database
            .next_retry_deadline(unix_ms(), self.clock.now_secs())
    }

    fn next_retry_wakeup_at(
        &self,
        retry_deadline: Option<RetryDeadline>,
    ) -> EngineResult<Option<Instant>> {
        let Some(retry_deadline) = retry_deadline else {
            return Ok(None);
        };
        let retry_delay_ms = retry_deadline.at_ms.saturating_sub(unix_ms()) as u64;
        Ok(Some(Instant::now() + Duration::from_millis(retry_delay_ms)))
    }

    fn retry_expired_ack_deadlines(&mut self) -> EngineResult<()> {
        for message_id in self.database.expired_ack_deadline_message_ids(unix_ms())? {
            let _ = self.apply_message_transport_outcome(
                &message_id,
                MessageTransportOutcome::RetryableFailure,
            )?;
        }
        Ok(())
    }

    fn prepare_pairing_response_payload(
        &mut self,
        effect: &torchat_client_runtime::PairingSendEffect,
    ) -> EngineResult<Option<(String, String)>> {
        let Some(stored) = self
            .database
            .pairing_response_retry_record(&effect.pairing_id, unix_secs())?
        else {
            return Ok(None);
        };
        let next_attempt_at = unix_ms() + retry_backoff_ms(stored.attempt_count);
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

    fn handle_relay_event(
        &mut self,
        event: RelayEvent,
    ) -> EngineResult<(
        Vec<torchat_client_runtime::RuntimeEvent>,
        Option<ConnectionSnapshot>,
        Option<EngineLogEvent>,
    )> {
        match event {
            RelayEvent::Connected => {
                self.connection_state = ConnectionState::Connected;
                let (_, runtime_events) =
                    self.with_runtime(|runtime| runtime.expedite_retry_after_ready())?;
                self.flush_pending_send_effects()?;
                self.flush_pending_receipt_effects()?;
                self.retry_pending_welcomes()?;
                self.retry_pending_contact_confirmations()?;
                self.queue_relay_endpoint_bootstraps()?;
                Ok((
                    runtime_events,
                    Some(self.connection_snapshot("relay connected")),
                    Some(EngineLogEvent {
                        level: "info".to_owned(),
                        message: "relay connected".to_owned(),
                    }),
                ))
            }
            RelayEvent::Backoff {
                attempt,
                retry_in_ms,
                detail,
            } => {
                self.connection_state = ConnectionState::Backoff {
                    attempt,
                    retry_in_ms,
                };
                Ok((
                    Vec::new(),
                    Some(self.connection_snapshot("relay reconnect backoff")),
                    Some(EngineLogEvent {
                        level: "info".to_owned(),
                        message: format!(
                            "relay reconnect backoff attempt {attempt} retry_in_ms={retry_in_ms}: {detail}"
                        ),
                    }),
                ))
            }
            RelayEvent::Disconnected { detail } => {
                self.connection_state = ConnectionState::Disconnected;
                self.requeue_after_disconnect()?;
                Ok((
                    Vec::new(),
                    Some(self.connection_snapshot("relay disconnected")),
                    Some(EngineLogEvent {
                        level: "warn".to_owned(),
                        message: format!("relay disconnected: {detail}"),
                    }),
                ))
            }
            RelayEvent::Envelope(envelope) => self
                .handle_relay_envelope(envelope)
                .map(|events| (events, None, None)),
            RelayEvent::MessageTransportOutcome {
                message_id,
                outcome,
            } => {
                let runtime_events = self.handle_relay_delivery_outcome(message_id, outcome)?;
                Ok((runtime_events, None, None))
            }
        }
    }

    fn queue_relay_envelope(
        &mut self,
        envelope_id: uuid::Uuid,
        recipient: &str,
        ciphertext: &str,
        delivery: PendingRelayDelivery,
    ) -> EngineResult<()> {
        self.relay
            .send_envelope(envelope_id, recipient, ciphertext)
            .map_err(runtime_error)?;
        self.pending_relay_deliveries.insert(envelope_id, delivery);
        Ok(())
    }

    fn contact_transport_policy(
        &mut self,
        installation_id: &str,
    ) -> EngineResult<ContactTransportPolicy> {
        Ok(self
            .list_contacts()?
            .into_iter()
            .find(|contact| contact.installation_id == installation_id)
            .map(|contact| contact.transport_policy)
            .unwrap_or_default())
    }

    fn queue_peer_payload(
        &mut self,
        message_id: uuid::Uuid,
        recipient: &str,
        conversation_id: &str,
        sequence: u64,
        ciphertext: Vec<u8>,
        delivery: PeerDeliveryTag,
    ) -> EngineResult<()> {
        if !self.network_online {
            return Err(EngineError::Transport(
                "peer transport is paused while the network is offline".to_owned(),
            ));
        }
        let socks5_url = self.socks5_url.clone().ok_or_else(|| {
            EngineError::Transport("Tor SOCKS endpoint is not available".to_owned())
        })?;
        let local_endpoint = self.local_peer_endpoint.as_ref().ok_or_else(|| {
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
        endpoint.validate(unix_secs()).map_err(|error| {
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
            let now = unix_ms();
            let ack_deadline = now + 60_000;
            if !self.database.claim_outbound_delivery(
                delivery_message_id,
                ack_deadline,
                ack_deadline,
            )? {
                return Err(EngineError::Transport(
                    "outbound delivery is no longer queued".to_owned(),
                ));
            }
        }

        let command = PeerOutboundCommand {
            peer_public_key: endpoint.identity_public_key.clone(),
            endpoint,
            local_endpoint: local_endpoint.clone(),
            endpoint_updates: self.database.pending_endpoint_updates(recipient)?,
            message_id,
            conversation_id: conversation_id.to_owned(),
            sequence,
            created_at: unix_secs(),
            ciphertext,
            delivery,
            socks5_url,
        };
        self.peer_transport
            .as_ref()
            .ok_or_else(|| EngineError::Transport("peer listener is not running".to_owned()))?
            .try_send(command)
    }

    fn queue_endpoint_update_probes(&mut self) -> EngineResult<()> {
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
        for contact in self.list_contacts()? {
            let updates = self
                .database
                .pending_endpoint_updates(&contact.installation_id)?;
            if updates.is_empty() {
                continue;
            }
            let Some(endpoint) = self
                .database
                .contact_peer_endpoint(&contact.installation_id)?
            else {
                continue;
            };
            let probe_id = uuid::Uuid::new_v4();
            transport.try_send(PeerOutboundCommand {
                peer_public_key: endpoint.identity_public_key.clone(),
                endpoint,
                local_endpoint: local_endpoint.clone(),
                endpoint_updates: updates,
                message_id: probe_id,
                conversation_id: contact.installation_id,
                sequence: stable_message_sequence(probe_id),
                created_at: unix_secs(),
                ciphertext: Vec::new(),
                delivery: PeerDeliveryTag::EndpointUpdate,
                socks5_url: socks5_url.clone(),
            })?;
        }
        Ok(())
    }

    fn queue_relay_endpoint_bootstraps(&mut self) -> EngineResult<()> {
        if self.connection_state != ConnectionState::Connected {
            return Ok(());
        }
        let Some(local_endpoint) = self.local_peer_endpoint.clone() else {
            return Ok(());
        };
        let profile = self.runtime_profile()?;
        for contact in self.list_contacts()? {
            if self
                .database
                .contact_peer_endpoint(&contact.installation_id)?
                .is_some()
            {
                continue;
            }
            let payload = RelayPayloadV1::peer_endpoint_bootstrap(
                &self.identity,
                &profile.nickname,
                contact.installation_id.clone(),
                local_endpoint.clone(),
            )
            .encode()
            .map_err(EngineError::InvalidCommand)?;
            self.database.put_peer_endpoint_bootstrap(
                &contact.installation_id,
                payload.as_bytes(),
                local_endpoint.sequence,
            )?;
            if let Err(error) = self.send_peer_endpoint_bootstrap(PeerEndpointBootstrapRecord {
                contact_installation_id: contact.installation_id.clone(),
                payload: payload.into_bytes(),
                endpoint_sequence: local_endpoint.sequence,
                attempt_count: 0,
                next_attempt_at: 0,
                last_error: None,
            }) {
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

    fn send_peer_endpoint_bootstrap(
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

    fn send_contact_confirmation(
        &mut self,
        record: PendingContactConfirmationRecord,
    ) -> EngineResult<()> {
        self.relay
            .confirm_contact(&record.capability, &record.peer_installation_id)
            .map_err(runtime_error)
    }

    fn acknowledge_pairing_request(&mut self, pairing_id: &str) -> EngineResult<()> {
        match self.relay.acknowledge_pairing(pairing_id) {
            Ok(()) => {
                self.database
                    .complete_pending_pairing_acknowledgement(pairing_id)?;
                Ok(())
            }
            Err(error) => {
                self.database.put_pending_pairing_acknowledgement(
                    pairing_id,
                    Some(&error.to_string()),
                )?;
                Err(runtime_error(error))
            }
        }
    }

    fn handle_relay_delivery_outcome(
        &mut self,
        envelope_id: uuid::Uuid,
        outcome: MessageTransportOutcome,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        let delivery = self.pending_relay_deliveries.remove(&envelope_id);
        match delivery {
            Some(PendingRelayDelivery::PairingResponse { pairing_id }) => {
                match outcome {
                    MessageTransportOutcome::Forwarded
                    | MessageTransportOutcome::Delivered
                    | MessageTransportOutcome::PeerPersisted
                    | MessageTransportOutcome::PeerDelivered => {
                        self.database.complete_pairing_response(&pairing_id)?;
                    }
                    MessageTransportOutcome::RecipientOffline
                    | MessageTransportOutcome::PeerUnavailable
                    | MessageTransportOutcome::PeerAuthenticationFailed
                    | MessageTransportOutcome::PeerRejected
                    | MessageTransportOutcome::RetryableFailure
                    | MessageTransportOutcome::PermanentFailure => {
                        self.database.record_pairing_response_error(
                            &pairing_id,
                            "relay did not forward pairing response",
                        )?;
                    }
                }
                Ok(Vec::new())
            }
            Some(PendingRelayDelivery::Welcome { invite_id }) => {
                match outcome {
                    MessageTransportOutcome::Forwarded
                    | MessageTransportOutcome::Delivered
                    | MessageTransportOutcome::PeerPersisted
                    | MessageTransportOutcome::PeerDelivered => {
                        self.database.remove_pending_welcome(&invite_id)?;
                        self.pending_welcomes.remove(&invite_id);
                    }
                    MessageTransportOutcome::RecipientOffline
                    | MessageTransportOutcome::PeerUnavailable
                    | MessageTransportOutcome::PeerAuthenticationFailed
                    | MessageTransportOutcome::PeerRejected
                    | MessageTransportOutcome::RetryableFailure
                    | MessageTransportOutcome::PermanentFailure => {
                        self.database.record_pending_welcome_error(
                            &invite_id,
                            "relay did not forward MLS Welcome",
                        )?;
                    }
                }
                Ok(Vec::new())
            }
            Some(PendingRelayDelivery::Message { message_id }) => match outcome {
                MessageTransportOutcome::Forwarded
                | MessageTransportOutcome::Delivered
                | MessageTransportOutcome::PeerPersisted
                | MessageTransportOutcome::PeerDelivered => {
                    self.database.complete_outbound_delivery(&message_id)?;
                    self.apply_message_transport_outcome(
                        &message_id,
                        MessageTransportOutcome::Forwarded,
                    )
                }
                MessageTransportOutcome::RecipientOffline
                | MessageTransportOutcome::PeerUnavailable
                | MessageTransportOutcome::PeerAuthenticationFailed
                | MessageTransportOutcome::PeerRejected
                | MessageTransportOutcome::RetryableFailure
                | MessageTransportOutcome::PermanentFailure => {
                    let attempt = self
                        .database
                        .outbound_delivery(&message_id)?
                        .map(|record| record.attempt_count)
                        .unwrap_or(0);
                    self.database.requeue_outbound_delivery(
                        &message_id,
                        unix_ms() + retry_backoff_ms(attempt),
                        "relay did not forward message",
                    )?;
                    self.apply_message_transport_outcome(
                        &message_id,
                        MessageTransportOutcome::RetryableFailure,
                    )
                }
            },
            Some(PendingRelayDelivery::Receipt { message_id }) => {
                match outcome {
                    MessageTransportOutcome::Forwarded
                    | MessageTransportOutcome::Delivered
                    | MessageTransportOutcome::PeerPersisted
                    | MessageTransportOutcome::PeerDelivered => {
                        self.database.complete_delivery_receipt(&message_id)?;
                    }
                    MessageTransportOutcome::RecipientOffline
                    | MessageTransportOutcome::PeerUnavailable
                    | MessageTransportOutcome::PeerAuthenticationFailed
                    | MessageTransportOutcome::PeerRejected
                    | MessageTransportOutcome::RetryableFailure
                    | MessageTransportOutcome::PermanentFailure => {
                        let attempt = self
                            .database
                            .delivery_receipt(&message_id)?
                            .map(|record| record.attempt_count)
                            .unwrap_or(0);
                        self.database.requeue_delivery_receipt(
                            &message_id,
                            unix_ms() + retry_backoff_ms(attempt),
                            "relay did not forward receipt",
                        )?;
                    }
                }
                Ok(Vec::new())
            }
            Some(PendingRelayDelivery::Ephemeral { installation_id }) => {
                self.pending_engine_events.push(EngineEvent::Log {
                    log: EngineLogEvent {
                        level: match outcome {
                            MessageTransportOutcome::Forwarded
                            | MessageTransportOutcome::Delivered
                            | MessageTransportOutcome::PeerPersisted
                            | MessageTransportOutcome::PeerDelivered => "info".to_owned(),
                            _ => "warn".to_owned(),
                        },
                        message: format!(
                            "ephemeral relay outcome contact={} outcome={outcome:?}",
                            installation_id
                        ),
                    },
                });
                Ok(Vec::new())
            }
            Some(PendingRelayDelivery::PeerEndpointBootstrap {
                installation_id,
                sequence,
            }) => {
                if matches!(
                    outcome,
                    MessageTransportOutcome::Forwarded
                        | MessageTransportOutcome::Delivered
                        | MessageTransportOutcome::PeerPersisted
                        | MessageTransportOutcome::PeerDelivered
                ) {
                    self.database
                        .complete_peer_endpoint_bootstrap(&installation_id, sequence)?;
                }
                self.pending_engine_events.push(EngineEvent::Log {
                    log: EngineLogEvent {
                        level: match outcome {
                            MessageTransportOutcome::Forwarded
                            | MessageTransportOutcome::Delivered
                            | MessageTransportOutcome::PeerPersisted
                            | MessageTransportOutcome::PeerDelivered => "info".to_owned(),
                            _ => "warn".to_owned(),
                        },
                        message: format!(
                            "peer endpoint bootstrap outcome contact={} sequence={} outcome={outcome:?}",
                            installation_id, sequence
                        ),
                    },
                });
                Ok(Vec::new())
            }
            None => {
                // Application envelopes use their public message id as the
                // relay envelope id. A late outcome can therefore still be
                // applied after the in-memory correlation was cleared.
                match self.apply_message_transport_outcome(&envelope_id.to_string(), outcome) {
                    Ok(events) => Ok(events),
                    Err(EngineError::InvalidCommand(message))
                        if message.contains("message does not exist") =>
                    {
                        Ok(Vec::new())
                    }
                    Err(error) => Err(error),
                }
            }
        }
    }

    fn handle_relay_envelope(
        &mut self,
        envelope: RelayEnvelope,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        // Control-plane payloads (pairing and Welcome) use RelayPayloadV1.
        // Application messages are opaque PeerCiphertextPayloads: the relay
        // must never inspect their MLS ciphertext, but the recipient still
        // needs to feed the decoded bytes through the exact same application
        // path used by the onion listener.
        let payload = match RelayPayloadV1::decode(&envelope.ciphertext) {
            Ok(payload) => payload,
            Err(relay_error) => {
                let ciphertext = PeerCiphertextPayload::decode(&envelope.ciphertext)
                    .map_err(|peer_error| {
                        EngineError::InvalidCommand(format!(
                            "invalid relay envelope payload: {relay_error}; peer payload: {peer_error}"
                        ))
                    })?;
                return self.handle_application_envelope(envelope, ciphertext);
            }
        };
        match &payload {
            RelayPayloadV1::PairingOffer {
                pairing_id, invite, ..
            } => {
                let mut runtime_events = self.accept_invite(invite)?;
                // The contact and durable Welcome have now been committed by
                // accept_invite. Finalize the originating local request as
                // well; otherwise its PENDING record blocks every later code.
                if let Ok(mut outcome_events) = self.apply_pairing_peer_outcome(
                    pairing_id,
                    PairingPeerOutcome::OfferReceived,
                ) {
                    runtime_events.append(&mut outcome_events);
                    if let Ok(mut completion_events) = self.apply_pairing_peer_outcome(
                        pairing_id,
                        PairingPeerOutcome::WelcomePrepared,
                    ) {
                        runtime_events.append(&mut completion_events);
                    }
                } else {
                    self.pending_engine_events.push(EngineEvent::Log {
                        log: EngineLogEvent {
                            level: "warn".to_owned(),
                            message: format!(
                                "pairing offer accepted without a local outbox record pairing_id={pairing_id}"
                            ),
                        },
                    });
                }
                self.queue_notification(NotificationRequest {
                    id: pairing_id.clone(),
                    title: "Nowe zaproszenie".to_owned(),
                    body: "Masz nową prośbę o rozmowę.".to_owned(),
                    conversation_id: None,
                });
                Ok(runtime_events)
            }
            RelayPayloadV1::PairingRejected { pairing_id, .. } => {
                if let Ok(pairing_id) = uuid::Uuid::parse_str(pairing_id) {
                    return self.apply_pairing_peer_outcome(
                        &pairing_id.to_string(),
                        PairingPeerOutcome::RejectionReceived,
                    );
                }
                Ok(Vec::new())
            }
            RelayPayloadV1::Welcome { sender, .. } => {
                payload
                    .verify_welcome(&envelope.sender, &self.identity.installation_id())
                    .map_err(EngineError::InvalidCommand)?;
                let peer_endpoint = payload.welcome_peer_endpoint().cloned();
                if let Some(endpoint) = &peer_endpoint {
                    endpoint
                        .validate(unix_secs())
                        .map_err(EngineError::InvalidCommand)?;
                    if endpoint.installation_id != sender.installation_id
                        || endpoint.identity_public_key != sender.public_key
                    {
                        return Err(EngineError::InvalidCommand(
                            "Welcome peer endpoint does not match sender identity".to_owned(),
                        ));
                    }
                }
                let (invite_id, welcome, tree) = payload
                    .decode_welcome()
                    .map_err(EngineError::InvalidCommand)?;
                let snapshot = self.snapshot_mls_inbox()?;
                let fresh_member = self.fresh_mls_member()?;
                let member = mem::replace(&mut self.mls_inbox, fresh_member);
                let conversation = match member.accept_conversation(&welcome, &tree) {
                    Ok(value) => value,
                    Err(error) => {
                        self.restore_mls_inbox(&snapshot)?;
                        return Err(EngineError::InvalidCommand(error));
                    }
                };
                let inbox_snapshot_after = self.snapshot_mls_inbox()?;
                let committed = self.commit_contact_with_conversation(
                    sender.clone(),
                    conversation,
                    Some(&invite_id),
                    None,
                    None,
                    Some(&inbox_snapshot_after),
                    Some(&invite_id),
                );
                match committed {
                    Ok(mut runtime_events) => {
                        if let Some(peer_endpoint) = peer_endpoint {
                            self.database.put_contact_peer_endpoint(&peer_endpoint)?;
                            if let Some(transport) = &self.peer_transport {
                                transport.authorize_contact(&peer_endpoint);
                            }
                            runtime_events.push(
                                torchat_client_runtime::RuntimeEvent::PeerEndpointChanged {
                                    contact_id: peer_endpoint.installation_id.clone(),
                                    status: PeerEndpointStatus::Verified,
                                },
                            );
                        }
                        self.pending_welcomes.remove(&invite_id);
                        Ok(runtime_events)
                    }
                    Err(error) => {
                        self.restore_mls_inbox(&snapshot)?;
                        Err(error)
                    }
                }
            }
            RelayPayloadV1::PeerEndpointBootstrap { .. } => {
                let endpoint = payload
                    .verify_peer_endpoint_bootstrap(
                        &envelope.sender,
                        &self.identity.installation_id(),
                    )
                    .map_err(EngineError::InvalidCommand)?;
                let contact = self
                    .list_contacts()?
                    .into_iter()
                    .find(|contact| contact.installation_id == endpoint.installation_id);
                let Some(contact) = contact else {
                    self.database.put_pending_peer_endpoint_inbox(
                        &PendingPeerEndpointInboxRecord {
                            contact_installation_id: endpoint.installation_id.clone(),
                            payload: payload
                                .encode()
                                .map_err(EngineError::InvalidCommand)?
                                .into_bytes(),
                            endpoint_sequence: endpoint.sequence,
                            received_at: unix_ms(),
                        },
                    )?;
                    self.pending_engine_events.push(EngineEvent::Log {
                        log: EngineLogEvent {
                            level: "info".to_owned(),
                            message: format!(
                                "peer endpoint bootstrap deferred until contact exists contact={}",
                                endpoint.installation_id
                            ),
                        },
                    });
                    return Ok(Vec::new());
                };
                if !contact.public_key.trim().is_empty()
                    && contact.public_key != endpoint.identity_public_key
                {
                    return Err(EngineError::InvalidCommand(
                        "peer endpoint bootstrap identity does not match contact".to_owned(),
                    ));
                }
                self.apply_peer_endpoint(endpoint)
            }
        }
    }

    fn apply_peer_endpoint(
        &mut self,
        endpoint: PeerEndpointBundle,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        match self.database.contact_peer_endpoint(&endpoint.installation_id)? {
            Some(previous) => {
                if endpoint.sequence <= previous.sequence {
                    return Ok(Vec::new());
                }
                endpoint
                    .validate_successor(&previous, unix_secs())
                    .map_err(EngineError::InvalidCommand)?;
            }
            None => {
                endpoint
                    .validate(unix_secs())
                    .map_err(EngineError::InvalidCommand)?;
            }
        }
        self.database.put_contact_peer_endpoint(&endpoint)?;
        if let Some(transport) = &self.peer_transport {
            transport.authorize_contact(&endpoint);
        }
        Ok(vec![
            torchat_client_runtime::RuntimeEvent::PeerEndpointChanged {
                contact_id: endpoint.installation_id,
                status: PeerEndpointStatus::Verified,
            },
        ])
    }

    fn apply_pending_peer_endpoint(
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
            EngineError::Storage(format!("stored peer endpoint bootstrap is not UTF-8: {error}"))
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

    fn handle_application_envelope(
        &mut self,
        envelope: RelayEnvelope,
        ciphertext: Vec<u8>,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        let peer = envelope.sender.clone();
        let message_id = envelope.message_id;
        let ciphertext_hash = Sha256::digest(&ciphertext).to_vec();
        if let Some(existing) = self
            .database
            .received_envelope(&peer, &message_id.to_string())?
        {
            if existing.ciphertext_hash != ciphertext_hash {
                return Err(EngineError::InvalidCommand(
                    "duplicate envelope has different ciphertext".to_owned(),
                ));
            }
            if existing.receipt_state != "DELIVERED"
                && self
                    .database
                    .delivery_receipt(&message_id.to_string())?
                    .is_some()
            {
                self.flush_pending_receipt_effects()?;
            }
            return Ok(Vec::new());
        }

        let mut conversation = self.conversations.remove(&peer).ok_or_else(|| {
            EngineError::InvalidCommand("message received before MLS Welcome".to_owned())
        })?;
        let snapshot_before = conversation
            .snapshot()
            .map_err(|error| EngineError::Storage(error.to_string()))?;

        let result = (|| {
            let plaintext = conversation
                .decrypt(&ciphertext)
                .map_err(EngineError::InvalidCommand)?;
            let application =
                ApplicationPayloadV1::decode(&plaintext).map_err(EngineError::InvalidCommand)?;
            let snapshot_after = conversation
                .snapshot()
                .map_err(|error| EngineError::Storage(error.to_string()))?;
            let received_at = unix_secs();
            let envelope_record = ReceivedEnvelopeRecord {
                sender_installation_id: peer.clone(),
                message_id: message_id.to_string(),
                ciphertext_hash,
                received_at,
                receipt_state: "NONE".to_owned(),
            };

            match application {
                ApplicationPayloadV1::Message {
                    message_id: payload_message_id,
                    body,
                    reply_to,
                    ..
                } => {
                    if payload_message_id != message_id {
                        return Err(EngineError::InvalidCommand(
                            "application messageId mismatch".to_owned(),
                        ));
                    }
                    let receipt = DeliveryReceiptRecord {
                        envelope_id: uuid::Uuid::new_v4().to_string(),
                        message_id: message_id.to_string(),
                        conversation_id: peer.clone(),
                        original_sender: peer.clone(),
                        received_at,
                        relay_payload: None,
                        state: "PENDING".to_owned(),
                        attempt_count: 0,
                        next_attempt_at: 0,
                        last_error: None,
                        created_at: received_at,
                    };
                    let notification = NotificationRequest {
                        id: message_id.to_string(),
                        title: "Nowa wiadomość".to_owned(),
                        body: body.clone(),
                        conversation_id: Some(peer.clone()),
                    };
                    let (notify, runtime_events) = self.with_runtime(|runtime| {
                        let accepts = runtime.contact_accepts_messages(&peer)?;
                        let mut envelope_record = envelope_record.clone();
                        if accepts {
                            runtime.receive_message_reply(
                                &peer,
                                body.clone(),
                                Some(message_id),
                                reply_to.clone().map(|reply| {
                                    torchat_client_runtime::MessageReply {
                                        message_id: reply.message_id.to_string(),
                                        body: reply.body,
                                        outgoing: !reply.outgoing,
                                    }
                                }),
                            )?;
                            runtime.storage_mut().put_delivery_receipt(&receipt)?;
                            envelope_record.receipt_state = "PENDING".to_owned();
                        }
                        runtime
                            .storage_mut()
                            .put_conversation_mls_snapshot(&peer, &snapshot_after)?;
                        runtime
                            .storage_mut()
                            .put_received_envelope(&envelope_record)?;
                        Ok(accepts && runtime.contact_allows_notifications(&peer)?)
                    })?;
                    Ok((runtime_events, notify.then_some(notification)))
                }
                ApplicationPayloadV1::DeliveryReceipt {
                    message_id: delivered_message_id,
                    ..
                } => {
                    let (_, runtime_events) = self.with_runtime(|runtime| {
                        runtime.apply_message_transport_outcome(
                            delivered_message_id,
                            MessageTransportOutcome::Delivered,
                        )?;
                        runtime
                            .storage_mut()
                            .put_conversation_mls_snapshot(&peer, &snapshot_after)?;
                        runtime
                            .storage_mut()
                            .put_received_envelope(&envelope_record)?;
                        Ok(())
                    })?;
                    Ok((runtime_events, None))
                }
                ApplicationPayloadV1::Typing {
                    sent_at, typing, ..
                } => {
                    let (_, mut runtime_events) = self.with_runtime(|runtime| {
                        runtime
                            .storage_mut()
                            .put_conversation_mls_snapshot(&peer, &snapshot_after)?;
                        Ok(())
                    })?;
                    runtime_events.push(torchat_client_runtime::RuntimeEvent::TypingChanged {
                        conversation_id: peer.clone(),
                        typing,
                        expires_at: sent_at + 5_000,
                    });
                    Ok((runtime_events, None))
                }
                ApplicationPayloadV1::Presence {
                    sent_at, online, ..
                } => {
                    let (_, mut runtime_events) = self.with_runtime(|runtime| {
                        runtime
                            .storage_mut()
                            .put_conversation_mls_snapshot(&peer, &snapshot_after)?;
                        Ok(())
                    })?;
                    runtime_events.push(torchat_client_runtime::RuntimeEvent::PresenceChanged {
                        contact_id: peer.clone(),
                        online,
                        observed_at: sent_at,
                    });
                    Ok((runtime_events, None))
                }
                ApplicationPayloadV1::ReadReceipt { message_ids, .. } => {
                    let (_, events) = self.with_runtime(|runtime| {
                        for message_id in message_ids {
                            let _ = runtime.apply_message_read(message_id);
                        }
                        runtime
                            .storage_mut()
                            .put_conversation_mls_snapshot(&peer, &snapshot_after)?;
                        Ok(())
                    })?;
                    Ok((events, None))
                }
            }
        })();

        match result {
            Ok((runtime_events, notification)) => {
                self.conversations.insert(peer, conversation);
                self.flush_pending_receipt_effects()?;
                if let Some(notification) = notification {
                    self.queue_notification(notification);
                }
                Ok(runtime_events)
            }
            Err(error) => {
                let restored =
                    DirectConversation::restore(&snapshot_before).map_err(|restore_error| {
                        EngineError::Storage(format!(
                            "restore MLS conversation after receive rollback: {restore_error}"
                        ))
                    })?;
                self.conversations.insert(peer, restored);
                Err(error)
            }
        }
    }

    fn build_contact_invite(
        &mut self,
        recipient_installation_id: Option<String>,
    ) -> EngineResult<String> {
        let profile = self.runtime_profile()?;
        let nickname = profile.nickname.trim().chars().take(32).collect::<String>();
        let snapshot_before = self.snapshot_mls_inbox()?;
        let key_package = self
            .mls_inbox
            .key_package()
            .map_err(|error| EngineError::Storage(format!("create MLS key package: {error}")))?;
        let snapshot_after = self.snapshot_mls_inbox()?;
        if let Err(error) = self.database.put_mls_inbox_snapshot(&snapshot_after) {
            self.restore_mls_inbox(&snapshot_before)?;
            return Err(error);
        }
        let payload = self
            .identity
            .contact_invite_payload(
                Some(nickname),
                recipient_installation_id,
                URL_SAFE_NO_PAD.encode(key_package),
                uuid::Uuid::new_v4().to_string(),
                unix_secs() as u64 + 15 * 60,
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
        serde_json::to_string(&invite).map_err(EngineError::from)
    }

    fn runtime_profile(&mut self) -> EngineResult<RuntimeProfile> {
        let mut storage = SqliteRuntimeStorage::new(self.database.transaction()?);
        let profile = storage
            .profile()
            .map_err(runtime_error)?
            .ok_or_else(|| EngineError::Storage("runtime profile is missing".to_owned()))?;
        storage.rollback().map_err(runtime_error)?;
        Ok(profile)
    }

    fn runtime_identity(&mut self) -> EngineResult<RuntimeIdentity> {
        let mut storage = SqliteRuntimeStorage::new(self.database.transaction()?);
        let identity = storage
            .identity()
            .map_err(runtime_error)?
            .ok_or_else(|| EngineError::Storage("runtime identity is missing".to_owned()))?;
        storage.rollback().map_err(runtime_error)?;
        Ok(identity)
    }

    fn list_contacts(&mut self) -> EngineResult<Vec<torchat_client_runtime::ContactRecord>> {
        let mut storage = SqliteRuntimeStorage::new(self.database.transaction()?);
        let contacts = storage.contacts().map_err(runtime_error)?;
        storage.rollback().map_err(runtime_error)?;
        Ok(contacts)
    }

    fn list_conversations(
        &mut self,
    ) -> EngineResult<Vec<torchat_client_runtime::ConversationSummary>> {
        let mut storage = SqliteRuntimeStorage::new(self.database.transaction()?);
        let conversations = storage.conversations().map_err(runtime_error)?;
        storage.rollback().map_err(runtime_error)?;
        Ok(conversations)
    }

    fn list_messages(
        &mut self,
        conversation_id: &str,
    ) -> EngineResult<Vec<torchat_client_runtime::ChatMessage>> {
        let mut storage = SqliteRuntimeStorage::new(self.database.transaction()?);
        let messages = storage.messages(conversation_id).map_err(runtime_error)?;
        storage.rollback().map_err(runtime_error)?;
        Ok(messages)
    }

    fn send_message_command(
        &mut self,
        conversation_id: &str,
        body: String,
        reply_to_message_id: Option<&str>,
    ) -> EngineResult<(MessageSendEffect, Vec<torchat_client_runtime::RuntimeEvent>)> {
        let peer_installation_id = self
            .list_conversations()?
            .into_iter()
            .find(|conversation| conversation.id == conversation_id)
            .map(|conversation| conversation.contact_installation_id)
            .ok_or_else(|| EngineError::InvalidCommand("conversation does not exist".to_owned()))?;
        let mut conversation = self
            .conversations
            .remove(&peer_installation_id)
            .ok_or_else(|| {
                EngineError::InvalidCommand(
                    "contact requires MLS welcome before sending".to_owned(),
                )
            })?;
        let snapshot_before = conversation
            .snapshot()
            .map_err(|error| EngineError::Storage(error.to_string()))?;
        let now_ms = unix_ms();
        let next_attempt_at = now_ms + retry_backoff_ms(0);
        let ack_deadline = Some(now_ms + 60_000);

        let transaction_result = self.with_runtime(|runtime| {
            let effect = runtime.send_message_reply(conversation_id, body, reply_to_message_id)?;
            let stored = runtime
                .storage()
                .message(&effect.message_id)?
                .ok_or_else(|| {
                    RuntimeError::Storage(
                        "new outgoing message is missing from the active transaction".to_owned(),
                    )
                })?;
            let message_id = uuid::Uuid::parse_str(&effect.message_id)
                .map_err(|error| RuntimeError::Storage(error.to_string()))?;
            let plaintext = ApplicationPayloadV1::Message {
                version: torchat_core::PROTOCOL_VERSION,
                message_id,
                sent_at: stored.created_at,
                body: effect.body.clone(),
                reply_to: effect
                    .reply_to
                    .clone()
                    .map(|reply| {
                        Ok::<_, RuntimeError>(ApplicationReply {
                            message_id: uuid::Uuid::parse_str(&reply.message_id)
                                .map_err(|error| RuntimeError::Storage(error.to_string()))?,
                            body: reply.body,
                            outgoing: reply.outgoing,
                        })
                    })
                    .transpose()?,
            }
            .encode()
            .map_err(RuntimeError::Storage)?;
            let encrypted = conversation
                .encrypt(&plaintext)
                .map_err(RuntimeError::Storage)?;
            let payload = PeerCiphertextPayload::new(&encrypted)
                .encode()
                .map_err(RuntimeError::Storage)?;
            let snapshot_after = conversation.snapshot().map_err(RuntimeError::Storage)?;
            runtime.storage_mut().persist_outbound_encryption(
                &effect.message_id,
                payload.as_bytes(),
                &effect.conversation_id,
                &snapshot_after,
            )?;
            if !runtime.storage_mut().claim_outgoing_attempt(
                &effect.message_id,
                next_attempt_at,
                ack_deadline,
                None,
                now_ms,
            )? {
                return Err(RuntimeError::Storage(
                    "new outgoing message could not be claimed for delivery".to_owned(),
                ));
            }
            Ok((effect, payload))
        });

        let ((effect, payload), mut runtime_events) = match transaction_result {
            Ok(value) => value,
            Err(error) => {
                let restored =
                    DirectConversation::restore(&snapshot_before).map_err(|restore_error| {
                        EngineError::Storage(format!(
                            "restore MLS conversation after send rollback: {restore_error}"
                        ))
                    })?;
                self.conversations.insert(peer_installation_id, restored);
                return Err(error);
            }
        };
        self.conversations
            .insert(peer_installation_id.clone(), conversation);

        let envelope_id = uuid::Uuid::parse_str(&effect.message_id)
            .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
        let sequence = stable_message_sequence(envelope_id);
        runtime_events.append(&mut self.dispatch_outbound_message(
            &effect,
            envelope_id,
            sequence,
            payload,
        )?);
        Ok((effect, runtime_events))
    }

    fn send_ephemeral_payload(
        &mut self,
        conversation_id: &str,
        application: ApplicationPayloadV1,
    ) -> EngineResult<()> {
        let mut conversation = self.conversations.remove(conversation_id).ok_or_else(|| {
            EngineError::InvalidCommand(
                "contact requires MLS welcome before sending ephemeral state".to_owned(),
            )
        })?;
        let snapshot_before = conversation
            .snapshot()
            .map_err(|error| EngineError::Storage(error.to_string()))?;
        let persist_result = (|| {
            let plaintext = application.encode().map_err(EngineError::InvalidCommand)?;
            let encrypted = conversation
                .encrypt(&plaintext)
                .map_err(EngineError::InvalidCommand)?;
            let payload = PeerCiphertextPayload::new(&encrypted)
                .encode()
                .map_err(EngineError::InvalidCommand)?;
            let snapshot_after = conversation
                .snapshot()
                .map_err(|error| EngineError::Storage(error.to_string()))?;
            self.database
                .put_conversation_mls_snapshot(conversation_id, &snapshot_after)?;
            Ok(payload)
        })();
        let payload = match persist_result {
            Ok(payload) => payload,
            Err(error) => {
                conversation = DirectConversation::restore(&snapshot_before)
                    .map_err(|restore| EngineError::Storage(restore.to_string()))?;
                self.conversations
                    .insert(conversation_id.to_owned(), conversation);
                return Err(error);
            }
        };
        self.conversations
            .insert(conversation_id.to_owned(), conversation);
        self.dispatch_ephemeral_payload(conversation_id, payload)
    }

    fn dispatch_ephemeral_payload(
        &mut self,
        installation_id: &str,
        payload: String,
    ) -> EngineResult<()> {
        let policy = self.contact_transport_policy(installation_id)?;
        let peer_result = if matches!(policy, ContactTransportPolicy::RelayOnly) {
            Err(EngineError::Transport(
                "peer route disabled by contact policy".to_owned(),
            ))
        } else {
            let envelope_id = uuid::Uuid::new_v4();
            self.queue_peer_payload(
                envelope_id,
                installation_id,
                installation_id,
                stable_message_sequence(envelope_id),
                payload.clone().into_bytes(),
                PeerDeliveryTag::Ephemeral,
            )
        };
        if let Err(error) = peer_result {
            if matches!(
                policy,
                ContactTransportPolicy::PeerWithRelayFallback | ContactTransportPolicy::RelayOnly
            ) {
                let relay_envelope_id = uuid::Uuid::new_v4();
                if self
                    .queue_relay_envelope(
                        relay_envelope_id,
                        installation_id,
                        &payload,
                        PendingRelayDelivery::Ephemeral {
                            installation_id: installation_id.to_owned(),
                        },
                    )
                    .is_ok()
                {
                    return Ok(());
                }
            }
            return Err(error);
        }
        Ok(())
    }

    fn deliver_send_effect(&mut self, effect: RuntimeSendEffect) -> EngineResult<()> {
        if let Some(message) = effect.message().cloned() {
            let payload = self.prepare_outbound_message_payload(&message)?;
            let message_id = uuid::Uuid::parse_str(&message.message_id)
                .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
            let sequence = stable_message_sequence(message_id);
            let _ = self.dispatch_outbound_message(&message, message_id, sequence, payload)?;
            return Ok(());
        }
        if let Some(pairing) = effect.pairing().cloned() {
            let Some((recipient_installation_id, ciphertext)) =
                self.prepare_pairing_response_payload(&pairing)?
            else {
                return Ok(());
            };
            let envelope_id = uuid::Uuid::parse_str(&pairing.pairing_id)
                .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
            if let Err(error) = self.queue_relay_envelope(
                envelope_id,
                &recipient_installation_id,
                &ciphertext,
                PendingRelayDelivery::PairingResponse {
                    pairing_id: pairing.pairing_id.clone(),
                },
            ) {
                self.database
                    .record_pairing_response_error(&pairing.pairing_id, &error.to_string())?;
                self.pending_engine_events.push(EngineEvent::Log {
                    log: EngineLogEvent {
                        level: "warn".to_owned(),
                        message: format!(
                            "pairing response enqueue deferred pairing_id={} error={error}",
                            pairing.pairing_id
                        ),
                    },
                });
                return Ok(());
            }
            return Ok(());
        }
        if let Some(receipt) = effect.receipt().cloned() {
            let ciphertext = self.encrypt_receipt(&receipt)?;
            let envelope_id = uuid::Uuid::parse_str(&receipt.envelope_id)
                .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
            self.dispatch_outbound_receipt(
                &receipt,
                envelope_id,
                stable_message_sequence(envelope_id),
                ciphertext,
            )?;
            return Ok(());
        }
        Err(EngineError::InvalidCommand(
            "engine relay transport does not support this runtime send effect yet".to_owned(),
        ))
    }

    fn flush_pending_send_effects(&mut self) -> EngineResult<()> {
        let (effects, _) = self.with_runtime(|runtime| runtime.prepare_pending_send_effects())?;
        for effect in effects {
            self.deliver_send_effect(effect)?;
        }
        Ok(())
    }

    fn dispatch_outbound_message(
        &mut self,
        message: &torchat_client_runtime::MessageSendEffect,
        envelope_id: uuid::Uuid,
        sequence: u64,
        payload: String,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        self.database.enqueue_outbound_delivery(
            &message.message_id,
            &message.recipient_installation_id,
            sequence,
            unix_secs(),
        )?;
        let policy = self.contact_transport_policy(&message.recipient_installation_id)?;
        self.pending_engine_events.push(EngineEvent::Log {
            log: EngineLogEvent {
                level: "info".to_owned(),
                message: format!(
                    "delivery route selected message_id={} policy={:?}",
                    message.message_id, policy
                ),
            },
        });
        let peer_result = if matches!(policy, ContactTransportPolicy::RelayOnly) {
            Err(EngineError::Transport(
                "peer route disabled by contact policy".to_owned(),
            ))
        } else {
            self.queue_peer_payload(
                envelope_id,
                &message.recipient_installation_id,
                &message.conversation_id,
                sequence,
                payload.clone().into_bytes(),
                PeerDeliveryTag::Message {
                    message_id: message.message_id.clone(),
                },
            )
        };
        if let Err(error) = peer_result {
            return self.handle_failed_peer_message_delivery(
                &message.recipient_installation_id,
                &message.message_id,
                &error.to_string(),
            );
        }
        Ok(Vec::new())
    }

    fn handle_failed_peer_message_delivery(
        &mut self,
        installation_id: &str,
        message_id: &str,
        error: &str,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        let policy = self.contact_transport_policy(installation_id)?;
        let payload = self
            .database
            .message(message_id)?
            .and_then(|message| message.wire_ciphertext)
            .ok_or_else(|| {
                EngineError::Storage("outbound wire ciphertext is missing".to_owned())
            })?;
        let payload = String::from_utf8(payload).map_err(|decode_error| {
            EngineError::Storage(format!(
                "stored wire ciphertext is invalid UTF-8: {decode_error}"
            ))
        })?;
        let envelope_id = uuid::Uuid::parse_str(message_id)
            .map_err(|parse_error| EngineError::InvalidCommand(parse_error.to_string()))?;
        if matches!(
            policy,
            ContactTransportPolicy::PeerWithRelayFallback | ContactTransportPolicy::RelayOnly
        ) && self
            .queue_relay_envelope(
                envelope_id,
                installation_id,
                &payload,
                PendingRelayDelivery::Message {
                    message_id: message_id.to_owned(),
                },
            )
            .is_ok()
        {
            self.pending_engine_events.push(EngineEvent::Log {
                log: EngineLogEvent {
                    level: "warn".to_owned(),
                    message: format!(
                        "delivery route fallback message_id={} route=relay error={error}",
                        message_id
                    ),
                },
            });
            return Ok(Vec::new());
        }
        let attempt = self
            .database
            .outbound_delivery(message_id)?
            .map(|record| record.attempt_count)
            .unwrap_or(0);
        self.database.requeue_outbound_delivery(
            message_id,
            unix_ms() + retry_backoff_ms(attempt),
            error,
        )?;
        self.apply_message_transport_outcome(message_id, MessageTransportOutcome::PeerUnavailable)
    }

    fn dispatch_outbound_receipt(
        &mut self,
        receipt: &torchat_client_runtime::ReceiptSendEffect,
        envelope_id: uuid::Uuid,
        sequence: u64,
        ciphertext: String,
    ) -> EngineResult<()> {
        let policy = self.contact_transport_policy(&receipt.recipient_installation_id)?;
        let peer_result = if matches!(policy, ContactTransportPolicy::RelayOnly) {
            Err(EngineError::Transport(
                "peer route disabled by contact policy".to_owned(),
            ))
        } else {
            self.queue_peer_payload(
                envelope_id,
                &receipt.recipient_installation_id,
                &receipt.conversation_id,
                sequence,
                ciphertext.clone().into_bytes(),
                PeerDeliveryTag::Receipt {
                    message_id: receipt.message_id.clone(),
                },
            )
        };
        if let Err(error) = peer_result {
            self.handle_failed_peer_receipt_delivery(
                &receipt.recipient_installation_id,
                &receipt.message_id,
                &error.to_string(),
            )?;
        }
        Ok(())
    }

    fn handle_failed_peer_receipt_delivery(
        &mut self,
        installation_id: &str,
        message_id: &str,
        error: &str,
    ) -> EngineResult<()> {
        let policy = self.contact_transport_policy(installation_id)?;
        let payload = self
            .database
            .delivery_receipt(message_id)?
            .and_then(|receipt| receipt.relay_payload)
            .ok_or_else(|| {
                EngineError::Storage("delivery receipt payload is missing".to_owned())
            })?;
        let payload = String::from_utf8(payload).map_err(|decode_error| {
            EngineError::Storage(format!(
                "stored delivery receipt payload is invalid UTF-8: {decode_error}"
            ))
        })?;
        let envelope_id = uuid::Uuid::parse_str(message_id)
            .map_err(|parse_error| EngineError::InvalidCommand(parse_error.to_string()))?;
        if matches!(
            policy,
            ContactTransportPolicy::PeerWithRelayFallback | ContactTransportPolicy::RelayOnly
        ) && self
            .queue_relay_envelope(
                envelope_id,
                installation_id,
                &payload,
                PendingRelayDelivery::Receipt {
                    message_id: message_id.to_owned(),
                },
            )
            .is_ok()
        {
            return Ok(());
        }
        let attempt = self
            .database
            .delivery_receipt(message_id)?
            .map(|record| record.attempt_count)
            .unwrap_or(0);
        self.database.requeue_delivery_receipt(
            message_id,
            unix_ms() + retry_backoff_ms(attempt),
            error,
        )?;
        Ok(())
    }

    fn retry_pending_welcomes(&mut self) -> EngineResult<()> {
        let now_ms = unix_ms();
        let now_secs = unix_secs();
        self.database.delete_expired_pending_welcomes(now_secs)?;
        self.pending_welcomes
            .retain(|_, pending| pending.expires_at >= now_secs);
        for pending in self.database.due_pending_welcomes(now_ms, now_secs)? {
            let next_attempt_at = now_ms + retry_backoff_ms(pending.attempt_count);
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
                self.database
                    .record_pending_welcome_error(&pending.invite_id, &error.to_string())?;
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

    fn retry_peer_endpoint_bootstraps(&mut self) -> EngineResult<()> {
        if self.connection_state != ConnectionState::Connected {
            return Ok(());
        }
        for record in self.database.due_peer_endpoint_bootstraps(unix_ms())? {
            let next_attempt_at = unix_ms() + retry_backoff_ms(record.attempt_count);
            if !self.database.claim_peer_endpoint_bootstrap_attempt(
                &record.contact_installation_id,
                record.endpoint_sequence,
                next_attempt_at,
                None,
            )? {
                continue;
            }
            if let Err(error) = self.send_peer_endpoint_bootstrap(record.clone()) {
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

    fn retry_pending_contact_confirmations(&mut self) -> EngineResult<()> {
        if self.connection_state != ConnectionState::Connected {
            return Ok(());
        }
        for record in self.database.due_pending_contact_confirmations(unix_ms())? {
            let next_attempt_at = unix_ms() + retry_backoff_ms(record.attempt_count);
            if !self.database.claim_pending_contact_confirmation_attempt(
                &record.pairing_id,
                next_attempt_at,
                None,
            )? {
                continue;
            }
            if let Err(error) = self.send_contact_confirmation(record.clone()) {
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
                self.database
                    .complete_pending_contact_confirmation(&record.pairing_id)?;
            }
        }
        Ok(())
    }

    fn retry_pending_pairing_acknowledgements(&mut self) -> EngineResult<()> {
        if self.connection_state != ConnectionState::Connected {
            return Ok(());
        }
        for (pairing_id, attempt_count) in
            self.database.due_pending_pairing_acknowledgements(unix_ms())?
        {
            let next_attempt_at = unix_ms() + retry_backoff_ms(attempt_count);
            if !self.database.claim_pending_pairing_acknowledgement_attempt(
                &pairing_id,
                next_attempt_at,
                None,
            )? {
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

    fn peer_retry_in_ms(&self, installation_id: &str) -> EngineResult<Option<u64>> {
        let now = unix_ms();
        let outbound = self.database.next_contact_peer_retry_deadline_ms(installation_id)?;
        let receipt = self
            .database
            .next_contact_receipt_retry_deadline_ms(installation_id)?;
        Ok(outbound
            .into_iter()
            .chain(receipt)
            .min()
            .map(|deadline| deadline.saturating_sub(now) as u64))
    }

    fn apply_message_transport_outcome(
        &mut self,
        message_id: &str,
        outcome: MessageTransportOutcome,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        let parsed = uuid::Uuid::parse_str(message_id)
            .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
        let (_, runtime_events) =
            self.with_runtime(|runtime| runtime.apply_message_transport_outcome(parsed, outcome))?;
        Ok(runtime_events)
    }

    fn flush_pending_receipt_effects(&mut self) -> EngineResult<()> {
        let (effects, _) =
            self.with_runtime(|runtime| runtime.prepare_pending_receipt_effects())?;
        for effect in effects {
            self.deliver_send_effect(RuntimeSendEffect::from(effect))?;
        }
        Ok(())
    }

    fn prepare_outbound_message_payload(
        &mut self,
        effect: &torchat_client_runtime::MessageSendEffect,
    ) -> EngineResult<String> {
        let message_id = uuid::Uuid::parse_str(&effect.message_id)
            .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
        let stored = self.database.message(&effect.message_id)?.ok_or_else(|| {
            EngineError::Storage("runtime message is missing from engine store".to_owned())
        })?;
        let next_attempt_at = unix_ms() + retry_backoff_ms(stored.attempt_count);
        let ack_deadline = Some(unix_ms() + 60_000);
        if let Some(existing) = stored.wire_ciphertext {
            if !self.database.claim_outgoing_attempt(
                &effect.message_id,
                next_attempt_at,
                ack_deadline,
                None,
            )? {
                return Err(EngineError::Storage(
                    "outgoing message could not be claimed for retry".to_owned(),
                ));
            }
            return String::from_utf8(existing).map_err(|error| {
                EngineError::Storage(format!("stored wire ciphertext is invalid UTF-8: {error}"))
            });
        }

        let mut conversation = self
            .conversations
            .remove(&effect.recipient_installation_id)
            .ok_or_else(|| {
                EngineError::InvalidCommand(
                    "contact requires MLS welcome before sending".to_owned(),
                )
            })?;
        let snapshot_before = conversation
            .snapshot()
            .map_err(|error| EngineError::Storage(error.to_string()))?;
        let encryption_result = (|| {
            let plaintext = ApplicationPayloadV1::Message {
                version: torchat_core::PROTOCOL_VERSION,
                message_id,
                sent_at: stored.created_at,
                body: effect.body.clone(),
                reply_to: effect
                    .reply_to
                    .clone()
                    .map(|reply| {
                        Ok::<_, EngineError>(ApplicationReply {
                            message_id: uuid::Uuid::parse_str(&reply.message_id)
                                .map_err(|error| EngineError::InvalidCommand(error.to_string()))?,
                            body: reply.body,
                            outgoing: reply.outgoing,
                        })
                    })
                    .transpose()?,
            }
            .encode()
            .map_err(EngineError::InvalidCommand)?;
            let encrypted = conversation
                .encrypt(&plaintext)
                .map_err(EngineError::InvalidCommand)?;
            let payload = PeerCiphertextPayload::new(&encrypted)
                .encode()
                .map_err(EngineError::InvalidCommand)?;
            let snapshot_after = conversation
                .snapshot()
                .map_err(|error| EngineError::Storage(error.to_string()))?;
            if !self.database.persist_outbound_encryption_and_claim(
                &effect.message_id,
                payload.as_bytes(),
                &effect.conversation_id,
                &snapshot_after,
                next_attempt_at,
                ack_deadline,
            )? {
                return Err(EngineError::Storage(
                    "outgoing message could not be claimed after encryption".to_owned(),
                ));
            }
            Ok(payload)
        })();

        match encryption_result {
            Ok(payload) => {
                self.conversations
                    .insert(effect.recipient_installation_id.clone(), conversation);
                Ok(payload)
            }
            Err(error) => {
                let restored =
                    DirectConversation::restore(&snapshot_before).map_err(|restore_error| {
                        EngineError::Storage(format!(
                            "restore MLS conversation after retry rollback: {restore_error}"
                        ))
                    })?;
                self.conversations
                    .insert(effect.recipient_installation_id.clone(), restored);
                Err(error)
            }
        }
    }

    fn encrypt_receipt(
        &mut self,
        effect: &torchat_client_runtime::ReceiptSendEffect,
    ) -> EngineResult<String> {
        let stored = self
            .database
            .delivery_receipt(&effect.message_id)?
            .ok_or_else(|| EngineError::Storage("delivery receipt is missing".to_owned()))?;
        let in_flight_until = unix_ms() + 60_000;
        if let Some(existing) = stored.relay_payload {
            if !self
                .database
                .claim_receipt_attempt(&effect.message_id, in_flight_until, None)?
            {
                return Err(EngineError::Storage(
                    "delivery receipt could not be claimed for retry".to_owned(),
                ));
            }
            return String::from_utf8(existing).map_err(|error| {
                EngineError::Storage(format!(
                    "stored delivery receipt payload is invalid UTF-8: {error}"
                ))
            });
        }

        let mut conversation = self
            .conversations
            .remove(&effect.recipient_installation_id)
            .ok_or_else(|| {
                EngineError::InvalidCommand("receipt recipient has no MLS conversation".to_owned())
            })?;
        let snapshot_before = conversation
            .snapshot()
            .map_err(|error| EngineError::Storage(error.to_string()))?;
        let encryption_result = (|| {
            let plaintext = ApplicationPayloadV1::DeliveryReceipt {
                version: torchat_core::PROTOCOL_VERSION,
                message_id: uuid::Uuid::parse_str(&effect.message_id)
                    .map_err(|error| EngineError::InvalidCommand(error.to_string()))?,
                received_at: effect.received_at,
            }
            .encode()
            .map_err(EngineError::InvalidCommand)?;
            let encrypted = conversation
                .encrypt(&plaintext)
                .map_err(EngineError::InvalidCommand)?;
            let payload = PeerCiphertextPayload::new(&encrypted)
                .encode()
                .map_err(EngineError::InvalidCommand)?;
            let snapshot_after = conversation
                .snapshot()
                .map_err(|error| EngineError::Storage(error.to_string()))?;
            if !self.database.persist_receipt_encryption(
                &effect.message_id,
                payload.as_bytes(),
                &effect.conversation_id,
                &snapshot_after,
                in_flight_until,
                None,
            )? {
                return Err(EngineError::Storage(
                    "delivery receipt could not be claimed for encryption".to_owned(),
                ));
            }
            Ok(payload)
        })();

        match encryption_result {
            Ok(payload) => {
                self.conversations
                    .insert(effect.recipient_installation_id.clone(), conversation);
                Ok(payload)
            }
            Err(error) => {
                let restored =
                    DirectConversation::restore(&snapshot_before).map_err(|restore_error| {
                        EngineError::Storage(format!(
                            "restore MLS conversation after receipt rollback: {restore_error}"
                        ))
                    })?;
                self.conversations
                    .insert(effect.recipient_installation_id.clone(), restored);
                Err(error)
            }
        }
    }

    fn accept_invite(
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
                .or_else(|| self.database.pending_welcome(&invite.invite_id).ok().flatten());
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
                    self.database
                        .record_pending_welcome_error(&invite.invite_id, &error.to_string())?;
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
        let ciphertext = RelayPayloadV1::welcome_with_endpoint(
            &self.identity,
            &profile.nickname,
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
            None,
        )?;
        if let Some(peer_endpoint) = peer_endpoint {
            self.database.put_contact_peer_endpoint(&peer_endpoint)?;
            if let Some(transport) = &self.peer_transport {
                transport.authorize_contact(&peer_endpoint);
            }
            runtime_events.push(torchat_client_runtime::RuntimeEvent::PeerEndpointChanged {
                contact_id: peer_endpoint.installation_id.clone(),
                status: PeerEndpointStatus::Verified,
            });
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

    fn apply_pairing_peer_outcome(
        &mut self,
        pairing_id: &str,
        outcome: PairingPeerOutcome,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        let (_, runtime_events) =
            self.with_runtime(|runtime| runtime.apply_pairing_peer_outcome(pairing_id, outcome))?;
        Ok(runtime_events)
    }

    #[allow(clippy::too_many_arguments)]
    fn commit_contact_with_conversation(
        &mut self,
        card: torchat_core::relay::ContactCard,
        conversation: DirectConversation,
        pairing_invite_id: Option<&str>,
        consume_invite_id: Option<&str>,
        pending_welcome: Option<&PendingWelcomeRecord>,
        mls_inbox_snapshot: Option<&[u8]>,
        remove_pending_welcome_id: Option<&str>,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        let conversation_snapshot = conversation
            .snapshot()
            .map_err(|error| EngineError::Storage(error.to_string()))?;
        let (result, mut runtime_events): (WelcomeAcceptedResult, _) =
            self.with_runtime(|runtime| {
                if let Some(invite_id) = consume_invite_id {
                    if !runtime.storage_mut().consume_invite(invite_id)? {
                        return Err(RuntimeError::Conflict(
                            "contact invite was already consumed".to_owned(),
                        ));
                    }
                }
                let result = runtime.welcome_accepted(
                    contact_record_from_card(&card, false),
                    true,
                    pairing_invite_id.map(str::to_owned),
                )?;
                runtime.storage_mut().put_conversation_mls_snapshot(
                    &result.conversation.id,
                    &conversation_snapshot,
                )?;
                if let Some(snapshot) = mls_inbox_snapshot {
                    runtime.storage_mut().put_mls_inbox_snapshot(snapshot)?;
                }
                if let Some(pending) = pending_welcome {
                    runtime.storage_mut().put_pending_welcome(pending)?;
                }
                if let Some(invite_id) = remove_pending_welcome_id {
                    runtime.storage_mut().remove_pending_welcome(invite_id)?;
                }
                Ok(result)
            })?;
        self.conversations
            .insert(card.installation_id.clone(), conversation);
        runtime_events.extend(self.apply_pending_peer_endpoint(&card.installation_id)?);
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
                self.pending_engine_events.push(EngineEvent::Log {
                    log: EngineLogEvent {
                        level: "warn".to_owned(),
                        message: format!(
                            "contact confirmation enqueue failed pairing_id={} error={error}",
                            confirm.pairing_id
                        ),
                    },
                });
            } else {
                self.database
                    .complete_pending_contact_confirmation(&confirm.pairing_id)?;
            }
        }
        let _ = self.queue_relay_endpoint_bootstraps();
        Ok(runtime_events)
    }

    fn fresh_mls_member(&self) -> EngineResult<MlsMember> {
        MlsMember::create(self.identity.public_key().as_bytes())
            .map_err(|error| EngineError::Storage(format!("create MLS inbox state: {error}")))
    }

    fn snapshot_mls_inbox(&self) -> EngineResult<Vec<u8>> {
        self.mls_inbox
            .snapshot()
            .map_err(|error| EngineError::Storage(format!("snapshot MLS inbox state: {error}")))
    }

    fn restore_mls_inbox(&mut self, snapshot: &[u8]) -> EngineResult<()> {
        self.mls_inbox = MlsMember::restore(snapshot, self.identity.public_key().as_bytes())
            .map_err(|error| EngineError::Storage(format!("restore MLS inbox state: {error}")))?;
        Ok(())
    }
}

struct EngineRuntimeTransport<'a> {
    status: RuntimeTorStatus,
    relay: &'a mut dyn EngineRelay,
}

impl RuntimeTransport for EngineRuntimeTransport<'_> {
    fn connect(&mut self) -> torchat_client_runtime::RuntimeResult<RuntimeTorStatus> {
        Ok(self.status.clone())
    }

    fn status(&self) -> RuntimeTorStatus {
        self.status.clone()
    }

    fn update_profile(&mut self, nickname: &str) -> torchat_client_runtime::RuntimeResult<()> {
        self.relay.update_profile(nickname)
    }

    fn refresh_pairing_code(
        &mut self,
    ) -> torchat_client_runtime::RuntimeResult<torchat_client_runtime::InviteCode> {
        self.relay.refresh_pairing_code()
    }

    fn submit_pairing_code(
        &mut self,
        code: &str,
    ) -> torchat_client_runtime::RuntimeResult<torchat_client_runtime::PairingItem> {
        self.relay.submit_pairing_code(code)
    }

    fn pairing_inbox(
        &mut self,
    ) -> torchat_client_runtime::RuntimeResult<Vec<torchat_client_runtime::PairingItem>> {
        self.relay.pairing_inbox()
    }
}

fn identity_from_config(config: &EngineConfig) -> EngineResult<Identity> {
    let bytes: [u8; 32] = config
        .identity_private_key
        .expose()
        .try_into()
        .map_err(|_| {
            EngineError::InvalidConfig("identityPrivateKey must contain 32 bytes".to_owned())
        })?;
    Ok(Identity::from_private_key_bytes(bytes))
}

fn seed_runtime_identity(database: &mut ClientDatabase, identity: &Identity) -> EngineResult<()> {
    let mut storage = SqliteRuntimeStorage::new(database.transaction()?);
    storage
        .put_identity(RuntimeIdentity::from_parts(
            identity.installation_id(),
            identity.public_key(),
            identity.fingerprint(),
        ))
        .map_err(runtime_error)?;
    storage
        .ensure_profile(RuntimeProfile::from_parts(
            identity.installation_id(),
            String::new(),
            identity.public_key(),
            identity.fingerprint(),
        ))
        .map_err(runtime_error)?;
    storage.commit().map_err(runtime_error)?;
    Ok(())
}

fn load_engine_technical_state(
    database: &ClientDatabase,
    identity: &Identity,
) -> EngineResult<(
    MlsMember,
    HashMap<String, DirectConversation>,
    HashMap<String, PendingWelcomeRecord>,
)> {
    let mls_inbox = if let Some(snapshot) = database.mls_inbox_snapshot()? {
        MlsMember::restore(&snapshot, identity.public_key().as_bytes())
            .map_err(|error| EngineError::Storage(format!("restore MLS inbox snapshot: {error}")))?
    } else {
        let inbox = MlsMember::create(identity.public_key().as_bytes())
            .map_err(|error| EngineError::Storage(format!("create MLS inbox state: {error}")))?;
        let snapshot = inbox
            .snapshot()
            .map_err(|error| EngineError::Storage(format!("snapshot MLS inbox state: {error}")))?;
        database.put_mls_inbox_snapshot(&snapshot)?;
        inbox
    };

    let mut conversations = HashMap::new();
    for (conversation_id, snapshot) in database.conversation_mls_snapshots()? {
        let conversation = DirectConversation::restore(&snapshot).map_err(|error| {
            EngineError::Storage(format!(
                "restore MLS conversation snapshot for {conversation_id}: {error}"
            ))
        })?;
        conversations.insert(conversation_id, conversation);
    }

    let pending_welcomes = database
        .pending_welcomes(unix_secs())?
        .into_iter()
        .map(|record| (record.invite_id.clone(), record))
        .collect();

    Ok((mls_inbox, conversations, pending_welcomes))
}

fn unix_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system clock must be after unix epoch")
        .as_secs() as i64
}

fn unix_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system clock must be after unix epoch")
        .as_millis() as i64
}

fn retry_backoff_ms(attempt_count: u32) -> i64 {
    let shift = attempt_count.min(5);
    5_000_i64 * (1_i64 << shift)
}

fn stable_message_sequence(message_id: uuid::Uuid) -> u64 {
    let bytes = message_id.as_bytes();
    let mut sequence = [0_u8; 8];
    sequence.copy_from_slice(&bytes[..8]);
    u64::from_be_bytes(sequence).max(1)
}

fn encode_pairing_response_payload(
    effect: &torchat_client_runtime::PairingSendEffect,
    stored: &PairingResponseRecord,
) -> EngineResult<String> {
    match effect.kind {
        PairingSendKind::Offer => {
            let payload = effect
                .payload
                .clone()
                .or_else(|| {
                    stored
                        .offer_payload
                        .as_ref()
                        .map(|value| String::from_utf8_lossy(value).into_owned())
                })
                .ok_or_else(|| {
                    EngineError::InvalidCommand(
                        "runtime pairing offer payload is missing".to_owned(),
                    )
                })?;
            Ok(payload)
        }
        PairingSendKind::Rejection => RelayPayloadV1::pairing_rejected(effect.pairing_id.clone())
            .encode()
            .map_err(EngineError::InvalidCommand),
    }
}

fn runtime_error(error: torchat_client_runtime::RuntimeError) -> EngineError {
    match error {
        torchat_client_runtime::RuntimeError::Storage(message) => EngineError::Storage(message),
        other => EngineError::InvalidCommand(other.to_string()),
    }
}

fn json_response(value: impl serde::Serialize) -> EngineResult<ResponsePayload> {
    Ok(ResponsePayload::Json {
        value: serde_json::to_value(value).map_err(EngineError::from)?,
    })
}

fn error_code(error: &EngineError) -> &'static str {
    match error {
        EngineError::Closed(_) => "closed",
        EngineError::InvalidConfig(_) => "invalid_config",
        EngineError::InvalidCommand(_) => "invalid_command",
        EngineError::Serialization(_) => "serialization",
        EngineError::Storage(_) => "storage",
        EngineError::Transport(_) => "transport",
    }
}
