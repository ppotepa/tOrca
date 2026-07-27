mod cli;
mod identity_store;
mod model;
mod sql;
mod store;
mod tor_runtime;
mod transport;

use anyhow::{Context, Result};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use clap::Parser;
use cli::Cli;
use model::{PairingCodeResponse, PairingInboxItem};
use std::io::{BufRead, Write};
use std::{
    collections::HashMap,
    fs,
    path::Path,
    sync::Arc,
    time::{Instant, SystemTime, UNIX_EPOCH},
};
use store::{LocalStore, StoredMessage};
use tokio::runtime::Runtime;
use tor_runtime::{TorRuntime as ManagedTor, TorStatus};
use torchat_core::{
    ContactInvite, Identity, PROTOCOL_VERSION,
    mls::{DirectConversation, MlsMember},
    relay::{ContactCard, RelayPayloadV1},
};
use transport::{ApiTransport, RelayCommand, RelayEvent, spawn_relay_actor};
use uuid::Uuid;

struct DesktopState {
    _runtime: Runtime,
    _tor: ManagedTor,
    tor_events: std::sync::mpsc::Receiver<TorStatus>,
    relay_events: std::sync::mpsc::Receiver<RelayEvent>,
    relay_commands: tokio::sync::mpsc::UnboundedSender<RelayCommand>,
    identity: Arc<Identity>,
    pending_member: Option<MlsMember>,
    store: LocalStore,
    nickname: String,
    screen: String,
    status: String,
    status_phase: String,
    status_progress: i32,
    connected: bool,
    contacts: Vec<ContactCard>,
    conversations: HashMap<String, DirectConversation>,
    selected_peer: Option<String>,
    messages: Vec<StoredMessage>,
    error: String,
    pairing_code: Option<PairingCodeResponse>,
    pairing_inbox: Vec<PairingInboxItem>,
    pairing_offers: HashMap<String, (String, Uuid)>,
    pending_pairing_offers: HashMap<Uuid, (String, String)>,
    started_at: Instant,
    last_pairing_sync: Instant,
}

