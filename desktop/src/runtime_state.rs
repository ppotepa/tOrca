use anyhow::{Context, Result};
use base64::Engine;
use serde::{Serialize, de::DeserializeOwned};
use std::{
    collections::{HashMap, VecDeque},
    sync::Arc,
    time::Instant,
};
use tokio::runtime::Runtime;
use torchat_client_runtime::{
    RuntimeSession,
    retry::{retry_delay_ms, retry_jitter_seed},
    runtime_status_snapshot,
};
use torchat_core::{
    mls::{DirectConversation, MlsMember},
    relay::ContactCard,
};
use uuid::Uuid;

use crate::{
    cli::Cli,
    identity_store,
    runtime_support::{load_dev_snapshot, load_json_secret, persist_json_secret, unix_secs},
    store::LocalStore,
    tor_runtime::{TorRuntime as ManagedTor, TorStatus},
    transport::{ApiTransport, RelayCommand, RelayEvent, spawn_relay_actor},
};

pub(crate) struct DesktopState {
    pub(crate) _runtime: Runtime,
    pub(crate) _tor: ManagedTor,
    pub(crate) tor_events: std::sync::mpsc::Receiver<TorStatus>,
    pub(crate) relay_events: std::sync::mpsc::Receiver<RelayEvent>,
    pub(crate) relay_commands: tokio::sync::mpsc::Sender<RelayCommand>,
    pub(crate) identity: Arc<torchat_core::Identity>,
    pub(crate) pending_member: Option<MlsMember>,
    pub(crate) store: LocalStore,
    pub(crate) nickname: String,
    pub(crate) screen: String,
    pub(crate) tor_status: torchat_client_runtime::RuntimeTorStatus,
    pub(crate) connected: bool,
    pub(crate) contacts: Vec<ContactCard>,
    pub(crate) conversations: HashMap<String, DirectConversation>,
    pub(crate) selected_peer: Option<String>,
    pub(crate) messages: Vec<crate::store::StoredMessage>,
    pub(crate) error: String,
    pub(crate) pairing_code: Option<crate::model::PairingCodeResponse>,
    pub(crate) pairing_inbox: Vec<crate::model::PairingInboxItem>,
    pub(crate) pairing_outbox: Vec<crate::model::PairingRequestResponse>,
    pub(crate) pending_welcomes: HashMap<String, (String, String)>,
    pub(crate) client_runtime_session: RuntimeSession,
    pub(crate) started_at: Instant,
    pub(crate) last_pairing_sync: Instant,
    pub(crate) runtime_events: VecDeque<torchat_client_runtime::RuntimeEvent>,
}

