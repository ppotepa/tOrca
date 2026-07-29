use std::{collections::HashMap, mem};

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use sha2::{Digest, Sha256};
use serde_json::json;
use tokio::sync::mpsc;
use tokio::time::{Duration, Instant};
use tokio_util::sync::CancellationToken;
use torchat_client_runtime::{
    ClientRuntime, MessageTransportOutcome, PairingPeerOutcome, PairingPreparation,
    PairingSendKind, PairingSyncResult, RuntimeIdentity, RuntimeProfile, RuntimeRequest,
    RuntimeClock, RuntimeResponse, RuntimeSendEffect, RuntimeSession, RuntimeStorage, RuntimeTorStatus,
    RuntimeTransport, RuntimeStatusPhase, SystemRuntimeClock, WelcomeAcceptedResult,
    contact_card_from_invite, contact_record_from_card,
};
use torchat_core::{
    ContactInvite,
    Identity,
    application::ApplicationPayloadV1,
    mls::{DirectConversation, MlsMember},
    relay::{RelayEnvelope, RelayPayloadV1},
};

use crate::{
    ClientDatabase, EngineCommand, EngineCommandEnvelope, EngineConfig, EngineError, EngineEvent,
    EngineLogEvent, EngineResult, PlatformFact,
    event::{ConnectionSnapshot, ConnectionState, ResponsePayload, ResponseResult},
    relay::{EngineRelay, RelayEvent, SharedRelayActor},
    storage::{
        DeliveryReceiptRecord, PairingResponseRecord, PendingWelcomeRecord, ReceivedEnvelopeRecord,
        RetryDeadline, RetryKind, SqliteRuntimeStorage,
    },
};

pub struct ClientEngineActor {
    pub config: EngineConfig,
    pub database: ClientDatabase,
    pub identity: Identity,
    pub mls_inbox: MlsMember,
    pub conversations: HashMap<String, DirectConversation>,
    pub pending_welcomes: HashMap<String, PendingWelcomeRecord>,
    pub session: RuntimeSession,
    pub clock: SystemRuntimeClock,
    pub connection_state: ConnectionState,
    pub tor_status: RuntimeTorStatus,
    pub socks5_url: Option<String>,
    pub relay: Box<dyn EngineRelay>,
}

const RELAY_POLL_INTERVAL: Duration = Duration::from_millis(100);

impl ClientEngineActor {
    pub fn new(config: EngineConfig) -> EngineResult<Self> {
        let identity = identity_from_config(&config)?;
        let mut database = ClientDatabase::open(&config.database_path, &config.database_key)?;
        seed_runtime_identity(&mut database, &identity)?;
        let (mls_inbox, conversations, pending_welcomes) =
            load_engine_technical_state(&database, &identity)?;
        let relay_identity = identity_from_config(&config)?;
        let initial_socks5_url = config.initial_socks5_url.as_ref().map(ToString::to_string);
        let relay_onion_url = config.relay_onion_url.clone();
        Ok(Self {
            config,
            database,
            identity,
            mls_inbox,
            conversations,
            pending_welcomes,
            session: RuntimeSession::new(),
            clock: SystemRuntimeClock,
            connection_state: ConnectionState::WaitingForTor,
            tor_status: RuntimeTorStatus {
                phase: RuntimeStatusPhase::Starting,
                label: "starting".to_owned(),
                detail: "engine initialized".to_owned(),
                progress: None,
                latency_ms: None,
                retry_attempt: 0,
            },
            socks5_url: None,
            relay: Box::new(SharedRelayActor::new(
                relay_onion_url,
                initial_socks5_url,
                relay_identity,
            )),
        })
    }