impl DesktopState {
    fn new(cli: Cli) -> Result<Self> {
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
        let transport = ApiTransport::new(&cli.server_url, Some(tor.socks_url()))?;
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
            status: "Uruchamianie Tor…".into(),
            status_phase: "starting".into(),
            status_progress: 0,
            connected: false,
            contacts: Vec::new(),
            conversations: HashMap::new(),
            selected_peer: None,
            messages: Vec::new(),
            error: String::new(),
            pairing_code: None,
            pairing_inbox: Vec::new(),
            pairing_offers: HashMap::new(),
            pending_pairing_offers: HashMap::new(),
            started_at: Instant::now(),
            last_pairing_sync: Instant::now(),
        };
        state.load_local_state()?;
        state.load_pairing_inbox()?;
        state.load_pairing_offers()?;
        state.load_pending_pairing_offers()?;
        state.load_dev_pair(&cli)?;
        Ok(state)
    }

    fn load_local_state(&mut self) -> Result<()> {
        self.contacts = self.store.contacts()?;
        for peer in self.store.conversation_peers()? {
            let Some(snapshot) = self.store.conversation(&peer)? else {
                continue;
            };
            if let Ok(conversation) = DirectConversation::restore(&snapshot) {
                self.conversations.insert(peer, conversation);
            }
        }
        Ok(())
    }

    fn load_pairing_inbox(&mut self) -> Result<()> {
        if let Some(value) = self.store.secret("pairing-inbox-v1")? {
            self.pairing_inbox = serde_json::from_slice(&value).unwrap_or_default();
        }
        Ok(())
    }

    fn persist_pairing_inbox(&self) -> Result<()> {
        self.store.put_secret(
            "pairing-inbox-v1",
            &serde_json::to_vec(&self.pairing_inbox)?,
        )
    }

    fn load_pairing_offers(&mut self) -> Result<()> {
        if let Some(value) = self.store.secret("pairing-offers-v1")? {
            self.pairing_offers = serde_json::from_slice(&value).unwrap_or_default();
        }
        Ok(())
    }

    fn load_pending_pairing_offers(&mut self) -> Result<()> {
        if let Some(value) = self.store.secret("pending-pairing-offers-v1")? {
            self.pending_pairing_offers = serde_json::from_slice(&value).unwrap_or_default();
        }
        Ok(())
    }

    fn persist_pending_pairing_offers(&self) -> Result<()> {
        self.store.put_secret(
            "pending-pairing-offers-v1",
            &serde_json::to_vec(&self.pending_pairing_offers)?,
        )
    }

    fn persist_pairing_offers(&self) -> Result<()> {
        self.store.put_secret(
            "pairing-offers-v1",
            &serde_json::to_vec(&self.pairing_offers)?,
        )
    }

    fn load_dev_pair(&mut self, cli: &Cli) -> Result<()> {
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
        self.store.put_contact(&card, "dev")?;
        if !self
            .contacts
            .iter()
            .any(|existing| existing.installation_id == card.installation_id)
        {
            self.contacts.push(card.clone());
        }
        if !self.conversations.contains_key(&card.installation_id) {
            let snapshot = load_dev_snapshot(path, "peer_snapshot")?;
            let conversation =
                DirectConversation::restore(&snapshot).map_err(anyhow::Error::msg)?;
            self.store
                .put_conversation(&card.installation_id, &snapshot, 0)?;
            self.conversations
                .insert(card.installation_id.clone(), conversation);
        }
        self.selected_peer = Some(card.installation_id.clone());
        self.messages = self.store.messages(&card.installation_id)?;
        Ok(())
    }

    fn build_invite(&self, recipient_installation_id: Option<String>) -> Result<String> {
        let member = self
            .pending_member
            .as_ref()
            .context("MLS invitation state unavailable")?;
        let mut invite = ContactInvite {
            version: PROTOCOL_VERSION,
            installation_id: self.identity.installation_id(),
            public_key: self.identity.public_key(),
            fingerprint: self.identity.fingerprint(),
            nickname: Some(self.nickname.clone()),
            recipient_installation_id,
            key_package: URL_SAFE_NO_PAD.encode(member.key_package().map_err(anyhow::Error::msg)?),
            invite_id: Uuid::new_v4().to_string(),
            expires_at: unix_secs() + 15 * 60,
            signature: None,
        };
        invite.sign(&self.identity).map_err(anyhow::Error::msg)?;
        Ok(serde_json::to_string(&invite)?)
    }

    fn tick(&mut self) {
        while let Ok(status) = self.tor_events.try_recv() {
            self.status_phase = status.phase;
            self.status = status.label;
            self.status_progress = status.progress;
        }
        while let Ok(event) = self.relay_events.try_recv() {
            if let Err(error) = self.handle_relay_event(event) {
                self.error = format!("{error:#}");
                self.status_phase = "error".into();
            }
        }
        if self.connected && self.last_pairing_sync.elapsed() >= std::time::Duration::from_secs(20) {
            let _ = self.relay_commands.send(RelayCommand::PairingInbox);
            self.last_pairing_sync = Instant::now();
        }
        if self.screen == "splash" && self.started_at.elapsed().as_millis() >= 700 {
            self.screen = if self.connected {
                if self.nickname.trim().is_empty() {
                    "onboarding"
                } else {
                    "main"
                }
                .into()
            } else {
                "connection".into()
            };
        }
    }

    fn handle_relay_event(&mut self, event: RelayEvent) -> Result<()> {
        match event {
            RelayEvent::Status {
                phase,
                label,
                progress,
            } => {
                self.status_phase = phase;
                self.status = label;
                self.status_progress = progress;
                self.connected = false;
                self.error.clear();
            }
            RelayEvent::Connected => {
                self.connected = true;
                self.status_phase = "connected".into();
                self.status = "Onion połączony · relay aktywny".into();
                self.status_progress = 100;
                if self.started_at.elapsed().as_millis() >= 700 {
                    self.screen = if self.nickname.trim().is_empty() {
                        "onboarding"
                    } else {
                        "main"
                    }
                    .into();
                }
                self.error.clear();
                self.flush_pending_messages()?;
                self.flush_pending_pairing_offers()?;
                let _ = self.relay_commands.send(RelayCommand::RefreshPairingCode);
                let _ = self.relay_commands.send(RelayCommand::PairingInbox);
            }
            RelayEvent::PairingCode(code) => self.pairing_code = Some(code),
            RelayEvent::PairingRequestCreated => {}
            RelayEvent::PairingInbox(items) => {
                for item in items {
                    if !self
                        .pairing_inbox
                        .iter()
                        .any(|saved| saved.pairing_id == item.pairing_id)
                    {
                        self.pairing_inbox.push(item.clone());
                    }
                    let _ = self
                        .relay_commands
                        .send(RelayCommand::AcknowledgePairing(item.pairing_id));
                }
                self.persist_pairing_inbox()?;
            }
            RelayEvent::PairingAcknowledged => {}
            RelayEvent::ContactConfirmed => {}
            RelayEvent::MessageState { message_id, state } => {
                self.store
                    .set_message_state(&message_id.to_string(), &state)?;
                if let Some(message) = self
                    .messages
                    .iter_mut()
                    .find(|message| message.id == message_id.to_string())
                {
                    message.state = state;
                }
            }
            RelayEvent::Envelope(envelope) => self.receive_envelope(envelope)?,
            RelayEvent::Error(error) => {
                eprintln!("TorChat relay: {error}");
                self.error = error;
                self.connected = false;
                self.status_phase = "error".into();
            }
        }
        Ok(())
    }

    fn receive_envelope(&mut self, envelope: torchat_core::relay::RelayEnvelope) -> Result<()> {
        let payload = RelayPayloadV1::decode(&envelope.ciphertext).map_err(anyhow::Error::msg)?;
        match &payload {
            RelayPayloadV1::PairingOffer { invite, .. } => {
                self.accept_invite(invite)?;
            }
            RelayPayloadV1::PairingRejected { .. } => {}
            RelayPayloadV1::Welcome { sender, .. } => {
                payload
                    .verify_welcome(&envelope.sender, &self.identity.installation_id())
                    .map_err(anyhow::Error::msg)?;
                let (invite_id, welcome, tree) =
                    payload.decode_welcome().map_err(anyhow::Error::msg)?;
                let member = self
                    .pending_member
                    .take()
                    .context("no pending MLS invitation for Welcome")?;
                let snapshot = member.snapshot().map_err(anyhow::Error::msg)?;
                let conversation = match member.accept_conversation(&welcome, &tree) {
                    Ok(value) => value,
                    Err(error) => {
                        self.pending_member = Some(
                            MlsMember::restore(&snapshot, self.identity.public_key().as_bytes())
                                .map_err(anyhow::Error::msg)?,
                        );
                        return Err(anyhow::Error::msg(error));
                    }
                };
                self.pending_member = Some(
                    MlsMember::create(self.identity.public_key().as_bytes())
                        .map_err(anyhow::Error::msg)?,
                );
                self.store.put_contact(sender, "welcome")?;
                self.contacts
                    .retain(|value| value.installation_id != sender.installation_id);
                self.contacts.push(sender.clone());
                let snapshot = conversation.snapshot().map_err(anyhow::Error::msg)?;
                self.store
                    .put_conversation(&sender.installation_id, &snapshot, 0)?;
                self.conversations
                    .insert(sender.installation_id.clone(), conversation);
                self.selected_peer = Some(sender.installation_id.clone());
                self.messages = self.store.messages(&sender.installation_id)?;
                if let Some((capability, pairing_id)) = self.pairing_offers.remove(&invite_id) {
                    self.persist_pairing_offers()?;
                    self.pending_pairing_offers.remove(&pairing_id);
                    self.persist_pending_pairing_offers()?;
                    let _ = self.relay_commands.send(RelayCommand::ConfirmContact {
                        capability,
                        peer: envelope.sender.clone(),
                    });
                }
            }
            RelayPayloadV1::Application { .. } => {
                let conversation = self
                    .conversations
                    .get_mut(&envelope.sender)
                    .context("message received before MLS Welcome")?;
                let ciphertext = payload.decode_application().map_err(anyhow::Error::msg)?;
                let plaintext = conversation
                    .decrypt(&ciphertext)
                    .map_err(anyhow::Error::msg)?;
                let body = String::from_utf8(plaintext).context("message is not UTF-8")?;
                let message = StoredMessage {
                    id: envelope.message_id.to_string(),
                    peer: envelope.sender.clone(),
                    outgoing: false,
                    body,
                    state: "delivered".into(),
                    created_at: now_ms(),
                    relay_payload: None,
                };
                self.store.put_message(&message)?;
                self.store.put_conversation(
                    &envelope.sender,
                    &conversation.snapshot().map_err(anyhow::Error::msg)?,
                    if self.selected_peer.as_deref() == Some(&envelope.sender) {
                        0
                    } else {
                        1
                    },
                )?;
                if self.selected_peer.as_deref() == Some(&envelope.sender) {
                    self.messages.push(message);
                }
            }
        }
        let _ = self.relay_commands.send(RelayCommand::Receipt {
            message_id: envelope.message_id,
            sender: envelope.sender,
        });
        Ok(())
    }

    fn accept_invite(&mut self, value: &str) -> Result<()> {
        let invite = ContactInvite::parse(value.trim()).map_err(anyhow::Error::msg)?;
        anyhow::ensure!(
            invite.installation_id != self.identity.installation_id(),
            "nie można zaprosić samego siebie"
        );
        anyhow::ensure!(
            self.store.consume_invite(&invite.invite_id)?,
            "zaproszenie zostało już użyte"
        );
        let card = ContactCard {
            installation_id: invite.installation_id.clone(),
            public_key: invite.public_key.clone(),
            fingerprint: invite.fingerprint.clone(),
            nickname: invite
                .nickname
                .clone()
                .unwrap_or_else(|| invite.installation_id.clone()),
        };
        let member =
            MlsMember::create(self.identity.public_key().as_bytes()).map_err(anyhow::Error::msg)?;
        let mut direct = member.create_conversation().map_err(anyhow::Error::msg)?;
        let (welcome, tree) = direct
            .invite(
                &URL_SAFE_NO_PAD
                    .decode(invite.key_package)
                    .map_err(|_| anyhow::anyhow!("nieprawidłowy KeyPackage"))?,
            )
            .map_err(anyhow::Error::msg)?;
        self.store.put_contact(&card, "invite")?;
        self.store.put_conversation(
            &card.installation_id,
            &direct.snapshot().map_err(anyhow::Error::msg)?,
            0,
        )?;
        self.contacts
            .retain(|item| item.installation_id != card.installation_id);
        self.contacts.push(card.clone());
        self.conversations
            .insert(card.installation_id.clone(), direct);
        self.selected_peer = Some(card.installation_id.clone());
        self.messages = self.store.messages(&card.installation_id)?;
        let ciphertext = RelayPayloadV1::welcome(
            self.identity.as_ref(),
            &self.nickname,
            self.identity.installation_id(),
            invite.invite_id.clone(),
            &welcome,
            &tree,
        )
        .encode()
        .map_err(anyhow::Error::msg)?;
        self.relay_commands
            .send(RelayCommand::Send {
                message_id: Uuid::new_v4(),
                recipient: card.installation_id,
                ciphertext,
            })
            .map_err(|_| anyhow::anyhow!("relay actor stopped"))?;
        Ok(())
    }

    fn accept_pairing(&mut self, pairing_id: Uuid) -> Result<()> {
        let pairing = self
            .pairing_inbox
            .iter()
            .find(|item| item.pairing_id == pairing_id)
            .cloned()
            .context("pairing request does not exist")?;
        let invite = self.build_invite(Some(pairing.sender.installation_id.clone()))?;
        let invite_id = ContactInvite::parse(&invite)
            .map_err(anyhow::Error::msg)?
            .invite_id;
        self.pairing_offers
            .insert(invite_id, (pairing.capability.clone(), pairing.pairing_id));
        self.persist_pairing_offers()?;
        let payload = RelayPayloadV1::pairing_offer(
            pairing.pairing_id.to_string(),
            pairing.capability,
            invite,
        )
        .encode()
        .map_err(anyhow::Error::msg)?;
        self.pending_pairing_offers.insert(
            pairing.pairing_id,
            (pairing.sender.installation_id, payload),
        );
        self.persist_pending_pairing_offers()?;
        self.flush_pending_pairing_offers()?;
        Ok(())
    }

    fn reject_pairing(&mut self, pairing_id: Uuid) -> Result<()> {
        let pairing = self
            .pairing_inbox
            .iter()
            .find(|item| item.pairing_id == pairing_id)
            .cloned()
            .context("pairing request does not exist")?;
        let payload = RelayPayloadV1::pairing_rejected(pairing_id.to_string())
            .encode()
            .map_err(anyhow::Error::msg)?;
        self.relay_commands
            .send(RelayCommand::Send {
                message_id: Uuid::new_v4(),
                recipient: pairing.sender.installation_id,
                ciphertext: payload,
            })
            .map_err(|_| anyhow::anyhow!("relay actor stopped"))?;
        self.pairing_inbox.retain(|item| item.pairing_id != pairing_id);
        self.persist_pairing_inbox()
    }

    fn set_nickname(&mut self, nickname: &str) -> Result<()> {
        let nickname = nickname.trim();
        anyhow::ensure!(
            (2..=32).contains(&nickname.chars().count()),
            "nick musi mieć od 2 do 32 znaków"
        );
        anyhow::ensure!(
            nickname.chars().all(|value| value.is_alphanumeric()
                || value == ' '
                || value == '_'
                || value == '-'),
            "nick zawiera niedozwolone znaki"
        );
        self.relay_commands
            .send(RelayCommand::UpdateNickname(nickname.to_owned()))
            .map_err(|_| anyhow::anyhow!("relay actor stopped"))?;
        self.store
            .put_secret("profile-nickname-v1", nickname.as_bytes())?;
        self.nickname = nickname.to_owned();
        self.screen = "main".into();
        self.error.clear();
        Ok(())
    }

    fn send(&mut self, text: &str) -> Result<()> {
        let text = text.trim();
        if text.is_empty() {
            return Ok(());
        }
        let peer = self.selected_peer.clone().context("wybierz rozmowę")?;
        anyhow::ensure!(
            self.store.contact_is_verified(&peer)?,
            "potwierdź fingerprint kontaktu przed wysłaniem wiadomości"
        );
        let conversation = self
            .conversations
            .get_mut(&peer)
            .context("kontakt wymaga najpierw wymiany QR")?;
        let encrypted = conversation
            .encrypt(text.as_bytes())
            .map_err(anyhow::Error::msg)?;
        let message_id = Uuid::new_v4();
        let relay_payload = RelayPayloadV1::application(&encrypted)
            .encode()
            .map_err(anyhow::Error::msg)?;
        let message = StoredMessage {
            id: message_id.to_string(),
            peer: peer.clone(),
            outgoing: true,
            body: text.into(),
            state: if self.connected { "sending" } else { "pending" }.into(),
            created_at: now_ms(),
            relay_payload: Some(relay_payload),
        };
        self.store.put_message(&message)?;
        self.store.put_conversation(
            &peer,
            &conversation.snapshot().map_err(anyhow::Error::msg)?,
            0,
        )?;
        self.messages.push(message.clone());
        if self.connected {
            self.send_stored_message(&message)?;
        }
        Ok(())
    }

    fn flush_pending_messages(&mut self) -> Result<()> {
        for message in self.store.pending_outgoing()? {
            self.send_stored_message(&message)?;
        }
        Ok(())
    }

    fn flush_pending_pairing_offers(&self) -> Result<()> {
        if !self.connected {
            return Ok(());
        }
        for (recipient, ciphertext) in self.pending_pairing_offers.values() {
            self.relay_commands
                .send(RelayCommand::Send {
                    message_id: Uuid::new_v4(),
                    recipient: recipient.clone(),
                    ciphertext: ciphertext.clone(),
                })
                .map_err(|_| anyhow::anyhow!("relay actor stopped"))?;
        }
        Ok(())
    }

    fn send_stored_message(&mut self, message: &StoredMessage) -> Result<()> {
        let message_id = Uuid::parse_str(&message.id).context("invalid stored message ID")?;
        let ciphertext = message
            .relay_payload
            .clone()
            .context("stored outgoing message has no relay payload")?;
        self.store.set_message_state(&message.id, "sending")?;
        self.relay_commands
            .send(RelayCommand::Send {
                message_id,
                recipient: message.peer.clone(),
                ciphertext,
            })
            .map_err(|_| anyhow::anyhow!("relay actor stopped"))?;
        Ok(())
    }

}