impl DesktopState {
    pub fn new(cli: Cli) -> Result<Self> {
        let server_url = cli
            .server_url
            .clone()
            .or_else(|| option_env!("TORCHAT_COMPILED_ONION_URL").map(str::to_owned))
            .context(
                "TorChat onion URL is missing; rebuild the client after starting the environment",
            )?;
        let identity = Arc::new(identity_store::load_or_create(
            cli.identity_file.as_deref(),
        )?);
        let store_path = identity_store::state_path(cli.identity_file.as_deref())?;
        let store = LocalStore::open(&store_path, &identity)?;
        let pending_member = match store.secret("mls-inbox-v1")? {
            Some(snapshot) => MlsMember::restore(&snapshot, identity.public_key().as_bytes())
                .map_err(anyhow::Error::msg)?,
            None => {
                MlsMember::create(identity.public_key().as_bytes()).map_err(anyhow::Error::msg)?
            }
        };
        let nickname = cli
            .nickname
            .clone()
            .or_else(|| {
                store
                    .secret("profile-nickname-v1")
                    .ok()
                    .flatten()
                    .and_then(|value| String::from_utf8(value).ok())
            })
            .unwrap_or_default();

        let (tor, tor_events) = if let Some(binary) = cli.tor_binary.as_deref() {
            let data_dir = cli
                .tor_data_dir
                .clone()
                .unwrap_or_else(|| store_path.with_file_name("tor"));
            ManagedTor::start(binary, &data_dir)?
        } else {
            ManagedTor::external(
                cli.socks5_proxy
                    .clone()
                    .context("managed Tor binary or SOCKS proxy is required")?,
            )
        };
        let transport = ApiTransport::new(&server_url, Some(tor.socks_url()))?;
        let tor_ready = tor.readiness();
        let runtime = Runtime::new()?;
        let (relay_commands, relay_events) = spawn_relay_actor(
            &runtime,
            transport,
            identity.clone(),
            nickname.clone(),
            tor_ready,
        );

        let mut state = Self {
            _runtime: runtime,
            _tor: tor,
            tor_events,
            relay_events,
            relay_commands,
            identity,
            pending_member: Some(pending_member),
            store,
            nickname,
            screen: "splash".into(),
            tor_status: runtime_status_snapshot(
                "starting",
                "Uruchamianie Tor…".into(),
                "Uruchamianie Tor…".into(),
                Some(0),
                None,
                0,
            ),
            connected: false,
            contacts: Vec::new(),
            conversations: HashMap::new(),
            selected_peer: None,
            messages: Vec::new(),
            error: String::new(),
            pairing_code: None,
            pairing_inbox: Vec::new(),
            pairing_outbox: Vec::new(),
            pending_welcomes: HashMap::new(),
            client_runtime_session: RuntimeSession::new(),
            started_at: Instant::now(),
            last_pairing_sync: Instant::now(),
            runtime_events: VecDeque::new(),
        };
        state.load_local_state()?;
        state.load_pairing_inbox()?;
        state.load_pairing_outbox()?;
        state.load_pending_welcomes()?;
        state.load_dev_pair(&cli)?;
        Ok(state)
    }

    fn load_local_state(&mut self) -> Result<()> {
        self.contacts = self.store.contacts()?;
        for conversation in self.store.runtime_conversations()? {
            if let Some(snapshot) = self.store.conversation_mls(&conversation.id)? {
                let restored = DirectConversation::restore(&snapshot)
                    .map_err(anyhow::Error::msg)
                    .with_context(|| format!("restore MLS conversation {}", conversation.id))?;
                self.conversations
                    .insert(conversation.contact_installation_id.clone(), restored);
            }
        }
        Ok(())
    }

    fn load_json_secret_or_default<T>(&self, key: &str) -> Result<T>
    where
        T: DeserializeOwned + Default,
    {
        Ok(load_json_secret(&self.store, key)?.unwrap_or_default())
    }

    fn persist_json_secret<T>(&self, key: &str, value: &T) -> Result<()>
    where
        T: Serialize,
    {
        persist_json_secret(&self.store, key, value)
    }

    pub(crate) fn load_pairing_inbox(&mut self) -> Result<()> {
        self.pairing_inbox = self.load_json_secret_or_default("pairing-inbox-v1")?;
        Ok(())
    }

    pub(crate) fn persist_pairing_inbox(&self) -> Result<()> {
        self.persist_json_secret("pairing-inbox-v1", &self.pairing_inbox)
    }

    pub(crate) fn load_pairing_outbox(&mut self) -> Result<()> {
        self.pairing_outbox = self.load_json_secret_or_default("pairing-outbox-v1")?;
        Ok(())
    }

    pub(crate) fn persist_pairing_outbox(&self) -> Result<()> {
        self.persist_json_secret("pairing-outbox-v1", &self.pairing_outbox)
    }

    pub(crate) fn load_pending_welcomes(&mut self) -> Result<()> {
        self.pending_welcomes = self.load_json_secret_or_default("pending-welcomes-v1")?;
        Ok(())
    }

    pub(crate) fn persist_pending_welcomes(&self) -> Result<()> {
        self.persist_json_secret("pending-welcomes-v1", &self.pending_welcomes)
    }

