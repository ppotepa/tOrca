mod cli;
mod identity_store;
mod model;
mod store;
mod tor_runtime;
mod transport;

slint::include_modules!();

use anyhow::{Context, Result};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use clap::Parser;
use cli::Cli;
use model::DirectoryEntry;
use qrcode::{Color, QrCode};
use slint::{
    Image, ModelRc, Rgba8Pixel, SharedPixelBuffer, SharedString, Timer, TimerMode, VecModel,
};
use std::{
    cell::RefCell,
    collections::HashMap,
    fs,
    path::Path,
    rc::Rc,
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
    directory: Vec<DirectoryEntry>,
    conversations: HashMap<String, DirectConversation>,
    selected_peer: Option<String>,
    messages: Vec<StoredMessage>,
    error: String,
    own_invite: String,
    started_at: Instant,
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
        let nickname = cli.nickname.clone().unwrap_or_else(|| "Bob".into());

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
            directory: Vec::new(),
            conversations: HashMap::new(),
            selected_peer: None,
            messages: Vec::new(),
            error: String::new(),
            own_invite: String::new(),
            started_at: Instant::now(),
        };
        state.load_local_state()?;
        state.load_dev_pair(&cli)?;
        state.refresh_invite()?;
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

    fn refresh_invite(&mut self) -> Result<()> {
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
            key_package: URL_SAFE_NO_PAD.encode(member.key_package().map_err(anyhow::Error::msg)?),
            invite_id: Uuid::new_v4().to_string(),
            expires_at: unix_secs() + 15 * 60,
            signature: None,
        };
        invite.sign(&self.identity).map_err(anyhow::Error::msg)?;
        self.own_invite = serde_json::to_string(&invite)?;
        self.store.put_secret(
            "mls-inbox-v1",
            &member.snapshot().map_err(anyhow::Error::msg)?,
        )?;
        Ok(())
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
        if self.screen == "splash" && self.started_at.elapsed().as_millis() >= 700 {
            self.screen = if self.connected {
                "main".into()
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
                    self.screen = "main".into();
                }
                self.error.clear();
                self.flush_pending_messages()?;
            }
            RelayEvent::SearchResults(results) => self.directory = results,
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
            RelayPayloadV1::Welcome { sender, .. } => {
                payload
                    .verify_welcome(&envelope.sender, &self.identity.installation_id())
                    .map_err(anyhow::Error::msg)?;
                let (welcome, tree) = payload.decode_welcome().map_err(anyhow::Error::msg)?;
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
                self.refresh_invite()?;
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

    fn select_contact(&mut self, display: &str) -> Result<()> {
        let card = self
            .all_contacts()
            .into_iter()
            .find(|contact| contact_display(contact) == display);
        let Some(card) = card else {
            return Ok(());
        };
        self.store.put_contact(&card, "directory")?;
        if !self
            .contacts
            .iter()
            .any(|value| value.installation_id == card.installation_id)
        {
            self.contacts.push(card.clone());
        }
        self.selected_peer = Some(card.installation_id.clone());
        self.messages = self.store.messages(&card.installation_id)?;
        if !self.conversations.contains_key(&card.installation_id) {
            self.error = "Ten kontakt wymaga wymiany QR przed rozpoczęciem rozmowy.".into();
        } else {
            self.error.clear();
        }
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

    fn send(&mut self, text: &str) -> Result<()> {
        let text = text.trim();
        if text.is_empty() {
            return Ok(());
        }
        let peer = self.selected_peer.clone().context("wybierz rozmowę")?;
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

    fn all_contacts(&self) -> Vec<ContactCard> {
        let mut values = self.contacts.clone();
        for item in &self.directory {
            if item.installation_id == self.identity.installation_id()
                || values
                    .iter()
                    .any(|value| value.installation_id == item.installation_id)
            {
                continue;
            }
            values.push(ContactCard {
                installation_id: item.installation_id.clone(),
                public_key: item.public_key.clone(),
                fingerprint: item.fingerprint.clone(),
                nickname: item.nickname.clone(),
            });
        }
        values.sort_by(|left, right| {
            left.nickname
                .to_lowercase()
                .cmp(&right.nickname.to_lowercase())
        });
        values
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

fn strings(values: impl IntoIterator<Item = String>) -> ModelRc<SharedString> {
    ModelRc::new(VecModel::from(
        values
            .into_iter()
            .map(SharedString::from)
            .collect::<Vec<_>>(),
    ))
}

fn contact_display(card: &ContactCard) -> String {
    format!("@{} · {}", card.nickname, card.fingerprint)
}

fn message_views(values: &[StoredMessage]) -> ModelRc<ChatMessageView> {
    ModelRc::new(VecModel::from(
        values
            .iter()
            .map(|message| ChatMessageView {
                body: message.body.clone().into(),
                meta: if message.outgoing {
                    format!("Ty · {}", message.state).into()
                } else {
                    "Kontakt · E2EE".into()
                },
                outgoing: message.outgoing,
            })
            .collect::<Vec<_>>(),
    ))
}

fn qr_image(value: &str) -> Result<Image> {
    let code = QrCode::new(value.as_bytes()).context("generate QR")?;
    let width = code.width();
    let quiet = 4_usize;
    let scale = 5_usize;
    let size = (width + quiet * 2) * scale;
    let mut buffer = SharedPixelBuffer::<Rgba8Pixel>::new(size as u32, size as u32);
    let pixels = buffer.make_mut_slice();
    for pixel in pixels.iter_mut() {
        *pixel = Rgba8Pixel {
            r: 245,
            g: 248,
            b: 255,
            a: 255,
        };
    }
    for y in 0..width {
        for x in 0..width {
            if code[(x, y)] != Color::Dark {
                continue;
            }
            for sy in 0..scale {
                for sx in 0..scale {
                    let px = (x + quiet) * scale + sx;
                    let py = (y + quiet) * scale + sy;
                    pixels[py * size + px] = Rgba8Pixel {
                        r: 13,
                        g: 20,
                        b: 32,
                        a: 255,
                    };
                }
            }
        }
    }
    Ok(Image::from_rgba8(buffer))
}

fn refresh_window(window: &MainWindow, state: &DesktopState) {
    window.set_screen(state.screen.clone().into());
    window.set_status(state.status.clone().into());
    window.set_status_phase(state.status_phase.clone().into());
    window.set_status_progress(state.status_progress);
    window.set_nickname(state.nickname.clone().into());
    window.set_fingerprint(state.identity.fingerprint().into());
    window.set_installation_id(state.identity.installation_id().into());
    window.set_error_text(state.error.clone().into());
    window.set_contacts(strings(state.all_contacts().iter().map(contact_display)));
    window.set_messages(message_views(&state.messages));
    window.set_own_invite(state.own_invite.clone().into());
    if let Ok(image) = qr_image(&state.own_invite) {
        window.set_own_qr(image);
    }
    let selected = state
        .selected_peer
        .as_deref()
        .and_then(|peer| {
            state
                .all_contacts()
                .into_iter()
                .find(|contact| contact.installation_id == peer)
        })
        .map(|contact| contact_display(&contact))
        .unwrap_or_default();
    window.set_selected_contact(selected.into());
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

fn main() -> Result<()> {
    let cli = Cli::parse();
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
            window.set_active_tab("Czaty".into());
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

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_snapshot(field: &str) -> Vec<u8> {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../protocol/dev-fixtures/android-peer.json"
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
