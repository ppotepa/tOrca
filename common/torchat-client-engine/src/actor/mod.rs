use std::{
    collections::{HashMap, HashSet},
    sync::Arc,
};

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::Serialize;
use sha2::{Digest, Sha256};

pub(crate) fn pairing_pair_key(left: &str, right: &str) -> String {
    let (first, second) = if left <= right {
        (left, right)
    } else {
        (right, left)
    };
    let mut input = Vec::with_capacity(first.len() + second.len() + 1);
    input.extend_from_slice(first.as_bytes());
    input.push(b':');
    input.extend_from_slice(second.as_bytes());
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(Sha256::digest(input))
}
use tokio::sync::mpsc;
use tokio::time::{Duration, Instant};
use tokio_util::sync::CancellationToken;
use torchat_client_runtime::{
    InviteState, MessageSendEffect, MessageTransportOutcome, PairingItem, PairingPeerOutcome,
    PairingPreparation, PairingSendKind, PeerConnectionStatus, PeerEndpointStatus, RuntimeClock, RuntimeError,
    RuntimeIdentity, RuntimeProfile, RuntimeSendEffect, RuntimeSession, RuntimeStatusPhase,
    RuntimeStorage, RuntimeTorStatus, RuntimeTransport, StartupReadinessSnapshot,
    SystemRuntimeClock, WelcomeAcceptedResult, contact_card_from_invite, contact_record_from_card,
};
use torchat_core::{
    ContactInvite, Identity,
    application::{ApplicationPayloadV1, ApplicationReply},
    mls::{DirectConversation, MlsMember},
    peer_protocol::{
        MAX_TRANSPORT_CIPHERTEXT_BYTES, PEER_VIRTUAL_PORT, PeerAck, PeerAckKind,
        PeerCiphertextPayload, PeerEndpointBundle, PeerEndpointUpdate,
    },
    relay::{RelayEnvelope, RelayPayloadV1},
};

use crate::anti_rollback::{
    AnchoredMlsCheckpoint, MlsEpochAnchor, MlsRecoveryState, validate_snapshot_checkpoint,
};
use crate::fault_injection::{FaultInjector, NoopFaultInjector};
use crate::{
    ClientDatabase, EngineCommand, EngineCommandEnvelope, EngineConfig, EngineError, EngineEvent,
    EngineLogEvent, EngineResult, PlatformAction, PlatformFact, PlatformKind,
    event::{
        ConnectionSnapshot, ConnectionState, NotificationRequest, ResponsePayload, ResponseResult,
    },
    peer::{PeerDeliveryTag, PeerOutboundCommand, PeerTransportEvent, PeerTransportHandle},
    probing::{ProbeCoordinator, ProbeKey, ProbeKind, ProbeStatus, pseudonymous_target_id},
    relay::{EngineRelay, RelayEvent, SharedRelayActor},
    storage::{
        DeliveryReceiptRecord, InboundEnvelopeStoreResult, PairingResponseRecord,
        PendingApplicationEnvelopeRecord, PendingLocalInviteMlsRecord,
        PendingPeerEndpointInboxRecord, PendingWelcomeRecord, ReceivedEnvelopeRecord,
        RetryDeadline, RetryKind, SqliteRuntimeStorage,
    },
};

mod application_envelope;
mod capabilities;
mod command_dispatch;
mod connection;
mod messaging;
mod pairing;
mod peer_control;
mod peer_event_policy;
mod peer_events;
mod platform_facts;
mod projection;
mod receipts;
mod relay_envelope;
mod relay_events;
mod retry_scheduler;
mod runtime_transaction;

fn error_kind(error: &EngineError) -> &'static str {
    match error {
        EngineError::Closed(_) => "closed",
        EngineError::InvalidConfig(_) => "invalid_config",
        EngineError::InvalidCommand(_) => "invalid_command",
        EngineError::Unsupported(_) => "unsupported",
        EngineError::Serialization(_) => "serialization",
        EngineError::Storage(_) => "storage",
        EngineError::Transport(_) => "transport",
    }
}

#[cfg(test)]
use platform_facts::runtime_phase_for_tor_ready;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ContactCapabilityStatusResponse {
    contact_id: String,
    capability_id: String,
    sequence: u64,
    status: torchat_client_runtime::CapabilityStatus,
}

#[derive(Clone, Debug)]
struct IdempotencyCommitContext {
    command_id: String,
    command_descriptor: String,
}

pub struct ClientEngineActor {
    pub(super) fault_injector: Arc<dyn FaultInjector>,
    pub(super) mls_anchor: Option<Box<dyn MlsEpochAnchor<Error = EngineError> + Send>>,
    /// Retain only platform metadata after construction. Database and identity
    /// secrets are consumed while opening the actor and must not have a second
    /// long-lived copy in actor memory.
    pub platform: PlatformKind,
    pub database: ClientDatabase,
    pub identity: Identity,
    pub conversations: HashMap<String, DirectConversation>,
    pub pending_welcomes: HashMap<String, PendingWelcomeRecord>,
    pending_engine_events: Vec<EngineEvent>,
    /// Process-local diagnostic count; durable receipt state remains in SQLite.
    receipt_queue_failed_after_commit: u64,
    active_peer_sessions: HashMap<String, HashSet<uuid::Uuid>>,
    crypto_blocked_peers: HashSet<String>,
    connection_generation: u64,
    app_foreground: bool,
    pub session: RuntimeSession,
    pub clock: SharedRuntimeClock,
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
    /// The next relay poll is actor state, not a per-loop local deadline.
    /// Recreating it after every command/event starves relay polling whenever
    /// the actor is busy with peer traffic or UI requests.
    relay_poll_at: Instant,
    probe_coordinator: ProbeCoordinator,
    connect_requested: bool,
    engine_session_id: String,
}