    pub(crate) fn load_dev_pair(&mut self, cli: &Cli) -> Result<()> {
        let Some(path) = cli.dev_fixture.as_deref() else {
            return Ok(());
        };
        let peer_identity = if let Some(path) = cli.dev_peer_identity_file.as_deref() {
            identity_store::load_existing(path)?
        } else {
            let installation_id = cli
                .dev_peer
                .as_deref()
                .context("dev peer identity or installation ID is required")?;
            if !self
                .contacts
                .iter()
                .any(|contact| contact.installation_id == installation_id)
            {
                self.error =
                    "Fixture ma tylko installation ID; podaj --dev-peer-identity-file.".into();
            }
            return Ok(());
        };
        let card = ContactCard::from_identity(&peer_identity, &cli.dev_peer_nickname);
        let installation_id = card.installation_id.clone();
        crate::runtime_adapter::dispatch_local_runtime_command(
            self,
            "welcomeAccepted",
            serde_json::json!({
                "contact": torchat_client_runtime::contact_record_from_card(&card, false),
                "openConversation": true,
            }),
        )?;
        crate::runtime_adapter::dispatch_local_runtime_command(
            self,
            "verifyContact",
            serde_json::json!({
                "installationId": installation_id,
            }),
        )?;
        self.contacts = self.store.contacts()?;
        let snapshot = load_dev_snapshot(path, "peer_snapshot")?;
        let conversation = DirectConversation::restore(&snapshot).map_err(anyhow::Error::msg)?;
        let snapshot = conversation.snapshot().map_err(anyhow::Error::msg)?;
        self.store
            .put_conversation_mls(&card.installation_id, &snapshot)?;
        self.conversations
            .insert(card.installation_id.clone(), conversation);
        self.select_peer(&card.installation_id)?;
        Ok(())
    }

    pub(crate) fn build_invite(&self, recipient_installation_id: Option<String>) -> Result<String> {
        let member = self
            .pending_member
            .as_ref()
            .context("MLS invitation state unavailable")?;
        Ok(self.identity.contact_invite_payload(
            Some(self.nickname.clone()),
            recipient_installation_id,
            base64::engine::general_purpose::URL_SAFE_NO_PAD
                .encode(member.key_package().map_err(anyhow::Error::msg)?),
            Uuid::new_v4().to_string(),
            unix_secs() + 15 * 60,
        )?)
    }

    fn boot_target_screen(&self) -> String {
        if self.connected {
            if self.nickname.trim().is_empty() {
                "onboarding".into()
            } else {
                "main".into()
            }
        } else {
            "connection".into()
        }
    }

    fn maybe_finish_boot(&mut self) {
        if self.screen == "splash" && self.started_at.elapsed().as_millis() >= 700 {
            self.screen = self.boot_target_screen();
        }
    }

    fn handle_connected(&mut self) -> Result<()> {
        self.connected = true;
        eprintln!(
            "[TorChat-Pairing] desktop connected nickname={} selected_peer={}",
            self.nickname,
            self.selected_peer.as_deref().unwrap_or("<none>")
        );
        self.tor_status = runtime_status_snapshot(
            "connected",
            "Onion połączony · relay aktywny".into(),
            "Onion połączony · relay aktywny".into(),
            Some(100),
            self.tor_status.latency_ms,
            0,
        );
        if self.started_at.elapsed().as_millis() >= 700 {
            self.screen = self.boot_target_screen();
        }
        self.error.clear();
        self.store
            .accelerate_retry_after_ready(crate::runtime_support::unix_millis())?;
        self.flush_pending_send_effects()?;
        self.retry_due_messages()?;
        self.retry_due_receipts()?;
        if !self.nickname.trim().is_empty() {
            let _ = self
                .relay_commands
                .try_send(RelayCommand::UpdateNickname(self.nickname.clone()));
        }
        Ok(())
    }

    pub(crate) fn enqueue_runtime_events(
        &mut self,
        events: impl IntoIterator<Item = torchat_client_runtime::RuntimeEvent>,
    ) {
        for event in events {
            self.runtime_events.push_back(event);
        }
    }

    pub(crate) fn drain_runtime_events(&mut self) -> Vec<torchat_client_runtime::RuntimeEvent> {
        self.runtime_events.drain(..).collect()
    }