impl Drop for DesktopState {
    fn drop(&mut self) {
        let _ = self.relay_commands.send(RelayCommand::Shutdown);
    }
}

fn load_dev_snapshot(path: &Path, field: &str) -> Result<Vec<u8>> {
    let value: serde_json::Value = serde_json::from_str(&fs::read_to_string(path)?)?;
    let encoded = value
        .get(field)
        .and_then(serde_json::Value::as_str)
        .with_context(|| format!("fixture has no {field}"))?;
    URL_SAFE_NO_PAD.decode(encoded).map_err(anyhow::Error::from)
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

fn unix_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs())
        .unwrap_or_default()
}

#[cfg(any())]
fn main() -> Result<()> {
    let cli = Cli::parse();
    if cli.stdio_runtime {
        return run_stdio_runtime(cli);
    }
    let headless_send = cli.headless_send.clone();
    if cli.headless_smoke || headless_send.is_some() {
        let mut state = DesktopState::new(cli)?;
        let deadline = Instant::now() + std::time::Duration::from_secs(90);
        let mut sent_message_id = None;
        while Instant::now() < deadline {
            state.tick();
            if state.connected {
                if let Some(text) = headless_send.as_deref() {
                    if sent_message_id.is_none() {
                        state.send(text)?;
                        sent_message_id = state.messages.last().map(|message| message.id.clone());
                    }
                    if let Some(message) = state
                        .messages
                        .iter()
                        .find(|message| Some(&message.id) == sent_message_id.as_ref())
                    {
                        if message.state == "delivered" {
                            println!(
                                "TorChat desktop delivered an MLS message to Android as {} ({})",
                                state.nickname,
                                state.identity.installation_id()
                            );
                            return Ok(());
                        }
                        if message.state == "failed" {
                            anyhow::bail!(
                                "Android peer is offline; relay rejected message {}",
                                message.id
                            );
                        }
                    }
                } else {
                    println!(
                        "TorChat desktop smoke connected as {} ({})",
                        state.nickname,
                        state.identity.installation_id()
                    );
                    return Ok(());
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        anyhow::bail!("desktop smoke timed out: {} {}", state.status, state.error)
    }
    let state = Rc::new(RefCell::new(DesktopState::new(cli)?));
    let window = MainWindow::new()?;
    refresh_window(&window, &state.borrow());

    {
        let state = state.clone();
        let weak = window.as_weak();
        window.on_connect_clicked(move || {
            let Some(window) = weak.upgrade() else {
                return;
            };
            state.borrow_mut().error.clear();
            refresh_window(&window, &state.borrow());
        });
    }
    {
        let state = state.clone();
        let weak = window.as_weak();
        window.on_search_clicked(move |query| {
            let Some(window) = weak.upgrade() else {
                return;
            };
            let _ = state
                .borrow()
                .relay_commands
                .send(RelayCommand::Search(query.to_string()));
            refresh_window(&window, &state.borrow());
        });
    }
    {
        let state = state.clone();
        let weak = window.as_weak();
        window.on_contact_selected(move |contact| {
            let Some(window) = weak.upgrade() else {
                return;
            };
            if let Err(error) = state.borrow_mut().select_contact(contact.as_str()) {
                state.borrow_mut().error = format!("{error:#}");
            }
            let current = state.borrow();
            let has_conversation = current
                .selected_peer
                .as_ref()
                .is_some_and(|peer| current.conversations.contains_key(peer));
            window.set_active_tab(
                if has_conversation {
                    "Czaty"
                } else {
                    "Kontakty"
                }
                .into(),
            );
            refresh_window(&window, &state.borrow());
        });
    }
    {
        let state = state.clone();
        let weak = window.as_weak();
        window.on_invite_submit(move |value| {
            let Some(window) = weak.upgrade() else {
                return;
            };
            if let Err(error) = state.borrow_mut().accept_invite(value.as_str()) {
                state.borrow_mut().error = format!("{error:#}");
            } else {
                window.set_invite_input("".into());
                state.borrow_mut().error.clear();
            }
            refresh_window(&window, &state.borrow());
        });
    }
    {
        let state = state.clone();
        let weak = window.as_weak();
        window.on_inbox_action(move |value| {
            let Some(window) = weak.upgrade() else {
                return;
            };
            let Some((action, encoded)) = value.split_once('|') else {
                return;
            };
            let Some(request_id) = encoded
                .split('|')
                .next()
                .and_then(|id| Uuid::parse_str(id).ok())
            else {
                state.borrow_mut().error = "Nieprawidłowe ID zaproszenia".into();
                refresh_window(&window, &state.borrow());
                return;
            };
            let result = if action == "accept" {
                state.borrow_mut().accept_request(request_id)
            } else {
                state.borrow_mut().update_request(request_id, action)
            };
            if let Err(error) = result {
                state.borrow_mut().error = format!("{error:#}");
            } else {
                state.borrow_mut().error.clear();
            }
            refresh_window(&window, &state.borrow());
        });
    }
    {
        let state = state.clone();
        let weak = window.as_weak();
        window.on_nickname_submit(move |value| {
            let Some(window) = weak.upgrade() else {
                return;
            };
            if let Err(error) = state.borrow_mut().set_nickname(value.as_str()) {
                state.borrow_mut().error = format!("{error:#}");
            }
            refresh_window(&window, &state.borrow());
        });
    }
    {
        let state = state.clone();
        let weak = window.as_weak();
        window.on_invite_contact(move |value| {
            let Some(window) = weak.upgrade() else {
                return;
            };
            if let Err(error) = state.borrow_mut().send_contact_request(value.as_str()) {
                state.borrow_mut().error = format!("{error:#}");
            }
            refresh_window(&window, &state.borrow());
        });
    }
    {
        let state = state.clone();
        let weak = window.as_weak();
        window.on_send_clicked(move |text| {
            let Some(window) = weak.upgrade() else {
                return;
            };
            if let Err(error) = state.borrow_mut().send(text.as_str()) {
                state.borrow_mut().error = format!("{error:#}");
            } else {
                window.set_composer("".into());
                state.borrow_mut().error.clear();
            }
            refresh_window(&window, &state.borrow());
        });
    }
    {
        let state = state.clone();
        let weak = window.as_weak();
        window.on_tab_changed(move |_| {
            let Some(window) = weak.upgrade() else {
                return;
            };
            refresh_window(&window, &state.borrow());
        });
    }

    let timer = Timer::default();
    {
        let state = state.clone();
        let weak = window.as_weak();
        timer.start(
            TimerMode::Repeated,
            std::time::Duration::from_millis(80),
            move || {
                let Some(window) = weak.upgrade() else {
                    return;
                };
                state.borrow_mut().tick();
                refresh_window(&window, &state.borrow());
            },
        );
    }
    window.run()?;
    Ok(())
}

#[cfg(not(any()))]
fn main() -> Result<()> {
    let cli = Cli::parse();
    if cli.stdio_runtime {
        return run_stdio_runtime(cli);
    }
    if cli.headless_smoke || cli.headless_send.is_some() {
        return run_headless(cli);
    }
    anyhow::bail!("The desktop frontend is Flutter. Run scripts/torchat.ps1 run -Target windows.")
}

#[cfg(not(any()))]
fn run_headless(cli: Cli) -> Result<()> {
    let headless_send = cli.headless_send.clone();
    let mut state = DesktopState::new(cli)?;
    let deadline = Instant::now() + std::time::Duration::from_secs(90);
    let mut sent_message_id = None;
    while Instant::now() < deadline {
        state.tick();
        if state.connected {
            if let Some(text) = headless_send.as_deref() {
                if sent_message_id.is_none() {
                    state.send(text)?;
                    sent_message_id = state.messages.last().map(|message| message.id.clone());
                }
                if let Some(message) = state
                    .messages
                    .iter()
                    .find(|message| Some(&message.id) == sent_message_id.as_ref())
                {
                    if message.state == "delivered" {
                        return Ok(());
                    }
                    if message.state == "failed" {
                        anyhow::bail!("relay rejected message {}", message.id);
                    }
                }
            } else {
                return Ok(());
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    anyhow::bail!(
        "desktop runtime smoke timed out: {} {}",
        state.status,
        state.error
    )
}

#[derive(Debug, serde::Deserialize)]
struct RuntimeRequest {
    id: Option<String>,
    method: String,
    params: Option<serde_json::Value>,
}

fn runtime_response(id: Option<String>, result: serde_json::Value) -> serde_json::Value {
    serde_json::json!({"id": id, "ok": true, "result": result})
}

fn runtime_error(id: Option<String>, error: impl std::fmt::Display) -> serde_json::Value {
    serde_json::json!({"id": id, "ok": false, "error": error.to_string()})
}

fn write_runtime(value: serde_json::Value) -> Result<()> {
    let mut stdout = std::io::stdout().lock();
    serde_json::to_writer(&mut stdout, &value)?;
    stdout.write_all(b"\n")?;
    stdout.flush()?;
    Ok(())
}

fn runtime_profile(state: &DesktopState) -> serde_json::Value {
    serde_json::json!({
        "installationId": state.identity.installation_id(),
        "nickname": if state.nickname.is_empty() { serde_json::Value::Null } else { serde_json::json!(state.nickname) },
        "publicKey": state.identity.public_key(),
        "fingerprint": state.identity.fingerprint(),
    })
}

fn runtime_contact(card: &ContactCard) -> serde_json::Value {
    serde_json::json!({
        "installationId": card.installation_id,
        "nickname": card.nickname,
        "publicKey": card.public_key,
        "fingerprint": card.fingerprint,
    })
}

fn runtime_messages(state: &DesktopState, peer: &str) -> Result<serde_json::Value> {
    Ok(serde_json::to_value(
        state
            .store
            .messages(peer)?
            .into_iter()
            .map(|m| {
                serde_json::json!({
                    "id": m.id, "peer": m.peer, "outgoing": m.outgoing, "body": m.body,
                    "state": m.state, "createdAt": m.created_at
                })
            })
            .collect::<Vec<_>>(),
    )?)
}

fn run_stdio_runtime(cli: Cli) -> Result<()> {
    let mut state = DesktopState::new(cli)?;
    write_runtime(serde_json::json!({"type":"runtime_ready","protocol":1}))?;
    let (request_tx, request_rx) = std::sync::mpsc::channel::<String>();
    std::thread::spawn(move || {
        let stdin = std::io::stdin();
        for line in stdin.lock().lines().map_while(Result::ok) {
            if request_tx.send(line).is_err() {
                break;
            }
        }
    });
    let mut last_status = String::new();
    let mut last_connected = false;
    loop {
        state.tick();
        let status_key = format!(
            "{}:{}:{}",
            state.status_phase, state.status_progress, state.status
        );
        if status_key != last_status {
            write_runtime(
                serde_json::json!({"type":"tor_status","phase":state.status_phase,"detail":state.status,"progress":state.status_progress}),
            )?;
            last_status = status_key;
        }
        if state.connected && !last_connected {
            write_runtime(
                serde_json::json!({"type":"profile_ready","profile":runtime_profile(&state),"identity":{"fingerprint":state.identity.fingerprint()}}),
            )?;
        }
        last_connected = state.connected;
        let line = match request_rx.recv_timeout(std::time::Duration::from_millis(100)) {
            Ok(value) => value,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
        };
        let request: RuntimeRequest = match serde_json::from_str(&line) {
            Ok(value) => value,
            Err(error) => {
                write_runtime(runtime_error(None, error))?;
                continue;
            }
        };
        let id = request.id.clone();
        let params = request.params.unwrap_or_else(|| serde_json::json!({}));
        let result: Result<serde_json::Value> = (|| {
            let text = |name: &str| {
                params
                    .get(name)
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("")
            };
            match request.method.as_str() {
                "connect" => Ok(serde_json::json!(true)),
                "identity" | "getProfile" => Ok(runtime_profile(&state)),
                "refreshPairingCode" => {
                    state
                        .relay_commands
                        .send(RelayCommand::RefreshPairingCode)
                        .map_err(|_| anyhow::anyhow!("relay actor stopped"))?;
                    let deadline = Instant::now() + std::time::Duration::from_secs(3);
                    while state.pairing_code.is_none() && Instant::now() < deadline {
                        state.tick();
                        std::thread::sleep(std::time::Duration::from_millis(50));
                    }
                    Ok(serde_json::to_value(state.pairing_code.clone())?)
                }
                "submitPairingCode" => {
                    state
                        .relay_commands
                        .send(RelayCommand::SubmitPairingCode(text("code").to_owned()))
                        .map_err(|_| anyhow::anyhow!("relay actor stopped"))?;
                    Ok(serde_json::json!(true))
                }
                "pairingInbox" => Ok(serde_json::to_value(state.pairing_inbox.clone())?),
                "acceptPairing" => {
                    state.accept_pairing(Uuid::parse_str(text("pairingId"))?)?;
                    Ok(serde_json::json!(true))
                }
                "rejectPairing" => {
                    state.reject_pairing(Uuid::parse_str(text("pairingId"))?)?;
                    Ok(serde_json::json!(true))
                }
                "verifyContact" => {
                    let installation_id = text("installationId");
                    state.store.verify_contact(installation_id)?;
                    Ok(serde_json::json!(true))
                }
                "setNickname" => {
                    state.set_nickname(text("nickname"))?;
                    Ok(runtime_profile(&state))
                }
                "contacts" => Ok(serde_json::Value::Array(
                    state.contacts.iter().map(|contact| {
                        let mut value = runtime_contact(contact);
                        value["verification"] = serde_json::json!(if state.store.contact_is_verified(&contact.installation_id).unwrap_or(false) { "VERIFIED" } else { "UNVERIFIED" });
                        value
                    }).collect(),
                )),
                "conversations" => {
                    let values = state.store.conversation_peers()?.into_iter().map(|peer| serde_json::json!({"id":peer,"contactInstallationId":peer,"lastMessagePreview":"Rozmowa","unreadCount":0})).collect();
                    Ok(serde_json::Value::Array(values))
                }
                "messages" => runtime_messages(&state, text("id")),
                "openConversation" => {
                    state.selected_peer = Some(text("id").to_owned());
                    Ok(serde_json::json!(true))
                }
                "sendMessage" => {
                    state.selected_peer = Some(text("id").to_owned());
                    state.send(text("text"))?;
                    Ok(serde_json::json!(true))
                }
                "shutdown" => Ok(serde_json::json!("shutdown")),
                method => anyhow::bail!("unknown runtime method: {method}"),
            }
        })();
        match result {
            Ok(value) => {
                write_runtime(runtime_response(id, value))?;
                if request.method == "shutdown" {
                    break;
                }
            }
            Err(error) => write_runtime(runtime_error(id, format!("{error:#}")))?,
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_snapshot(field: &str) -> Vec<u8> {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../protocol/dev-fixtures/android-peer.json"
        ))
        .unwrap();
        URL_SAFE_NO_PAD
            .decode(fixture[field].as_str().unwrap())
            .unwrap()
    }

    #[test]
    fn checked_in_mobile_desktop_fixture_exchanges_messages_both_ways() {
        let mut mobile =
            DirectConversation::restore(&fixture_snapshot("android_snapshot")).unwrap();
        let mut desktop = DirectConversation::restore(&fixture_snapshot("peer_snapshot")).unwrap();

        let mobile_ciphertext = mobile.encrypt(b"hello desktop").unwrap();
        let mobile_payload = RelayPayloadV1::application(&mobile_ciphertext)
            .encode()
            .unwrap();
        let decoded = RelayPayloadV1::decode(&mobile_payload)
            .unwrap()
            .decode_application()
            .unwrap();
        assert_eq!(desktop.decrypt(&decoded).unwrap(), b"hello desktop");

        let desktop_ciphertext = desktop.encrypt(b"hello mobile").unwrap();
        let desktop_payload = RelayPayloadV1::application(&desktop_ciphertext)
            .encode()
            .unwrap();
        let decoded = RelayPayloadV1::decode(&desktop_payload)
            .unwrap()
            .decode_application()
            .unwrap();
        assert_eq!(mobile.decrypt(&decoded).unwrap(), b"hello mobile");

        assert!(DirectConversation::restore(&mobile.snapshot().unwrap()).is_ok());
        assert!(DirectConversation::restore(&desktop.snapshot().unwrap()).is_ok());
    }
}