    pub async fn run(
        mut self,
        mut commands: mpsc::Receiver<EngineCommandEnvelope>,
        events: mpsc::Sender<EngineEvent>,
        shutdown: CancellationToken,
    ) -> EngineResult<()> {
        let _ = events
            .send(EngineEvent::Connection(ConnectionSnapshot {
                state: self.connection_state.clone(),
                generation: 0,
                detail: "engine actor initialized".to_owned(),
            }))
            .await;
        let _ = events
            .send(EngineEvent::Log(EngineLogEvent {
                level: "info".to_owned(),
                message: format!("client engine actor started for {:?}", self.config.platform),
            }))
            .await;

        loop {
            let relay_poll_at = Instant::now() + RELAY_POLL_INTERVAL;
            let retry_deadline = self.next_retry_deadline()?;
            let retry_wakeup_at = self.next_retry_wakeup_at(retry_deadline)?;
            let retry_sleep_deadline =
                retry_wakeup_at.unwrap_or(relay_poll_at + Duration::from_secs(3600));
            tokio::select! {
                _ = shutdown.cancelled() => break,
                _ = tokio::time::sleep_until(relay_poll_at) => {
                    self.drain_relay_events(&events).await;
                }
                _ = tokio::time::sleep_until(retry_sleep_deadline), if retry_wakeup_at.is_some() => {
                    self.run_retry_scheduler(&events, retry_deadline.expect("retry deadline is present")).await;
                }
                envelope = commands.recv() => {
                    let Some(envelope) = envelope else {
                        break;
                    };
                    if matches!(envelope.command, EngineCommand::Shutdown) {
                        self.connection_state = ConnectionState::Stopped;
                        let _ = events.send(EngineEvent::Connection(ConnectionSnapshot {
                            state: self.connection_state.clone(),
                            generation: 0,
                            detail: "shutdown requested".to_owned(),
                        })).await;
                        let _ = events.send(EngineEvent::Response {
                            request_id: envelope.request_id,
                            result: ResponseResult::Ok {
                                payload: ResponsePayload::Empty,
                            },
                        }).await;
                        break;
                    }
                    match self.handle_command(envelope.command) {
                        Ok((payload, runtime_events, connection_snapshot)) => {
                            if let Some(snapshot) = connection_snapshot {
                                let _ = events.send(EngineEvent::Connection(snapshot)).await;
                            }
                            for event in runtime_events {
                                let _ = events.send(EngineEvent::Runtime(event)).await;
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
                Ok((
                    ResponsePayload::Json {
                        value: serde_json::to_value(bootstrapped).map_err(EngineError::from)?,
                    },
                    runtime_events,
                    None,
                ))
            }
            EngineCommand::GetIdentity => Ok((
                ResponsePayload::Json {
                    value: serde_json::to_value(self.runtime_identity()?).map_err(EngineError::from)?,
                },
                Vec::new(),
                None,
            )),
            EngineCommand::GetProfile => Ok((
                ResponsePayload::Json {
                    value: serde_json::to_value(self.runtime_profile()?).map_err(EngineError::from)?,
                },
                Vec::new(),
                None,
            )),
            EngineCommand::PairingInbox => {
                let (response, runtime_events) =
                    self.dispatch_runtime("pairingInbox", serde_json::Value::Object(Default::default()))?;
                Ok((response_payload(response), runtime_events, None))
            }
            EngineCommand::PairingOutbox => {
                let (response, runtime_events) =
                    self.dispatch_runtime("pairingOutbox", serde_json::Value::Object(Default::default()))?;
                Ok((response_payload(response), runtime_events, None))
            }
            EngineCommand::ListContacts => Ok((
                ResponsePayload::Json {
                    value: serde_json::to_value(self.list_contacts()?).map_err(EngineError::from)?,
                },
                Vec::new(),
                None,
            )),
            EngineCommand::ListConversations => Ok((
                ResponsePayload::Json {
                    value: serde_json::to_value(self.list_conversations()?).map_err(EngineError::from)?,
                },
                Vec::new(),
                None,
            )),
            EngineCommand::ListMessages { conversation_id } => Ok((
                ResponsePayload::Json {
                    value: serde_json::to_value(self.list_messages(&conversation_id)?)
                        .map_err(EngineError::from)?,
                },
                Vec::new(),
                None,
            )),
            EngineCommand::SetNickname { nickname } => {
                let (response, runtime_events) =
                    self.dispatch_runtime("setNickname", json!({ "nickname": nickname }))?;
                Ok((response_payload(response), runtime_events, None))
            }
            EngineCommand::RefreshPairingCode => {
                let (response, runtime_events) = self.dispatch_runtime(
                    "refreshPairingCode",
                    serde_json::Value::Object(Default::default()),
                )?;
                Ok((response_payload(response), runtime_events, None))
            }
            EngineCommand::SubmitPairingCode { code } => {
                let (response, runtime_events) =
                    self.dispatch_runtime("submitPairingCode", json!({ "code": code }))?;
                Ok((response_payload(response), runtime_events, None))
            }
            EngineCommand::AcceptPairing { pairing_id } => {
                let (preparation, mut runtime_events): (PairingPreparation, _) =
                    self.with_runtime(|runtime| runtime.prepare_accept_pairing(&pairing_id))?;
                let invite = self
                    .build_contact_invite(Some(preparation.recipient_installation_id.clone()))?;
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
                self.dispatch_runtime_send_effect(effect)?;
                runtime_events.append(&mut commit_events);
                Ok((ResponsePayload::Empty, runtime_events, None))
            }
            EngineCommand::OpenConversation { conversation_id } => {
                let (response, runtime_events) =
                    self.dispatch_runtime("openConversation", json!({ "id": conversation_id }))?;
                Ok((response_payload(response), runtime_events, None))
            }
            EngineCommand::CloseConversation => {
                let (response, runtime_events) =
                    self.dispatch_runtime("closeConversation", serde_json::Value::Object(Default::default()))?;
                Ok((response_payload(response), runtime_events, None))
            }
            EngineCommand::VerifyContact { installation_id } => {
                let (response, runtime_events) =
                    self.dispatch_runtime("verifyContact", json!({ "installationId": installation_id }))?;
                Ok((response_payload(response), runtime_events, None))
            }
            EngineCommand::StartConversation { contact_id } => {
                let (response, runtime_events) =
                    self.dispatch_runtime("startConversation", json!({ "contactId": contact_id }))?;
                Ok((response_payload(response), runtime_events, None))
            }
            EngineCommand::SendMessage {
                conversation_id,
                body,
            } => {
                let (response, runtime_events) = self.dispatch_runtime(
                    "sendMessage",
                    json!({
                        "id": conversation_id,
                        "text": body,
                    }),
                )?;
                let effect = runtime_send_effect_from_response(&response)?;
                self.dispatch_runtime_send_effect(effect)?;
                Ok((response_payload(response), runtime_events, None))
            }
            EngineCommand::RejectPairing { pairing_id } => {
                let (effect, runtime_events) =
                    self.with_runtime(|runtime| runtime.commit_reject_pairing(&pairing_id))?;
                self.dispatch_runtime_send_effect(effect)?;
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
                let (response, runtime_events) = self.dispatch_runtime(
                    "archivePairing",
                    json!({ "pairingId": pairing_id }),
                )?;
                Ok((response_payload(response), runtime_events, None))
            }
            EngineCommand::Connect => {
                self.connection_state = if self.socks5_url.is_some() {
                    ConnectionState::Connecting
                } else {
                    ConnectionState::WaitingForTor
                };
                self.relay.ensure_session().map_err(runtime_error)?;
                let (response, runtime_events) =
                    self.dispatch_runtime("connect", serde_json::Value::Object(Default::default()))?;
                let mut events = runtime_events;
                events.append(&mut self.sync_pairing_inbox()?);
                self.flush_pending_send_effects()?;
                self.flush_pending_receipt_effects()?;
                Ok((response_payload(response), events, Some(self.connection_snapshot("connect requested"))))
            }
            EngineCommand::PlatformFact { fact } => {
                let runtime_events = self.apply_platform_fact(fact)?;
                Ok((
                    ResponsePayload::Empty,
                    runtime_events,
                    Some(self.connection_snapshot("platform fact applied")),
                ))
            }
            other => Err(EngineError::InvalidCommand(format!(
                "engine command not implemented yet: {other:?}"
            ))),
        }
    }

    fn dispatch_runtime(
        &mut self,
        method: &str,
        params: serde_json::Value,
    ) -> EngineResult<(RuntimeResponse, Vec<torchat_client_runtime::RuntimeEvent>)> {
        let storage = SqliteRuntimeStorage::new(self.database.transaction()?);
        let transport = EngineRuntimeTransport {
            status: self.tor_status.clone(),
            relay: self.relay.as_mut(),
        };
        let session = mem::take(&mut self.session);
        let mut runtime = ClientRuntime::with_session(storage, transport, self.clock, session);
        let result = runtime.dispatch_request_with(
            RuntimeRequest {
                id: None,
                method: method.to_owned(),
                params,
            },
            |runtime, response| {
                runtime.storage_mut().commit()?;
                Ok(response)
            },
        );
        let events = runtime.drain_events();
        let (_, transport, _, session) = runtime.into_parts_with_session();
        self.session = session;
        self.tor_status = transport.status;
        let response = result.map_err(runtime_error)?;
        Ok((response, events))
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

        let events = runtime.drain_events();
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
                    crate::TorPhase::Ready => (
                        ConnectionState::Disconnected,
                        RuntimeStatusPhase::Offline,
                        "tor ready",
                    ),
                    crate::TorPhase::Failed => (
                        ConnectionState::Stopped,
                        RuntimeStatusPhase::Error,
                        "tor failed",
                    ),
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
                let (_, runtime_events) =
                    self.with_runtime(|runtime| Ok(runtime.report_tor_status(self.tor_status.clone())))?;
                Ok(runtime_events)
            }
            PlatformFact::TorEndpointAvailable { socks5_url } => {
                self.socks5_url = Some(socks5_url);
                self.relay.set_socks5_url(self.socks5_url.clone());
                self.connection_state = ConnectionState::Disconnected;
                self.tor_status = RuntimeTorStatus {
                    phase: RuntimeStatusPhase::Offline,
                    label: "tor ready".to_owned(),
                    detail: "SOCKS endpoint available".to_owned(),
                    progress: Some(100),
                    latency_ms: None,
                    retry_attempt: 0,
                };
                let (_, runtime_events) =
                    self.with_runtime(|runtime| Ok(runtime.report_tor_status(self.tor_status.clone())))?;
                Ok(runtime_events)
            }
            PlatformFact::TorEndpointLost { reason } => {
                self.socks5_url = None;
                self.relay.set_socks5_url(None);
                self.connection_state = ConnectionState::WaitingForTor;
                self.tor_status.label = "tor unavailable".to_owned();
                self.tor_status.detail = reason;
                self.tor_status.phase = RuntimeStatusPhase::Offline;
                self.tor_status.progress = None;
                let (_, runtime_events) =
                    self.with_runtime(|runtime| Ok(runtime.report_tor_status(self.tor_status.clone())))?;
                Ok(runtime_events)
            }
            PlatformFact::AppVisibilityChanged { .. } | PlatformFact::NetworkChanged => {
                Ok(Vec::new())
            }
        }
    }

    fn connection_snapshot(&self, detail: &str) -> ConnectionSnapshot {
        ConnectionSnapshot {
            state: self.connection_state.clone(),
            generation: 0,
            detail: detail.to_owned(),
        }
    }

    fn sync_pairing_inbox(&mut self) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        let (response, runtime_events) =
            self.dispatch_runtime("pairingInbox", serde_json::Value::Object(Default::default()))?;
        let result = response
            .result
            .ok_or_else(|| EngineError::InvalidCommand("pairingInbox returned no result".to_owned()))?;
        let result: PairingSyncResult =
            serde_json::from_value(result).map_err(EngineError::from)?;
        for acknowledgement in result.acknowledgements {
            self.relay
                .acknowledge_pairing(&acknowledgement.pairing_id)
                .map_err(runtime_error)?;
        }
        Ok(runtime_events)
    }

    async fn drain_relay_events(&mut self, events: &mpsc::Sender<EngineEvent>) {
        while let Some(event) = self.relay.poll_event() {
            match self.handle_relay_event(event) {
                Ok((runtime_events, connection_snapshot, log_event)) => {
                    if let Some(snapshot) = connection_snapshot {
                        let _ = events.send(EngineEvent::Connection(snapshot)).await;
                    }
                    if let Some(log) = log_event {
                        let _ = events.send(EngineEvent::Log(log)).await;
                    }
                    for event in runtime_events {
                        let _ = events.send(EngineEvent::Runtime(event)).await;
                    }
                }
                Err(error) => {
                    let _ = events
                        .send(EngineEvent::Log(EngineLogEvent {
                            level: "error".to_owned(),
                            message: format!("relay event handling failed: {error}"),
                        }))
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
        if self.connection_state != ConnectionState::Connected {
            return;
        }
        let result = match deadline.kind {
            RetryKind::MessageSend | RetryKind::PairingResponse => {
                self.flush_pending_send_effects().map(|_| "send flush")
            }
            RetryKind::MessageAckDeadline => self
                .retry_expired_ack_deadlines()
                .map(|_| "ack deadline handling"),
            RetryKind::Receipt => self.flush_pending_receipt_effects().map(|_| "receipt flush"),
            RetryKind::PendingWelcome => self.retry_pending_welcomes().map(|_| "welcome flush"),
        };
        if let Err(error) = result {
            let _ = events
                .send(EngineEvent::Log(EngineLogEvent {
                    level: "warn".to_owned(),
                    message: format!(
                        "retry scheduler {:?} failed at {}: {error}",
                        deadline.kind, deadline.at_ms
                    ),
                }))
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
            self.apply_message_transport_outcome(&message_id, MessageTransportOutcome::RetryableFailure)?;
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
        if !self
            .database
            .claim_pairing_response_attempt(&effect.pairing_id, next_attempt_at, None)?
        {
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
                self.database.requeue_sending_after_disconnect(unix_ms())?;
                Ok((
                    Vec::new(),
                    Some(self.connection_snapshot("relay disconnected")),
                    Some(EngineLogEvent {
                        level: "warn".to_owned(),
                        message: format!("relay disconnected: {detail}"),
                    }),
                ))
            }
            RelayEvent::Envelope(envelope) => {
                self.handle_relay_envelope(envelope)
                    .map(|events| (events, None, None))
            }
            RelayEvent::MessageTransportOutcome { message_id, outcome } => {
                let (_, runtime_events) = self.with_runtime(|runtime| {
                    runtime.apply_message_transport_outcome(message_id, outcome)
                })?;
                Ok((runtime_events, None, None))
            }
        }
    }

    fn handle_relay_envelope(
        &mut self,
        envelope: RelayEnvelope,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        let payload = RelayPayloadV1::decode(&envelope.ciphertext)
            .map_err(EngineError::InvalidCommand)?;
        match &payload {
            RelayPayloadV1::PairingOffer {
                pairing_id, invite, ..
            } => {
                let mut runtime_events = self.accept_invite(invite)?;
                if let Ok(pairing_id) = uuid::Uuid::parse_str(pairing_id) {
                    runtime_events.append(&mut self.apply_pairing_peer_outcome(
                        &pairing_id.to_string(),
                        PairingPeerOutcome::OfferReceived,
                    )?);
                    runtime_events.append(&mut self.apply_pairing_peer_outcome(
                        &pairing_id.to_string(),
                        PairingPeerOutcome::WelcomePrepared,
                    )?);
                }
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
                self.persist_mls_inbox()?;
                let runtime_events =
                    self.promote_contact_with_conversation(sender.clone(), conversation, Some(&invite_id))?;
                self.pending_welcomes.remove(&invite_id);
                self.database.remove_pending_welcome(&invite_id)?;
                Ok(runtime_events)
            }
            RelayPayloadV1::Application { .. } => self.handle_application_envelope(envelope, payload),
        }
    }

    fn handle_application_envelope(
        &mut self,
        envelope: RelayEnvelope,
        payload: RelayPayloadV1,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        let peer = envelope.sender.clone();
        let message_id = envelope.message_id;
        let ciphertext = payload
            .decode_application()
            .map_err(EngineError::InvalidCommand)?;
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
            return Ok(Vec::new());
        }
        let (body, _sent_at, snapshot) = {
            let conversation = self.conversations.get_mut(&peer).ok_or_else(|| {
                EngineError::InvalidCommand("message received before MLS Welcome".to_owned())
            })?;
            let plaintext = conversation
                .decrypt(&ciphertext)
                .map_err(EngineError::InvalidCommand)?;
            let application =
                ApplicationPayloadV1::decode(&plaintext).map_err(EngineError::InvalidCommand)?;
            let snapshot = conversation
                .snapshot()
                .map_err(|error| EngineError::Storage(error.to_string()))?;
            match application {
                ApplicationPayloadV1::Message {
                    message_id: payload_message_id,
                    sent_at,
                    body,
                    ..
                } => {
                    if payload_message_id != message_id {
                        return Err(EngineError::InvalidCommand(
                            "application messageId mismatch".to_owned(),
                        ));
                    }
                    (body, sent_at, snapshot)
                }
                ApplicationPayloadV1::DeliveryReceipt {
                    message_id: delivered_message_id,
                    ..
                } => {
                    let (events, _, _) = self.handle_relay_event(RelayEvent::MessageTransportOutcome {
                        message_id: delivered_message_id,
                        outcome: MessageTransportOutcome::Delivered,
                    })?;
                    return Ok(events);
                }
            }
        };
        self.database.put_conversation_mls_snapshot(&peer, &snapshot)?;
        let (_, runtime_events) = self.with_runtime(|runtime| {
            runtime.receive_message(&peer, body.clone(), Some(message_id))
        })?;
        let now_secs = unix_secs();
        self.database.put_received_envelope(&ReceivedEnvelopeRecord {
            sender_installation_id: peer.clone(),
            message_id: message_id.to_string(),
            ciphertext_hash,
            received_at: now_secs,
            receipt_state: "PENDING".to_owned(),
        })?;
        self.database.put_delivery_receipt(&DeliveryReceiptRecord {
            envelope_id: uuid::Uuid::new_v4().to_string(),
            message_id: message_id.to_string(),
            conversation_id: peer.clone(),
            original_sender: peer,
            received_at: now_secs,
            relay_payload: None,
            state: "PENDING".to_owned(),
            attempt_count: 0,
            next_attempt_at: 0,
            last_error: None,
            created_at: now_secs,
        })?;
        self.flush_pending_receipt_effects()?;
        Ok(runtime_events)
    }

    fn build_contact_invite(
        &mut self,
        recipient_installation_id: Option<String>,
    ) -> EngineResult<String> {
        let profile = self.runtime_profile()?;
        let nickname = profile.nickname.trim().chars().take(32).collect::<String>();
        let key_package = self
            .mls_inbox
            .key_package()
            .map_err(|error| EngineError::Storage(format!("create MLS key package: {error}")))?;
        self.identity
            .contact_invite_payload(
                Some(nickname),
                recipient_installation_id,
                URL_SAFE_NO_PAD.encode(key_package),
                uuid::Uuid::new_v4().to_string(),
                unix_secs() as u64 + 15 * 60,
            )
            .map_err(|error| EngineError::Serialization(error.to_string()))
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

    fn dispatch_runtime_send_effect(&mut self, effect: RuntimeSendEffect) -> EngineResult<()> {
        if let Some(message) = effect.message().cloned() {
            let payload = self.prepare_outbound_message_payload(&message)?;
            if let Err(error) = self
                .relay
                .send_envelope(&message.recipient_installation_id, &payload)
            {
                self.apply_message_transport_outcome(
                    &message.message_id,
                    MessageTransportOutcome::RetryableFailure,
                )?;
                return Err(runtime_error(error));
            }
            return Ok(());
        }
        if let Some(pairing) = effect.pairing().cloned() {
            let Some((recipient_installation_id, ciphertext)) =
                self.prepare_pairing_response_payload(&pairing)?
            else {
                return Ok(());
            };
            if let Err(error) = self
                .relay
                .send_envelope(&recipient_installation_id, &ciphertext)
            {
                self.database
                    .record_pairing_response_error(&pairing.pairing_id, &error.to_string())?;
                return Err(runtime_error(error));
            }
            return Ok(());
        }
        if let Some(receipt) = effect.receipt().cloned() {
            let ciphertext = self.encrypt_receipt(&receipt)?;
            return self
                .relay
                .send_envelope(&receipt.recipient_installation_id, &ciphertext)
                .map_err(runtime_error);
        }
        Err(EngineError::InvalidCommand(
            "engine relay transport does not support this runtime send effect yet".to_owned(),
        ))
    }

    fn flush_pending_send_effects(&mut self) -> EngineResult<()> {
        let (effects, _) = self.with_runtime(|runtime| runtime.prepare_pending_send_effects())?;
        for effect in effects {
            self.dispatch_runtime_send_effect(effect)?;
        }
        Ok(())
    }

    fn retry_pending_welcomes(&mut self) -> EngineResult<()> {
        let now_ms = unix_ms();
        for pending in self.database.due_pending_welcomes(now_ms)? {
            let next_attempt_at = now_ms + retry_backoff_ms(pending.attempt_count);
            let _ = self
                .database
                .claim_pending_welcome_attempt(&pending.invite_id, next_attempt_at, None)?;
            self.relay
                .send_envelope(
                    &pending.recipient_installation_id,
                    &String::from_utf8_lossy(&pending.payload),
                )
                .map_err(runtime_error)?;
        }
        Ok(())
    }

    fn apply_message_transport_outcome(
        &mut self,
        message_id: &str,
        outcome: MessageTransportOutcome,
    ) -> EngineResult<()> {
        let parsed = uuid::Uuid::parse_str(message_id)
            .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
        let _ = self.with_runtime(|runtime| {
            runtime.apply_message_transport_outcome(parsed, outcome)
        })?;
        Ok(())
    }

    fn flush_pending_receipt_effects(&mut self) -> EngineResult<()> {
        let (effects, _) =
            self.with_runtime(|runtime| runtime.prepare_pending_receipt_effects())?;
        for effect in effects {
            self.dispatch_runtime_send_effect(RuntimeSendEffect::from(effect))?;
        }
        Ok(())
    }

    fn prepare_outbound_message_payload(
        &mut self,
        effect: &torchat_client_runtime::MessageSendEffect,
    ) -> EngineResult<String> {
        let message_id = uuid::Uuid::parse_str(&effect.message_id)
            .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
        let stored = self
            .database
            .message(&effect.message_id)?
            .ok_or_else(|| EngineError::Storage("runtime message is missing from engine store".to_owned()))?;
        let next_attempt_at = unix_ms() + retry_backoff_ms(stored.attempt_count);
        let ack_deadline = Some(unix_ms() + 60_000);
        let _ = self.database.claim_outgoing_attempt(
            &effect.message_id,
            next_attempt_at,
            ack_deadline,
            None,
        )?;
        if let Some(existing) = stored.relay_payload {
            return String::from_utf8(existing)
                .map_err(|error| EngineError::Storage(format!("stored relay payload is invalid UTF-8: {error}")));
        }
        let conversation = self
            .conversations
            .get_mut(&effect.recipient_installation_id)
            .ok_or_else(|| {
                EngineError::InvalidCommand("contact requires MLS welcome before sending".to_owned())
            })?;
        let plaintext = ApplicationPayloadV1::Message {
            version: torchat_core::PROTOCOL_VERSION,
            message_id,
            sent_at: stored.created_at,
            body: effect.body.clone(),
        }
        .encode()
        .map_err(EngineError::InvalidCommand)?;
        let encrypted = conversation
            .encrypt(&plaintext)
            .map_err(EngineError::InvalidCommand)?;
        let payload = RelayPayloadV1::application(&encrypted)
            .encode()
            .map_err(EngineError::InvalidCommand)?;
        let snapshot = conversation
            .snapshot()
            .map_err(|error| EngineError::Storage(error.to_string()))?;
        self.database.persist_outbound_encryption(
            &effect.message_id,
            payload.as_bytes(),
            &effect.conversation_id,
            &snapshot,
        )?;
        Ok(payload)
    }

    fn encrypt_receipt(
        &mut self,
        effect: &torchat_client_runtime::ReceiptSendEffect,
    ) -> EngineResult<String> {
        let next_attempt_at = unix_ms() + retry_backoff_ms(0);
        let _ = self
            .database
            .claim_receipt_attempt(&effect.message_id, next_attempt_at, None)?;
        let conversation = self
            .conversations
            .get_mut(&effect.recipient_installation_id)
            .ok_or_else(|| {
                EngineError::InvalidCommand(
                    "receipt recipient has no MLS conversation".to_owned(),
                )
            })?;
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
        let snapshot = conversation
            .snapshot()
            .map_err(|error| EngineError::Storage(error.to_string()))?;
        self.database
            .put_conversation_mls_snapshot(&effect.conversation_id, &snapshot)?;
        RelayPayloadV1::application(&encrypted)
            .encode()
            .map_err(EngineError::InvalidCommand)
    }

    fn accept_invite(
        &mut self,
        invite_payload: &str,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        let invite = ContactInvite::parse(invite_payload.trim()).map_err(EngineError::InvalidCommand)?;
        if invite.installation_id == self.identity.installation_id() {
            return Err(EngineError::InvalidCommand(
                "cannot accept self invite".to_owned(),
            ));
        }
        if !self.database.consume_invite(&invite.invite_id)? {
            if let Some(pending) = self.pending_welcomes.get(&invite.invite_id) {
                self.relay
                    .send_envelope(&pending.recipient_installation_id, &String::from_utf8_lossy(&pending.payload))
                    .map_err(runtime_error)?;
            }
            return Ok(Vec::new());
        }
        let card = contact_card_from_invite(&invite);
        let member = self.fresh_mls_member()?;
        let mut conversation = member
            .create_conversation()
            .map_err(EngineError::InvalidCommand)?;
        let key_package = URL_SAFE_NO_PAD
            .decode(invite.key_package)
            .map_err(|_| EngineError::InvalidCommand("invalid contact invite key package".to_owned()))?;
        let (welcome, tree) = conversation
            .invite(&key_package)
            .map_err(EngineError::InvalidCommand)?;
        let runtime_events = self.promote_contact_with_conversation(card.clone(), conversation, None)?;
        let profile = self.runtime_profile()?;
        let ciphertext = RelayPayloadV1::welcome(
            &self.identity,
            &profile.nickname,
            card.installation_id.clone(),
            invite.invite_id.clone(),
            &welcome,
            &tree,
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
        self.database.put_pending_welcome(&pending)?;
        self.pending_welcomes.insert(invite.invite_id, pending);
        self.relay
            .send_envelope(&card.installation_id, &ciphertext)
            .map_err(runtime_error)?;
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

    fn promote_contact_with_conversation(
        &mut self,
        card: torchat_core::relay::ContactCard,
        conversation: DirectConversation,
        invite_id: Option<&str>,
    ) -> EngineResult<Vec<torchat_client_runtime::RuntimeEvent>> {
        let snapshot = conversation
            .snapshot()
            .map_err(|error| EngineError::Storage(error.to_string()))?;
        let (result, runtime_events): (WelcomeAcceptedResult, _) = self.with_runtime(|runtime| {
            runtime.welcome_accepted(
                contact_record_from_card(&card, false),
                true,
                invite_id.map(str::to_owned),
            )
        })?;
        if let Some(confirm) = result.confirm_contact {
            self.relay
                .confirm_contact(&confirm.capability, &confirm.peer_installation_id)
                .map_err(runtime_error)?;
        }
        self.database
            .put_conversation_mls_snapshot(&card.installation_id, &snapshot)?;
        self.conversations.insert(card.installation_id.clone(), conversation);
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

    fn persist_mls_inbox(&self) -> EngineResult<()> {
        let snapshot = self.snapshot_mls_inbox()?;
        self.database.put_mls_inbox_snapshot(&snapshot)
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

    fn update_profile(&mut self, _nickname: &str) -> torchat_client_runtime::RuntimeResult<()> {
        Ok(())
    }

    fn refresh_pairing_code(&mut self) -> torchat_client_runtime::RuntimeResult<torchat_client_runtime::InviteCode> {
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
    let bytes: [u8; 32] =
        config.identity_private_key.expose().try_into().map_err(|_| {
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
        .pending_welcomes()?
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

fn runtime_send_effect_from_response(response: &RuntimeResponse) -> EngineResult<RuntimeSendEffect> {
    serde_json::from_value(response.result.clone().ok_or_else(|| {
        EngineError::InvalidCommand("runtime command did not return a result payload".to_owned())
    })?)
    .map_err(EngineError::from)
}

fn response_payload(response: RuntimeResponse) -> ResponsePayload {
    match response.result {
        Some(value) => ResponsePayload::Json { value },
        None => ResponsePayload::Empty,
    }
}

fn error_code(error: &EngineError) -> &'static str {
    match error {
        EngineError::Closed(_) => "closed",
        EngineError::InvalidConfig(_) => "invalid_config",
        EngineError::InvalidCommand(_) => "invalid_command",
        EngineError::Serialization(_) => "serialization",
        EngineError::Storage(_) => "storage",
    }
}