    fn add_pairing_outbox_request(
        &mut self,
        pairing_id: Uuid,
        expires_at: i64,
        state: torchat_client_runtime::InviteState,
    ) -> Result<()> {
        crate::runtime_adapter::dispatch_local_runtime_command(
            self,
            "mergePairingOutbox",
            serde_json::json!({
                "items": [{
                    "pairingId": pairing_id.to_string(),
                    "expiresAt": expires_at,
                    "state": state,
                }],
            }),
        )?;
        Ok(())
    }

    fn merge_pairing_inbox_items(
        &mut self,
        items: Vec<crate::model::PairingInboxItem>,
    ) -> Result<()> {
        eprintln!(
            "[TorChat-Pairing] merge_pairing_inbox_items remote={}",
            items.len()
        );
        let events = crate::runtime_adapter::merge_remote_pairing_inbox_with_runtime(self, items)?;
        let mut added = Vec::new();
        for event in &events {
            if let torchat_client_runtime::RuntimeEvent::InviteReceived {
                pairing_id: Some(pairing_id),
                ..
            } = event
                && let Ok(pairing_id) = Uuid::parse_str(&pairing_id)
            {
                added.push(pairing_id);
            }
        }
        for pairing_id in added {
            eprintln!("[TorChat-Pairing] ack_pairing_request pairing_id={pairing_id}");
            let _ = self
                .relay_commands
                .try_send(RelayCommand::AcknowledgePairing(pairing_id));
        }
        self.enqueue_runtime_events(events);
        Ok(())
    }

    fn retry_due_messages(&mut self) -> Result<()> {
        let now_ms = crate::runtime_support::unix_millis();
        for message in self.store.pending_outgoing(now_ms)? {
            let Some(ciphertext) = message.relay_payload.clone() else {
                continue;
            };
            let next_attempt_at = now_ms
                + retry_delay_ms(
                    message.attempt_count.saturating_add(1) as u32,
                    retry_jitter_seed(&message.id, message.attempt_count.saturating_add(1) as u32),
                );
            if !self.store.claim_outgoing_retry(
                &message.id,
                next_attempt_at,
                Some(now_ms + 30_000),
                None,
            )? {
                continue;
            }
            if self
                .relay_commands
                .try_send(RelayCommand::Send {
                    message_id: Uuid::parse_str(&message.id)?,
                    recipient: message.peer.clone(),
                    ciphertext,
                })
                .is_err()
            {
                break;
            }
        }
        Ok(())
    }

    fn retry_due_receipts(&mut self) -> Result<()> {
        let now_ms = crate::runtime_support::unix_millis();
        let receipts = self.store.pending_delivery_receipts(now_ms)?;
        for receipt in receipts {
            let next_attempt_at = now_ms
                + retry_delay_ms(
                    receipt.attempt_count.saturating_add(1) as u32,
                    retry_jitter_seed(
                        &receipt.message_id,
                        receipt.attempt_count.saturating_add(1) as u32,
                    ),
                );
            if !self
                .store
                .claim_receipt_retry(&receipt.message_id, next_attempt_at, None)?
            {
                continue;
            }
            let Some(conversation) = self.conversations.get_mut(&receipt.original_sender) else {
                continue;
            };
            let plaintext = torchat_core::application::ApplicationPayloadV1::DeliveryReceipt {
                version: torchat_core::PROTOCOL_VERSION,
                message_id: Uuid::parse_str(&receipt.message_id)?,
                received_at: now_ms,
            }
            .encode()
            .map_err(anyhow::Error::msg)?;
            let encrypted = conversation
                .encrypt(&plaintext)
                .map_err(anyhow::Error::msg)?;
            let snapshot = conversation.snapshot().map_err(anyhow::Error::msg)?;
            self.store
                .put_conversation_mls(&receipt.original_sender, &snapshot)?;
            let ciphertext = torchat_core::relay::RelayPayloadV1::application(&encrypted)
                .encode()
                .map_err(anyhow::Error::msg)?;
            let _ = self.relay_commands.try_send(RelayCommand::Send {
                message_id: Uuid::new_v4(),
                recipient: receipt.original_sender,
                ciphertext,
            });
        }
        Ok(())
    }