/// Cloneable clock handle shared by the actor and each temporary runtime
/// transaction. Tests can inject a deterministic implementation without
/// changing the production scheduler API.
#[derive(Clone)]
pub struct SharedRuntimeClock(Arc<dyn RuntimeClock + Send + Sync>);

impl SharedRuntimeClock {
    pub fn new(clock: impl RuntimeClock + Send + Sync + 'static) -> Self {
        Self(Arc::new(clock))
    }
}

impl Default for SharedRuntimeClock {
    fn default() -> Self {
        Self::new(SystemRuntimeClock)
    }
}

impl RuntimeClock for SharedRuntimeClock {
    fn now_ms(&self) -> i64 {
        self.0.now_ms()
    }
}

const RELAY_POLL_INTERVAL: Duration = Duration::from_millis(100);
const RETRY_BLOCKED_RECHECK: Duration = Duration::from_secs(5);
const RETRY_OFFLINE_RECHECK: Duration = Duration::from_secs(30);

impl ClientEngineActor {
    pub fn set_fault_injector(&mut self, injector: Arc<dyn FaultInjector>) {
        self.fault_injector = injector;
    }

    pub fn set_clock(&mut self, clock: impl RuntimeClock + Send + Sync + 'static) {
        self.clock = SharedRuntimeClock::new(clock);
    }

    pub fn new(config: EngineConfig) -> EngineResult<Self> {
        Self::new_with_optional_anchor(config, None)
    }

    /// Creates an actor while checking every restored MLS conversation
    /// against a platform-owned monotonic anchor before exposing it to the
    /// actor. The anchor is borrowed only during startup and is never copied
    /// into the actor state.
    pub fn new_with_anchor(
        config: EngineConfig,
        anchor: &mut dyn MlsEpochAnchor<Error = EngineError>,
    ) -> EngineResult<Self> {
        Self::new_with_optional_anchor(config, Some(anchor))
    }

    pub fn new_with_owned_anchor(
        config: EngineConfig,
        mut anchor: Box<dyn MlsEpochAnchor<Error = EngineError> + Send>,
    ) -> EngineResult<Self> {
        let mut actor = Self::new_with_optional_anchor(config, Some(anchor.as_mut()))?;
        actor.mls_anchor = Some(anchor);
        Ok(actor)
    }