    pub fn flush_pending_delivery_receipts(&mut self) -> Result<()> {
        self.retry_due_receipts()
    }

    pub fn tick(&mut self) {
        while let Ok(status) = self.tor_events.try_recv() {
            self.tor_status = runtime_status_snapshot(
                &status.phase,
                status.label,
                status.detail,
                Some(status.progress),
                status.latency_ms,
                status.retry_attempt,
            );
        }
        while let Ok(event) = self.relay_events.try_recv() {
            if let Err(error) = self.handle_relay_event(event) {
                eprintln!("[TorChat-Runtime] relay event handling failed: {error:#}");
                self.error = format!("{error:#}");
            }
        }
        if self.connected && self.last_pairing_sync.elapsed() >= std::time::Duration::from_secs(20)
        {
            let _ = self.relay_commands.try_send(RelayCommand::PairingInbox);
            if let Err(error) = self.flush_pending_send_effects() {
                self.error = format!("{error:#}");
            }
            self.last_pairing_sync = Instant::now();
        }
        self.maybe_finish_boot();
    }

    fn handle_relay_event(&mut self, event: RelayEvent) -> Result<()> {
        match event {
            RelayEvent::Status {
                phase,
                label,
                progress,
                latency_ms,
            } => {
                self.tor_status = runtime_status_snapshot(
                    &phase,
                    label.clone(),
                    label,
                    Some(progress),
                    latency_ms,
                    0,
                );
                self.connected = false;
                self.store
                    .requeue_sending_after_disconnect(crate::runtime_support::unix_millis())?;
                self.error.clear();
            }
            RelayEvent::Connected => self.handle_connected()?,
            RelayEvent::PairingCode(code) => self.pairing_code = Some(code),
            RelayEvent::PairingRequestCreated {
                pairing_id,
                expires_at,
                state,
            } => {
                eprintln!(
                    "[TorChat-Pairing] pairin_request_created pairing_id={pairing_id} expires_at={expires_at} state={state:?}"
                );
                self.add_pairing_outbox_request(pairing_id, expires_at, state)?
            }
            RelayEvent::PairingCancelled(pairing_id) => {
                crate::runtime_adapter::dispatch_local_runtime_command(
                    self,
                    "confirmPairingCancelled",
                    serde_json::json!({"pairingId": pairing_id.to_string()}),
                )?;
            }
            RelayEvent::PairingInbox(items) => self.merge_pairing_inbox_items(items)?,
            RelayEvent::PairingAcknowledged => {}
            RelayEvent::ContactConfirmed => {}
            RelayEvent::MessageTransportOutcome {
                message_id,
                outcome,
            } => {
                eprintln!(
                    "[TorChat-Runtime] message_transport_outcome message_id={message_id} outcome={outcome:?}"
                );
                if self.store.message(&message_id.to_string())?.is_some() {
                    if let Err(error) = crate::runtime_adapter::dispatch_local_runtime_command(
                        self,
                        "applyMessageTransportOutcome",
                        serde_json::json!({
                            "messageId": message_id.to_string(),
                            "outcome": outcome,
                        }),
                    ) {
                        eprintln!(
                            "[TorChat-Runtime] ignoring stale message transport outcome \
                             message_id={message_id}: {error}"
                        );
                    }
                } else {
                    eprintln!(
                        "[TorChat-Runtime] ignoring transport outcome for non-message envelope \
                         message_id={message_id}"
                    );
                }
                if let Some(selected_peer) = self.selected_peer.as_deref() {
                    self.messages = self.store.messages(selected_peer)?;
                }
            }
            RelayEvent::Envelope(envelope) => self.receive_envelope(envelope)?,
            RelayEvent::Error(error) => {
                eprintln!("TorChat relay: {error}");
                self.error = error;
            }
        }
        Ok(())
    }
}

impl Drop for DesktopState {
    fn drop(&mut self) {
        let _ = self.relay_commands.try_send(RelayCommand::Shutdown);
    }
}