    fn new_with_optional_anchor(
        config: EngineConfig,
        mut anchor: Option<&mut dyn MlsEpochAnchor<Error = EngineError>>,
    ) -> EngineResult<Self> {
        let identity = identity_from_config(&config)?;
        let mut database = ClientDatabase::open(&config.database_path, &config.database_key)?;
        // Recover claims left by a crashed/restarted process before loading
        // the technical state. Durable queues remain eligible for retry.
        database.requeue_after_disconnect(unix_ms())?;
        database.requeue_peer_deliveries(unix_ms())?;
        seed_runtime_identity(&mut database, &identity)?;
        database.delete_expired_pending_welcomes(unix_secs())?;
        database.delete_expired_pending_local_invite_mls(unix_secs())?;
        let (conversations, pending_welcomes) =
            load_engine_technical_state_with_anchor(&database, anchor.take())?;
        let crypto_blocked_peers = database.rejected_inbound_peer_senders()?;
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
        let platform = config.platform.clone();
        Ok(Self {
            fault_injector: Arc::new(NoopFaultInjector),
            mls_anchor: None,
            platform,
            database,
            identity,
            conversations,
            pending_welcomes,
            pending_engine_events: Vec::new(),
            receipt_queue_failed_after_commit: 0,
            active_peer_sessions: HashMap::new(),
            crypto_blocked_peers,
            connection_generation: 0,
            app_foreground: true,
            session: RuntimeSession::new(),
            clock: SharedRuntimeClock::default(),
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
            relay_poll_at: Instant::now() + RELAY_POLL_INTERVAL,
            probe_coordinator: ProbeCoordinator::new(Instant::now() + Duration::from_secs(30)),
            connect_requested: false,
            engine_session_id: uuid::Uuid::new_v4().to_string(),
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
            self.probe_coordinator.ensure(
                ProbeKey::contact(contact.installation_id.clone()),
                Instant::now(),
            );
            if let Some(endpoint) = self
                .database
                .contact_peer_endpoint(&contact.installation_id)?
            {
                self.database
                    .ensure_contact_endpoint_capability(&contact.installation_id)?;
                if let Some(base_endpoint) = self.local_peer_endpoint.clone() {
                    let (capability_id, secret) =
                        self.local_capability_credentials(&contact.installation_id)?;
                    let local_endpoint =
                        self.local_endpoint_for_contact(&contact.installation_id, &base_endpoint)?;
                    peer_transport.authorize_contact(
                        &endpoint,
                        local_endpoint,
                        capability_id,
                        secret,
                    );
                }
            }
        }
        let local_port = peer_transport.local_port();
        self.peer_transport = Some(peer_transport);
        for contact in self.list_contacts()? {
            for event in self.drain_pending_pre_welcome(&contact.installation_id)? {
                let _ = events.send(EngineEvent::Runtime { event }).await;
            }
        }
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
                    message: format!("peer listener bound on local port {local_port}"),
                },
            })
            .await;
        let _ = events
            .send(EngineEvent::Log {
                log: EngineLogEvent {
                    level: "info".to_owned(),
                    message: format!("client engine actor started for {:?}", self.platform),
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
            let relay_poll_at = self.relay_poll_at;
            let peer_probe_interval = if !self.network_online {
                Duration::from_secs(300)
            } else if self.battery_saver || self.device_idle || self.background_restricted {
                Duration::from_secs(180)
            } else if self.app_foreground {
                Duration::from_secs(30)
            } else {
                Duration::from_secs(120)
            };
            let peer_probe_at = self.probe_coordinator.next_round_at();
            let retry_deadline = self.next_retry_deadline()?;
            let retry_wakeup_at = self.next_retry_wakeup_at(retry_deadline)?;
            let retry_sleep_deadline =
                retry_wakeup_at.unwrap_or(relay_poll_at + Duration::from_secs(3600));
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
                    // Advance only after a real poll.  This preserves a
                    // stable cadence under command/P2P load while adapting
                    // the following interval to current platform policy.
                    self.relay_poll_at = Instant::now() + relay_poll_interval;
                }
                _ = tokio::time::sleep_until(peer_probe_at) => {
                    // Pairing expiry is local and must not depend on a relay
                    // status event or a UI refresh. This also prevents ACKed
                    // invitations from remaining pending forever offline.
                    if let Ok((_, runtime_events)) = self.with_runtime(|runtime| {
                        runtime.expire_pending_pairings()
                    }) {
                        for event in runtime_events {
                            let _ = events.send(EngineEvent::Runtime { event }).await;
                        }
                    }
                    let _ = self.retry_capability_deliveries();
                    let _ = self.queue_endpoint_update_probes();
                    let _ = self.queue_presence_heartbeats();
                    let now = Instant::now();
                    self.probe_coordinator.schedule_round(now, peer_probe_interval);
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
                    let command_id = envelope.command_id.clone();
                    let command_type = serde_json::to_value(&envelope.command)
                        .ok()
                        .and_then(|value| value.get("type").and_then(serde_json::Value::as_str).map(str::to_owned))
                        .unwrap_or_else(|| "unknown".to_owned());
                    let command_descriptor =
                        idempotency_descriptor(&envelope.command, &command_type);
                    if let Some(command_id) = command_id.as_deref()
                        && let Ok(Some((stored_type, result_json, _revision))) =
                            self.database.load_processed_command(command_id)
                    {
                            let result = if stored_type != command_descriptor {
                                ResponseResult::Error {
                                    code: "idempotency_conflict".to_owned(),
                                    message: "command id was already used for a different command"
                                        .to_owned(),
                                }
                            } else {
                                match serde_json::from_str::<ResponsePayload>(&result_json) {
                                    Ok(payload) => ResponseResult::Ok { payload },
                                    Err(_) => ResponseResult::Error {
                                        code: "idempotency_corrupt".to_owned(),
                                        message: "stored command result is invalid".to_owned(),
                                    },
                                }
                            };
                            let _ = events
                                .send(EngineEvent::Response {
                                    request_id: envelope.request_id,
                                    result,
                                })
                                .await;
                            if should_stop {
                                break;
                            }
                            continue;
                    }
                    let idempotency = command_id.as_ref().map(|command_id| {
                        IdempotencyCommitContext {
                            command_id: command_id.clone(),
                            command_descriptor: command_descriptor.clone(),
                        }
                    });
                    match self.handle_command(envelope.command, idempotency.as_ref()) {
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
                            if let Some(command_id) = command_id.as_deref()
                                && let Ok((_, revision)) = self.projection_head()
                                && let Ok(result_json) = serde_json::to_string(&payload)
                            {
                                let _ = self.database.save_processed_command(
                                    command_id,
                                    &command_descriptor,
                                    &result_json,
                                    revision,
                                );
                            }
                            let _ = events.send(EngineEvent::Response {
                                request_id: envelope.request_id,
                                result: ResponseResult::Ok {
                                    payload: payload.clone(),
                                },
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
            let recovered = self.handle_application_envelope(
                RelayEnvelope {
                    version: torchat_core::PROTOCOL_VERSION,
                    message_id,
                    sender: record.sender_installation_id.clone(),
                    recipient: self.identity.installation_id(),
                    ciphertext: wire_payload,
                },
                ciphertext,
            );
            match recovered {
                Ok(mut events) => {
                    runtime_events.append(&mut events);
                    self.database.complete_inbound_peer_envelope(
                        &record.sender_installation_id,
                        &record.message_id,
                    )?;
                }
                Err(error) => {
                    self.database.reject_inbound_peer_envelope(
                        &record.sender_installation_id,
                        &record.message_id,
                    )?;
                    self.crypto_blocked_peers
                        .insert(record.sender_installation_id.clone());
                    self.pending_engine_events.push(EngineEvent::Log {
                        log: EngineLogEvent {
                            level: "error".to_owned(),
                            message: format!(
                                "quarantined undecryptable peer envelope contact={} message_id={} error={error}",
                                record.sender_installation_id, record.message_id
                            ),
                        },
                    });
                    runtime_events.push(
                        torchat_client_runtime::RuntimeEvent::PeerConnectionChanged {
                            contact_id: record.sender_installation_id,
                            status: PeerConnectionStatus::Backoff,
                            retry_in_ms: None,
                        },
                    );
                }
            }
        }
        Ok(runtime_events)
    }

    fn requeue_after_disconnect(&mut self) -> EngineResult<()> {
        let now_ms = self.clock.now_ms();
        self.database.requeue_after_disconnect(now_ms)?;
        self.database.requeue_peer_deliveries(now_ms)?;
        Ok(())
    }

    fn queue_notification(&mut self, notification: NotificationRequest) {
        if !self.app_foreground {
            self.pending_engine_events
                .push(EngineEvent::NotificationRequested { notification });
        }
    }

    fn queue_relay_envelope(
        &mut self,
        envelope_id: uuid::Uuid,
        recipient: &str,
        ciphertext: &str,
    ) -> EngineResult<()> {
        self.relay
            .send_envelope(envelope_id, recipient, ciphertext)
            .map_err(runtime_error)?;
        Ok(())
    }

    fn send_ephemeral_payload(
        &mut self,
        conversation_id: &str,
        application: ApplicationPayloadV1,
    ) -> EngineResult<()> {
        // OpenMLS application encryption advances the sender generation. A
        // typing/presence/read frame cannot use a lossy latest-only queue:
        // dropping it would make the next durable message undecryptable.
        // Keep these signals off until they use a non-ratcheting authenticated
        // channel or the same durable delivery semantics as chat messages.
        const EPHEMERAL_MLS_DELIVERY_SAFE: bool = false;
        let capability_frame = matches!(
            &application,
            ApplicationPayloadV1::CapabilityOffer { .. }
                | ApplicationPayloadV1::CapabilityOfferAck { .. }
                | ApplicationPayloadV1::CapabilityRevoked { .. }
                | ApplicationPayloadV1::RelationshipRemoved { .. }
        );
        let removal_delivery_id = match &application {
            ApplicationPayloadV1::RelationshipRemoved {
                removal_id: Some(removal_id),
                ..
            } => Some(removal_id.to_string()),
            _ => None,
        };
        if capability_frame && (!self.network_online || self.socks5_url.is_none()) {
            return Err(EngineError::Transport(
                "Tor peer transport is not ready for capability bootstrap".to_owned(),
            ));
        }
        if !EPHEMERAL_MLS_DELIVERY_SAFE && !capability_frame {
            let feature = match application {
                ApplicationPayloadV1::Typing { .. } => "typing indicators",
                ApplicationPayloadV1::Presence { .. } => "presence signals",
                ApplicationPayloadV1::ReadReceipt { .. } => "read receipts",
                _ => "ephemeral signals",
            };
            return Err(EngineError::Unsupported(format!(
                "{feature} are disabled until they have durable, ratchet-safe delivery"
            )));
        }
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
        let requires_ack = matches!(
            application,
            ApplicationPayloadV1::CapabilityOffer { .. }
                | ApplicationPayloadV1::RelationshipRemoved { .. }
        );
        if let Err(error) = self.dispatch_ephemeral_payload(
            conversation_id,
            payload,
            capability_frame,
            requires_ack,
            removal_delivery_id,
        ) {
            let restored = DirectConversation::restore(&snapshot_before)
                .map_err(|restore| EngineError::Storage(restore.to_string()))?;
            self.database
                .put_conversation_mls_snapshot(conversation_id, &snapshot_before)?;
            self.conversations
                .insert(conversation_id.to_owned(), restored);
            return Err(error);
        }
        Ok(())
    }

    fn dispatch_ephemeral_payload(
        &mut self,
        installation_id: &str,
        payload: String,
        capability_frame: bool,
        requires_ack: bool,
        removal_delivery_id: Option<String>,
    ) -> EngineResult<()> {
        let _ = (capability_frame, requires_ack, removal_delivery_id);
        let envelope_id = uuid::Uuid::new_v4();
        self.queue_peer_payload(
            envelope_id,
            installation_id,
            installation_id,
            stable_message_sequence(envelope_id),
            payload.into_bytes(),
            PeerDeliveryTag::Ephemeral,
        )
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
            // Accepted rendezvous pairings deliver the MLS Welcome directly
            // from accept_invite. The old retry effect reused the original
            // ContactInvite as if it were a RelayPayloadV1 response, which
            // produced invalid relay payload encoding and could not repair a
            // pairing. Only rejection still uses the generic envelope path.
            if pairing.kind == torchat_client_runtime::PairingSendKind::Offer {
                return Ok(());
            }
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
        self.flush_pending_relationship_removal_acks()?;
        self.flush_pending_relationship_removals()?;
        Ok(())
    }

    fn flush_pending_relationship_removal_acks(&mut self) -> EngineResult<()> {
        for ack in self
            .database
            .due_relationship_removal_acks(self.clock.now_ms())?
        {
            let payload = String::from_utf8(ack.payload).map_err(|_| {
                EngineError::Storage("relationship removal ACK payload is not UTF-8".to_owned())
            })?;
            let envelope_id = uuid::Uuid::new_v4();
            if self
                .queue_peer_payload(
                    envelope_id,
                    &ack.contact_installation_id,
                    &ack.contact_installation_id,
                    stable_message_sequence(envelope_id),
                    payload.into_bytes(),
                    PeerDeliveryTag::RelationshipRemovalAck {
                        removal_id: ack.removal_id.clone(),
                    },
                )
                .is_ok()
            {
                self.database.mark_relationship_removal_ack_dispatched(
                    &ack.removal_id,
                    self.clock.now_ms() + retry_backoff_ms(ack.attempt_count + 1),
                )?;
            }
        }
        Ok(())
    }

    fn flush_pending_relationship_removals(&mut self) -> EngineResult<()> {
        use torchat_core::application::ApplicationPayloadV1;

        for removal in self
            .database
            .due_relationship_removals(self.clock.now_ms())?
        {
            let message_id = match uuid::Uuid::parse_str(&removal.removal_id) {
                Ok(value) => value,
                Err(error) => {
                    self.pending_engine_events.push(EngineEvent::Log {
                        log: EngineLogEvent {
                            level: "warn".to_owned(),
                            message: format!("invalid relationship removal id: {error}"),
                        },
                    });
                    continue;
                }
            };
            let payload = ApplicationPayloadV1::RelationshipRemoved {
                version: 1,
                message_id,
                removed_at: removal.removed_at,
                preserve_history: removal.preserve_history,
                relationship_epoch: Some(removal.relationship_epoch),
                removal_id: Some(message_id),
            };
            if let Err(error) =
                self.send_ephemeral_payload(&removal.contact_installation_id, payload)
            {
                self.pending_engine_events.push(EngineEvent::Log {
                    log: EngineLogEvent {
                        level: "debug".to_owned(),
                        message: format!("relationship removal dispatch deferred: {error}"),
                    },
                });
                continue;
            }
            self.database.mark_relationship_removal_dispatched(
                &removal.removal_id,
                self.clock.now_ms() + retry_backoff_ms(removal.attempt_count + 1),
            )?;
        }
        Ok(())
    }

    fn peer_retry_in_ms(&self, installation_id: &str) -> EngineResult<Option<u64>> {
        let now = self.clock.now_ms();
        let outbound = self
            .database
            .next_contact_peer_retry_deadline_ms(installation_id)?;
        let receipt = self
            .database
            .next_contact_receipt_retry_deadline_ms(installation_id)?;
        Ok(outbound
            .into_iter()
            .chain(receipt)
            .min()
            .map(|deadline| deadline.saturating_sub(now) as u64))
    }

    fn fresh_mls_member(&self) -> EngineResult<MlsMember> {
        MlsMember::create(self.identity.public_key().as_bytes())
            .map_err(|error| EngineError::Storage(format!("create MLS inbox state: {error}")))
    }
}

struct EngineRuntimeTransport<'a> {
    status: RuntimeTorStatus,
    _actor: std::marker::PhantomData<&'a mut dyn EngineRelay>,
}

impl RuntimeTransport for EngineRuntimeTransport<'_> {
    fn connect(&mut self) -> torchat_client_runtime::RuntimeResult<RuntimeTorStatus> {
        Ok(self.status.clone())
    }

    fn status(&self) -> RuntimeTorStatus {
        self.status.clone()
    }

    fn refresh_pairing_code(
        &mut self,
    ) -> torchat_client_runtime::RuntimeResult<torchat_client_runtime::InviteCode> {
        Err(torchat_client_runtime::RuntimeError::Unavailable(
            "relay HTTP effects must be executed outside RuntimeSession".to_owned(),
        ))
    }

    fn submit_pairing_code(
        &mut self,
        code: &str,
    ) -> torchat_client_runtime::RuntimeResult<torchat_client_runtime::PairingItem> {
        let _ = code;
        Err(torchat_client_runtime::RuntimeError::Unavailable(
            "relay HTTP effects must be executed outside RuntimeSession".to_owned(),
        ))
    }

    fn pairing_inbox(
        &mut self,
    ) -> torchat_client_runtime::RuntimeResult<Vec<torchat_client_runtime::PairingItem>> {
        Err(torchat_client_runtime::RuntimeError::Unavailable(
            "relay HTTP effects must be executed outside RuntimeSession".to_owned(),
        ))
    }
}

/// Couples an idempotency key to the complete command payload, not merely to
/// its command kind. A caller reusing an id for a different recipient/body is
/// rejected instead of receiving a stale success response.
fn idempotency_descriptor(command: &EngineCommand, command_type: &str) -> String {
    let encoded = serde_json::to_vec(command).unwrap_or_default();
    let digest = URL_SAFE_NO_PAD.encode(Sha256::digest(encoded));
    format!("{command_type}:{digest}")
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

fn protocol_nickname(installation_id: &str, nickname: &str) -> String {
    let trimmed = nickname.trim();
    if trimmed.chars().count() >= 2 {
        return trimmed.chars().take(32).collect();
    }
    let trimmed_installation_id = installation_id.trim();
    if trimmed_installation_id.starts_with("peer-") && trimmed_installation_id.chars().count() >= 2
    {
        return trimmed_installation_id.chars().take(32).collect();
    }
    let suffix = installation_id.chars().take(8).collect::<String>();
    format!("peer-{suffix}")
}

/// Loads MLS state with an optional platform secure-store anti-rollback gate.
/// Hosts that have a secure anchor must pass it here before exposing the
/// conversations to the actor.
pub(crate) fn load_engine_technical_state_with_anchor(
    database: &ClientDatabase,
    mut anchor: Option<&mut dyn MlsEpochAnchor<Error = EngineError>>,
) -> EngineResult<(
    HashMap<String, DirectConversation>,
    HashMap<String, PendingWelcomeRecord>,
)> {
    let mut conversations = HashMap::new();
    for (conversation_id, snapshot) in database.conversation_mls_snapshots()? {
        let conversation = DirectConversation::restore(&snapshot).map_err(|error| {
            let action = if error.contains("unsupported MLS")
                || error.contains("invalid MLS snapshot header")
            {
                "re-pair required"
            } else {
                "repair local data or re-pair"
            };
            EngineError::Storage(format!(
                "restore MLS conversation snapshot for {conversation_id}: {error}; {action}"
            ))
        })?;
        if let Some(anchor) = anchor.as_deref_mut() {
            let checkpoint = database
                .conversation_mls_checkpoint(&conversation_id)?
                .map(|record| AnchoredMlsCheckpoint {
                    state_version: record.state_version,
                    epoch: conversation.epoch(),
                    snapshot_hash: record.snapshot_hash.unwrap_or_default(),
                })
                .unwrap_or_else(|| AnchoredMlsCheckpoint {
                    state_version: conversation.epoch(),
                    epoch: conversation.epoch(),
                    snapshot_hash: Vec::new(),
                });
            match validate_snapshot_checkpoint(anchor, &conversation_id, &checkpoint)? {
                MlsRecoveryState::Ready => {}
                MlsRecoveryState::RePairRequired => {
                    return Err(EngineError::Storage(format!(
                        "MLS conversation snapshot for {conversation_id}: re-pair required"
                    )));
                }
            }
        }
        conversations.insert(conversation_id, conversation);
    }

    let pending_welcomes = database
        .pending_welcomes(unix_secs())?
        .into_iter()
        .map(|record| (record.invite_id.clone(), record))
        .collect();

    Ok((conversations, pending_welcomes))
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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct RetryPolicy {
    pub max_attempts: u32,
    pub base_delay_ms: i64,
    pub max_delay_ms: i64,
    pub max_age_ms: i64,
}

impl RetryPolicy {
    pub const DELIVERY: Self = Self {
        max_attempts: 8,
        base_delay_ms: 5_000,
        max_delay_ms: 160_000,
        max_age_ms: 24 * 60 * 60 * 1_000,
    };

    pub const CONTROL_PLANE: Self = Self {
        max_attempts: 8,
        base_delay_ms: 5_000,
        max_delay_ms: 160_000,
        max_age_ms: 24 * 60 * 60 * 1_000,
    };

    pub const PAIRING: Self = Self {
        max_attempts: 6,
        base_delay_ms: 2_000,
        max_delay_ms: 120_000,
        max_age_ms: 30 * 60 * 1_000,
    };

    pub const RECEIPT: Self = Self {
        max_attempts: 8,
        base_delay_ms: 3_000,
        max_delay_ms: 120_000,
        max_age_ms: 12 * 60 * 60 * 1_000,
    };

    pub fn for_kind(kind: RetryKind) -> Self {
        match kind {
            RetryKind::MessageSend | RetryKind::MessageAckDeadline => Self::DELIVERY,
            RetryKind::Receipt | RetryKind::ReadReceipt => Self::RECEIPT,
            RetryKind::PendingWelcome | RetryKind::PairingResponse => Self::PAIRING,
            RetryKind::RelationshipRemoval | RetryKind::RelationshipRemovalAck => {
                Self::CONTROL_PLANE
            }
        }
    }

    pub fn delay_ms(self, attempt_count: u32) -> i64 {
        let shift = attempt_count.min(5);
        (self.base_delay_ms * (1_i64 << shift)).min(self.max_delay_ms)
    }

    pub fn full_jitter_ms<R: RetryJitter>(self, attempt_count: u32, rng: &mut R) -> i64 {
        rng.sample(self.delay_ms(attempt_count))
    }

    pub fn exhausted(self, attempt_count: u32) -> bool {
        attempt_count >= self.max_attempts
    }

    pub fn age_exhausted(self, created_at_ms: i64, now_ms: i64) -> bool {
        now_ms.saturating_sub(created_at_ms) >= self.max_age_ms
    }
}

pub(super) trait RetryJitter {
    fn sample(&mut self, upper_inclusive_ms: i64) -> i64;
}

/// Injectable retry randomness boundary used by deterministic resilience
/// tests. Production uses `SystemRetryJitter`; harnesses can provide a fixed
/// sequence without touching scheduling logic.
pub(super) trait RetryRandom: RetryJitter {}

impl<T: RetryJitter> RetryRandom for T {}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum RetryDisposition {
    Transient,
    Permanent,
    Authentication,
    Protocol,
}

pub(super) fn classify_retry_error(error: &str) -> RetryDisposition {
    let normalized = error.to_ascii_lowercase();
    if normalized.contains("authentication")
        || normalized.contains("invalid capability")
        || normalized.contains("unauthorized")
    {
        RetryDisposition::Authentication
    } else if normalized.contains("protocol")
        || normalized.contains("malformed")
        || normalized.contains("unsupported")
        || normalized.contains("frame exceeds")
        || normalized.contains("safe frame budget")
    {
        RetryDisposition::Protocol
    } else if normalized.contains("permanent")
        || normalized.contains("invalid command")
        || normalized.contains("not found")
    {
        RetryDisposition::Permanent
    } else {
        RetryDisposition::Transient
    }
}

pub(super) fn retry_error_code(error: &str) -> &'static str {
    match classify_retry_error(error) {
        RetryDisposition::Transient => "transient",
        RetryDisposition::Permanent => "permanent",
        RetryDisposition::Authentication => "authentication",
        RetryDisposition::Protocol => "protocol",
    }
}

struct SystemRetryJitter;

impl RetryJitter for SystemRetryJitter {
    fn sample(&mut self, upper_inclusive_ms: i64) -> i64 {
        if upper_inclusive_ms <= 0 {
            return 0;
        }
        let mut bytes = [0_u8; 8];
        if getrandom::fill(&mut bytes).is_err() {
            return 0;
        }
        (u64::from_le_bytes(bytes) % (upper_inclusive_ms as u64 + 1)) as i64
    }
}

fn retry_backoff_ms(attempt_count: u32) -> i64 {
    retry_backoff_with(attempt_count, &mut SystemRetryJitter)
}

fn pairing_retry_backoff_ms(attempt_count: u32) -> i64 {
    RetryPolicy::PAIRING.full_jitter_ms(attempt_count, &mut SystemRetryJitter)
}

fn retry_backoff_with<R: RetryRandom>(attempt_count: u32, random: &mut R) -> i64 {
    RetryPolicy::DELIVERY.full_jitter_ms(attempt_count, random)
}

#[cfg(test)]
mod retry_policy_tests {
    use super::{
        RetryDisposition, RetryJitter, RetryPolicy, classify_retry_error, retry_backoff_with,
        retry_error_code,
    };
    use crate::storage::RetryKind;

    struct FixedJitter(i64);

    impl RetryJitter for FixedJitter {
        fn sample(&mut self, upper_inclusive_ms: i64) -> i64 {
            self.0.min(upper_inclusive_ms)
        }
    }

    #[test]
    fn delivery_policy_caps_backoff_and_exhaustion() {
        let policy = RetryPolicy::DELIVERY;
        assert_eq!(policy.delay_ms(0), 5_000);
        assert_eq!(policy.delay_ms(5), 160_000);
        assert_eq!(policy.delay_ms(99), 160_000);
        assert_eq!(policy.full_jitter_ms(0, &mut FixedJitter(123)), 123);
        assert_eq!(policy.full_jitter_ms(5, &mut FixedJitter(999_999)), 160_000);
        assert!(!policy.exhausted(7));
        assert!(policy.exhausted(8));
        assert!(!policy.age_exhausted(100_000, 100_000 + policy.max_age_ms - 1));
        assert!(policy.age_exhausted(100_000, 100_000 + policy.max_age_ms));
        assert_eq!(
            classify_retry_error("peer frame exceeds size limit"),
            RetryDisposition::Protocol
        );
        assert_eq!(
            classify_retry_error("invalid capability authentication"),
            RetryDisposition::Authentication
        );
        assert_eq!(
            classify_retry_error("relay connection reset"),
            RetryDisposition::Transient
        );
        assert_eq!(
            retry_error_code("invalid capability authentication"),
            "authentication"
        );
        assert_eq!(retry_error_code("malformed peer frame"), "protocol");
        assert_eq!(
            retry_error_code("permanent: contact not found"),
            "permanent"
        );
    }

    #[test]
    fn retry_backoff_accepts_deterministic_randomness() {
        let mut random = FixedJitter(42);
        assert_eq!(retry_backoff_with(0, &mut random), 42);
    }

    #[test]
    fn every_durable_retry_kind_has_a_bounded_policy() {
        let kinds = [
            RetryKind::MessageSend,
            RetryKind::MessageAckDeadline,
            RetryKind::Receipt,
            RetryKind::PendingWelcome,
            RetryKind::PairingResponse,
            RetryKind::ReadReceipt,
            RetryKind::RelationshipRemoval,
            RetryKind::RelationshipRemovalAck,
        ];
        for kind in kinds {
            let policy = RetryPolicy::for_kind(kind);
            assert!(policy.max_attempts > 0);
            assert!(policy.max_age_ms > 0);
            assert!(policy.max_delay_ms >= policy.base_delay_ms);
        }
    }

    #[test]
    fn pairing_retry_uses_the_faster_pairing_policy() {
        assert_eq!(RetryPolicy::PAIRING.delay_ms(0), 2_000);
        assert_eq!(RetryPolicy::PAIRING.delay_ms(5), 64_000);
        assert_eq!(RetryPolicy::PAIRING.delay_ms(20), 64_000);
        assert!(RetryPolicy::PAIRING.delay_ms(0) < RetryPolicy::DELIVERY.delay_ms(0));
    }
}

fn is_expected_peer_shutdown(error: &str) -> bool {
    let normalized = error.to_ascii_lowercase();
    normalized.contains("peer websocket closed")
        || normalized.contains("connection reset without closing handshake")
        || normalized.contains("connection reset by peer")
}

fn peer_endpoint_requires_update(
    previous: Option<&PeerEndpointBundle>,
    endpoint: &PeerEndpointBundle,
    now_secs: i64,
) -> Result<bool, String> {
    match previous {
        Some(previous) => {
            if endpoint.sequence <= previous.sequence {
                return Ok(false);
            }
            endpoint.validate_successor(previous, now_secs)?;
            Ok(true)
        }
        None => {
            endpoint.validate(now_secs)?;
            Ok(true)
        }
    }
}

fn stable_message_sequence(message_id: uuid::Uuid) -> u64 {
    let bytes = message_id.as_bytes();
    let mut sequence = [0_u8; 8];
    sequence.copy_from_slice(&bytes[..8]);
    u64::from_be_bytes(sequence).max(1)
}

fn endpoint_capability_id(endpoint: &PeerEndpointBundle) -> String {
    endpoint
        .capabilities
        .iter()
        .find_map(|value| value.strip_prefix("contact_endpoint_v1:"))
        .unwrap_or_default()
        .to_owned()
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
        EngineError::Unsupported(_) => "unsupported",
        EngineError::Serialization(_) => "serialization",
        EngineError::Storage(_) => "storage",
        EngineError::Transport(_) => "transport",
    }
}

fn relay_probe_state(
    phase: &torchat_client_runtime::RuntimeStatusPhase,
) -> torchat_client_runtime::TransportProbeState {
    match phase {
        torchat_client_runtime::RuntimeStatusPhase::Starting
        | torchat_client_runtime::RuntimeStatusPhase::Bootstrapping
        | torchat_client_runtime::RuntimeStatusPhase::Connecting
        | torchat_client_runtime::RuntimeStatusPhase::Reconnecting => {
            torchat_client_runtime::TransportProbeState::Starting
        }
        torchat_client_runtime::RuntimeStatusPhase::Connected => {
            torchat_client_runtime::TransportProbeState::Ready
        }
        torchat_client_runtime::RuntimeStatusPhase::Degraded => {
            torchat_client_runtime::TransportProbeState::Degraded
        }
        torchat_client_runtime::RuntimeStatusPhase::Offline
        | torchat_client_runtime::RuntimeStatusPhase::Error => {
            torchat_client_runtime::TransportProbeState::Error
        }
    }
}

#[allow(clippy::too_many_arguments)] // mirrors the generated transport-status contract.
fn transport_status_event(
    component: torchat_client_runtime::TransportComponent,
    state: torchat_client_runtime::TransportProbeState,
    detail: impl Into<String>,
    progress: Option<i32>,
    latency_ms: Option<u64>,
    retry_attempt: u32,
    retry_in_ms: Option<u64>,
    generation: u64,
    endpoint: Option<String>,
    updated_at_ms: i64,
) -> torchat_client_runtime::RuntimeEvent {
    torchat_client_runtime::RuntimeEvent::TransportStatusChanged {
        component,
        state,
        detail: detail.into(),
        progress,
        latency_ms,
        retry_attempt,
        retry_in_ms,
        generation,
        endpoint,
        updated_at: updated_at_ms,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        idempotency_descriptor, is_expected_peer_shutdown, peer_endpoint_requires_update,
        pairing_pair_key, protocol_nickname, runtime_phase_for_tor_ready,
    };
    use crate::EngineCommand;
    use crate::event::ConnectionState;
    use torchat_client_runtime::RuntimeStatusPhase;
    use torchat_core::Identity;
    use torchat_core::peer_protocol::PeerEndpointBundle;

    fn test_endpoint(identity: &Identity, sequence: u64) -> PeerEndpointBundle {
        PeerEndpointBundle::new(
            identity,
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.onion",
            sequence,
            1_700_000_000,
            Some(1_800_000_600),
        )
    }

    #[test]
    fn protocol_nickname_uses_profile_when_present() {
        assert_eq!(protocol_nickname("abcdefgh12345678", " Alice "), "Alice");
    }

    #[test]
    fn protocol_nickname_falls_back_when_profile_is_missing() {
        assert_eq!(protocol_nickname("abcdefgh12345678", " "), "peer-abcdefgh");
    }

    #[test]
    fn protocol_nickname_keeps_existing_peer_prefix() {
        assert_eq!(protocol_nickname("peer-1", " "), "peer-1");
    }

    #[test]
    fn tor_ready_without_relay_connection_remains_ready() {
        assert_eq!(
            runtime_phase_for_tor_ready(&ConnectionState::Disconnected),
            RuntimeStatusPhase::Connected
        );
    }

    #[test]
    fn tor_ready_with_relay_backoff_remains_ready() {
        assert_eq!(
            runtime_phase_for_tor_ready(&ConnectionState::Backoff {
                attempt: 2,
                retry_in_ms: 2_000,
            }),
            RuntimeStatusPhase::Connected
        );
    }

    #[test]
    fn expected_peer_shutdowns_are_downgraded() {
        assert!(is_expected_peer_shutdown(
            "read peer frame: WebSocket protocol error: Connection reset without closing handshake"
        ));
        assert!(is_expected_peer_shutdown("peer websocket closed"));
        assert!(!is_expected_peer_shutdown("peer client proof is invalid"));
    }

    #[test]
    fn older_peer_endpoint_is_ignored() {
        let identity = Identity::generate();
        let previous = test_endpoint(&identity, 7);
        let older = test_endpoint(&identity, 6);
        assert!(
            !peer_endpoint_requires_update(Some(&previous), &older, 1_800_000_000)
                .expect("older endpoint should be ignored")
        );
    }

    #[test]
    fn newer_peer_endpoint_requires_valid_successor() {
        let identity = Identity::generate();
        let previous = test_endpoint(&identity, 7);
        let newer = test_endpoint(&identity, 8);
        assert!(
            peer_endpoint_requires_update(Some(&previous), &newer, 1_800_000_000)
                .expect("newer successor should be accepted")
        );
    }

    #[test]
    fn idempotency_descriptor_binds_command_payload() {
        let bootstrap = idempotency_descriptor(&EngineCommand::Bootstrap, "bootstrap");
        let connect = idempotency_descriptor(&EngineCommand::Connect, "connect");
        assert_ne!(bootstrap, connect);
        assert!(bootstrap.starts_with("bootstrap:"));
    }

    #[test]
    fn pairing_pair_key_is_symmetric_and_stable() {
        let left = pairing_pair_key("installation-a", "installation-b");
        let right = pairing_pair_key("installation-b", "installation-a");
        assert_eq!(left, right);
        assert_eq!(left, pairing_pair_key("installation-a", "installation-b"));
        assert_ne!(left, pairing_pair_key("installation-a", "installation-c"));
    }
}
