use std::{
    pin::Pin,
    sync::mpsc::{self as std_mpsc, Receiver as StdReceiver, Sender as StdSender, TryRecvError},
    task::{Context as TaskContext, Poll},
    thread,
    time::Duration,
};

use futures_util::{SinkExt, StreamExt};
use reqwest::{
    StatusCode, Url,
    blocking::{Client, Response},
};
use serde::{Deserialize, Serialize};
use tokio::{
    io::{AsyncRead, AsyncWrite, ReadBuf},
    net::TcpStream,
    sync::mpsc::{self, Sender},
    time::{Instant, sleep, timeout},
};
use tokio_socks::tcp::Socks5Stream;
use tokio_tungstenite::{
    WebSocketStream, client_async,
    tungstenite::{Message, handshake::client::generate_key, http::Request},
};
use torchat_client_runtime::{
    ContactRecord, InviteCode, InviteState, PairingItem, RuntimeError, RuntimeResult,
    VerificationState,
};
use torchat_core::{
    Identity, is_valid_onion_address,
    relay::{ContactCard, RelayClientFrame, RelayEnvelope, RelayServerFrame},
};
use uuid::Uuid;

use super::{EngineRelay, RelayEvent};

type RelayStream = WebSocketStream<RelaySocket>;

// Relay HTTP calls currently run on the engine actor. Keep their failure
// budget short so an unavailable or warming onion cannot starve local
// commands (profile, contacts, conversations, and P2P state) for minutes.
// The actor owns retry/backoff, so availability is recovered by a later
// attempt rather than by one long blocking request.
// Tor onion circuits regularly take longer than a LAN/WebSocket budget would
// allow, especially immediately after bootstrap, after mobile network changes,
// or while a peer/relay onion is still warming. Keep the relay responsive, but
// do not tear it down so aggressively that healthy onion sessions flap.
const RELAY_CONNECT_TIMEOUT: Duration = Duration::from_secs(25);
const RELAY_REQUEST_TIMEOUT: Duration = Duration::from_secs(45);
const RELAY_READY_TIMEOUT: Duration = Duration::from_secs(35);

enum RelaySocket {
    Direct(TcpStream),
    Socks(Socks5Stream<TcpStream>),
}

impl AsyncRead for RelaySocket {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        match &mut *self {
            Self::Direct(stream) => Pin::new(stream).poll_read(cx, buf),
            Self::Socks(stream) => Pin::new(stream).poll_read(cx, buf),
        }
    }
}

impl AsyncWrite for RelaySocket {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        match &mut *self {
            Self::Direct(stream) => Pin::new(stream).poll_write(cx, buf),
            Self::Socks(stream) => Pin::new(stream).poll_write(cx, buf),
        }
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<std::io::Result<()>> {
        match &mut *self {
            Self::Direct(stream) => Pin::new(stream).poll_flush(cx),
            Self::Socks(stream) => Pin::new(stream).poll_flush(cx),
        }
    }

    fn poll_shutdown(
        mut self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
    ) -> Poll<std::io::Result<()>> {
        match &mut *self {
            Self::Direct(stream) => Pin::new(stream).poll_shutdown(cx),
            Self::Socks(stream) => Pin::new(stream).poll_shutdown(cx),
        }
    }
}

#[derive(Clone)]
enum WriterCommand {
    Envelope {
        message_id: Uuid,
        recipient: String,
        ciphertext: String,
    },
    Shutdown,
}

pub struct SharedRelayActor {
    pub connection: super::RelayConnectionConfig,
    pub writer: super::RelayWriterConfig,
    pub heartbeat: super::RelayHeartbeatConfig,
    session_token: Option<String>,
    identity: Identity,
    writer_commands: Option<Sender<WriterCommand>>,
    event_receiver: Option<StdReceiver<RelayEvent>>,
}

impl SharedRelayActor {
    pub fn new(relay_onion_url: Url, socks5_url: Option<String>, identity: Identity) -> Self {
        Self {
            connection: super::RelayConnectionConfig {
                connect_timeout: RELAY_CONNECT_TIMEOUT,
                ready_timeout: RELAY_READY_TIMEOUT,
                socks5_url,
                relay_onion_url: relay_onion_url.to_string(),
            },
            writer: super::RelayWriterConfig {
                control_channel_capacity: 64,
                data_channel_capacity: 256,
            },
            heartbeat: super::RelayHeartbeatConfig {
                ping_interval: Duration::from_secs(25),
                pong_timeout: Duration::from_secs(150),
            },
            session_token: None,
            identity,
            writer_commands: None,
            event_receiver: None,
        }
    }

    fn build_client(connection: &super::RelayConnectionConfig) -> RuntimeResult<Client> {
        let mut builder = Client::builder()
            .connect_timeout(connection.connect_timeout)
            .timeout(RELAY_REQUEST_TIMEOUT);
        if let Some(proxy) = &connection.socks5_url {
            builder = builder.proxy(
                reqwest::Proxy::all(proxy)
                    .map_err(|error| RuntimeError::Unavailable(error.to_string()))?,
            );
        }
        builder
            .build()
            .map_err(|error| RuntimeError::Unavailable(error.to_string()))
    }

    // reqwest::blocking::Client owns an internal Tokio runtime. The engine
    // actor itself runs on Tokio, so creating and dropping that client on an
    // actor worker panics (`Cannot drop a runtime ...`). Keep every blocking
    // HTTP request, including the client drop, on a scoped OS thread instead.
    fn run_http<T>(operation: impl FnOnce() -> RuntimeResult<T> + Send) -> RuntimeResult<T>
    where
        T: Send,
    {
        thread::scope(|scope| match scope.spawn(operation).join() {
            Ok(result) => result,
            Err(_) => Err(RuntimeError::Unavailable(
                "relay HTTP worker panicked".to_owned(),
            )),
        })
    }

    fn base_url(&self) -> RuntimeResult<Url> {
        let base_url = Url::parse(&self.connection.relay_onion_url)
            .map_err(|error| RuntimeError::Unavailable(error.to_string()))?;
        validate_relay_url(&base_url)?;
        Ok(base_url)
    }

    fn ensure_session_token(&mut self) -> RuntimeResult<String> {
        if let Some(token) = &self.session_token {
            return Ok(token.clone());
        }
        let base_url = self.base_url()?;
        let public_key = self.identity.public_key();
        let connection = self.connection.clone();
        let identity = &self.identity;
        let session: SessionResponse = Self::run_http(|| {
            let client = Self::build_client(&connection)?;
            let challenge: ChallengeResponse = client
                .post(
                    base_url
                        .join("/v1/bootstrap/challenge")
                        .map_err(http_error)?,
                )
                .json(&serde_json::json!({}))
                .send()
                .map_err(http_error)?
                .relay_status()?
                .json()
                .map_err(http_error)?;
            client
                .post(base_url.join("/v1/installations").map_err(http_error)?)
                .json(&RegisterRequest {
                    challenge_id: challenge.challenge_id,
                    public_key,
                    proof: identity.sign(challenge.challenge.as_bytes()),
                })
                .send()
                .map_err(http_error)?
                .relay_status()?
                .json()
                .map_err(http_error)
        })?;
        self.session_token = Some(session.session_token.clone());
        Ok(session.session_token)
    }

    fn ensure_writer(&mut self, token: &str) -> RuntimeResult<()> {
        if self
            .writer_commands
            .as_ref()
            .is_some_and(|commands| !commands.is_closed())
        {
            return Ok(());
        }
        self.writer_commands = None;
        self.event_receiver = None;
        let command_capacity = self
            .writer
            .control_channel_capacity
            .saturating_add(self.writer.data_channel_capacity)
            .max(1);
        let (command_tx, command_rx) = mpsc::channel(command_capacity);
        let (event_tx, event_rx) = std_mpsc::channel();
        let connection = self.connection.clone();
        let heartbeat = self.heartbeat.clone();
        let installation_id = self.identity.installation_id();
        let token = token.to_owned();
        thread::spawn(move || {
            let runtime = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(value) => value,
                Err(error) => {
                    eprintln!("[TorChat-Engine] relay runtime init failed: {error}");
                    return;
                }
            };
            runtime.block_on(run_writer_loop(
                connection,
                heartbeat,
                installation_id,
                token,
                command_rx,
                event_tx,
            ));
        });
        self.writer_commands = Some(command_tx);
        self.event_receiver = Some(event_rx);
        Ok(())
    }

    fn shutdown_writer(&mut self) {
        if let Some(commands) = self.writer_commands.take() {
            let _ = commands.try_send(WriterCommand::Shutdown);
        }
        self.event_receiver = None;
    }

    fn enqueue_writer_command(&mut self, command: WriterCommand) -> RuntimeResult<()> {
        let token = self.ensure_session_token()?;
        self.ensure_writer(&token)?;
        if let Some(commands) = &self.writer_commands
            && commands.try_send(command.clone()).is_ok()
        {
            return Ok(());
        }
        self.writer_commands = None;
        self.ensure_writer(&token)?;
        self.writer_commands
            .as_ref()
            .ok_or_else(|| RuntimeError::Unavailable("relay writer is unavailable".to_owned()))?
            .try_send(command)
            .map_err(|error| {
                RuntimeError::Unavailable(format!("relay writer queue is unavailable: {error}"))
            })
    }
}

impl EngineRelay for SharedRelayActor {
    fn set_socks5_url(&mut self, socks5_url: Option<String>) {
        self.shutdown_writer();
        self.connection.socks5_url = socks5_url;
        self.session_token = None;
    }

    fn shutdown(&mut self) {
        self.shutdown_writer();
        self.session_token = None;
    }

    fn ensure_session(&mut self) -> RuntimeResult<()> {
        let token = self.ensure_session_token()?;
        self.ensure_writer(&token)
    }

    fn update_profile(&mut self, nickname: &str) -> RuntimeResult<()> {
        let token = self.ensure_session_token()?;
        let base_url = self.base_url()?;
        let connection = self.connection.clone();
        let nickname = nickname.to_owned();
        Self::run_http(|| {
            Self::build_client(&connection)?
                .put(base_url.join("/v1/profile").map_err(http_error)?)
                .bearer_auth(token)
                .json(&UpdateProfileRequest { nickname })
                .send()
                .map_err(http_error)?
                .relay_status()?;
            Ok(())
        })
    }

    fn send_envelope(
        &mut self,
        message_id: Uuid,
        recipient: &str,
        ciphertext: &str,
    ) -> RuntimeResult<()> {
        self.enqueue_writer_command(WriterCommand::Envelope {
            message_id,
            recipient: recipient.to_owned(),
            ciphertext: ciphertext.to_owned(),
        })
    }

    fn poll_event(&mut self) -> Option<RelayEvent> {
        let receiver = self.event_receiver.as_ref()?;
        match receiver.try_recv() {
            Ok(event) => Some(event),
            Err(TryRecvError::Empty) => None,
            Err(TryRecvError::Disconnected) => {
                self.writer_commands = None;
                self.event_receiver = None;
                None
            }
        }
    }

    fn refresh_pairing_code(&mut self) -> RuntimeResult<InviteCode> {
        let token = self.ensure_session_token()?;
        let base_url = self.base_url()?;
        let connection = self.connection.clone();
        let response: PairingCodeResponse = Self::run_http(|| {
            Self::build_client(&connection)?
                .post(
                    base_url
                        .join("/v1/pairing-codes/refresh")
                        .map_err(http_error)?,
                )
                .bearer_auth(token)
                .send()
                .map_err(http_error)?
                .relay_status()?
                .json()
                .map_err(http_error)
        })?;
        Ok(InviteCode {
            code: response.code,
            expires_at: response.expires_at,
        })
    }

    fn submit_pairing_code(&mut self, code: &str) -> RuntimeResult<PairingItem> {
        let token = self.ensure_session_token()?;
        let base_url = self.base_url()?;
        let connection = self.connection.clone();
        let code = code.to_owned();
        let response: PairingRequestResponse = Self::run_http(|| {
            Self::build_client(&connection)?
                .post(base_url.join("/v1/pairing-requests").map_err(http_error)?)
                .bearer_auth(token)
                .json(&CreatePairingRequest { code })
                .send()
                .map_err(http_error)?
                .relay_status()?
                .json()
                .map_err(http_error)
        })?;
        Ok(PairingItem {
            pairing_id: response.pairing_id.to_string(),
            sender: response.sender.map(|sender| ContactRecord {
                installation_id: sender.installation_id,
                nickname: sender.nickname,
                public_key: sender.public_key,
                fingerprint: sender.fingerprint,
                local_alias: None,
                muted: false,
                blocked: false,
                verification: VerificationState::Unverified,
                peer_endpoint_status: torchat_client_runtime::PeerEndpointStatus::Missing,
                peer_connection_status: torchat_client_runtime::PeerConnectionStatus::Offline,
                last_peer_connected_at: None,
                transport_policy: Default::default(),
                dev: None,
            }),
            capability: None,
            expires_at: response.expires_at,
            state: response.state,
            received: false,
            available_actions: torchat_client_runtime::pairing_available_actions(
                response.state,
                false,
            ),
            offer_invite_id: None,
            offer_payload: None,
        })
    }

    fn pairing_inbox(&mut self) -> RuntimeResult<Vec<PairingItem>> {
        let token = self.ensure_session_token()?;
        let base_url = self.base_url()?;
        let connection = self.connection.clone();
        let response: Vec<PairingInboxItemResponse> = Self::run_http(|| {
            Self::build_client(&connection)?
                .get(
                    base_url
                        .join("/v1/pairing-requests/inbox")
                        .map_err(http_error)?,
                )
                .bearer_auth(token)
                .send()
                .map_err(http_error)?
                .relay_status()?
                .json()
                .map_err(http_error)
        })?;
        Ok(response
            .into_iter()
            .map(|item| PairingItem {
                pairing_id: item.pairing_id.to_string(),
                sender: Some(ContactRecord {
                    installation_id: item.sender.installation_id,
                    nickname: item.sender.nickname,
                    public_key: item.sender.public_key,
                    fingerprint: item.sender.fingerprint,
                    local_alias: None,
                    muted: false,
                    blocked: false,
                    verification: VerificationState::Unverified,
                    peer_endpoint_status: torchat_client_runtime::PeerEndpointStatus::Missing,
                    peer_connection_status: torchat_client_runtime::PeerConnectionStatus::Offline,
                    last_peer_connected_at: None,
                    transport_policy: Default::default(),
                    dev: None,
                }),
                capability: Some(item.capability),
                expires_at: item.expires_at,
                state: item.state,
                received: true,
                available_actions: torchat_client_runtime::pairing_available_actions(
                    item.state, true,
                ),
                offer_invite_id: item.offer_invite_id,
                offer_payload: item.offer_payload,
            })
            .collect())
    }

    fn acknowledge_pairing(&mut self, pairing_id: &str) -> RuntimeResult<()> {
        let token = self.ensure_session_token()?;
        let pairing_id = Uuid::parse_str(pairing_id)
            .map_err(|error| RuntimeError::InvalidParams(error.to_string()))?;
        let base_url = self.base_url()?;
        let connection = self.connection.clone();
        Self::run_http(|| {
            Self::build_client(&connection)?
                .post(
                    base_url
                        .join(&format!("/v1/pairing-requests/{pairing_id}/ack"))
                        .map_err(http_error)?,
                )
                .json(&serde_json::json!({}))
                .bearer_auth(token)
                .send()
                .map_err(http_error)?
                .relay_status()?;
            Ok(())
        })
    }

    fn cancel_pairing(&mut self, pairing_id: &str) -> RuntimeResult<()> {
        let token = self.ensure_session_token()?;
        let pairing_id = Uuid::parse_str(pairing_id)
            .map_err(|error| RuntimeError::InvalidParams(error.to_string()))?;
        let base_url = self.base_url()?;
        let connection = self.connection.clone();
        Self::run_http(|| {
            Self::build_client(&connection)?
                .delete(
                    base_url
                        .join(&format!("/v1/pairing-requests/{pairing_id}"))
                        .map_err(http_error)?,
                )
                .bearer_auth(token)
                .send()
                .map_err(http_error)?
                .relay_status()?;
            Ok(())
        })
    }

    fn confirm_contact(
        &mut self,
        capability: &str,
        peer_installation_id: &str,
    ) -> RuntimeResult<()> {
        let token = self.ensure_session_token()?;
        let base_url = self.base_url()?;
        let connection = self.connection.clone();
        let capability = capability.to_owned();
        let peer_installation_id = peer_installation_id.to_owned();
        Self::run_http(|| {
            Self::build_client(&connection)?
                .post(base_url.join("/v1/contacts/confirm").map_err(http_error)?)
                .bearer_auth(token)
                .json(&ConfirmContactRequest {
                    capability,
                    peer_installation_id,
                })
                .send()
                .map_err(http_error)?
                .relay_status()?;
            Ok(())
        })
    }
}

async fn run_writer_loop(
    connection: super::RelayConnectionConfig,
    heartbeat: super::RelayHeartbeatConfig,
    installation_id: String,
    token: String,
    mut commands: mpsc::Receiver<WriterCommand>,
    event_tx: StdSender<RelayEvent>,
) {
    let mut pending = None;
    let mut reconnect_attempt = 0_u32;
    loop {
        let relay = match connect_relay(&connection, &token).await {
            Ok(value) => value,
            Err(error) => {
                reconnect_attempt = reconnect_attempt.saturating_add(1);
                let reconnect_delay = relay_reconnect_delay(reconnect_attempt);
                let _ = event_tx.send(RelayEvent::Disconnected {
                    detail: error.to_string(),
                });
                let _ = event_tx.send(RelayEvent::Backoff {
                    attempt: reconnect_attempt,
                    retry_in_ms: reconnect_delay.as_millis() as u64,
                    detail: error.to_string(),
                });
                eprintln!("[TorChat-Engine] relay connect failed: {error}");
                if matches!(commands.try_recv(), Ok(WriterCommand::Shutdown)) {
                    return;
                }
                sleep(reconnect_delay).await;
                continue;
            }
        };
        reconnect_attempt = 0;
        let _ = event_tx.send(RelayEvent::Connected);
        let (mut writer, mut reader) = relay.split();
        let mut heartbeat_tick = tokio::time::interval(heartbeat.ping_interval);
        let mut last_pong_at = Instant::now();
        let disconnected_detail = loop {
            if last_pong_at.elapsed() >= heartbeat.pong_timeout {
                break "relay pong timeout".to_owned();
            }
            if let Some(command) = pending.take()
                && let Err(command) =
                    send_writer_command(&mut writer, &installation_id, command).await
            {
                pending = Some(command);
                break "relay send failed".to_owned();
            }
            tokio::select! {
                _ = heartbeat_tick.tick() => {
                    if writer.send(relay_ping_message()).await.is_err() {
                        break "relay ping failed".to_owned();
                    }
                    if writer.send(Message::Ping(Vec::new().into())).await.is_err() {
                        break "relay ping failed".to_owned();
                    }
                }
                command = commands.recv() => {
                    let Some(command) = command else {
                        return;
                    };
                    if matches!(command, WriterCommand::Shutdown) {
                        return;
                    }
                    if let Err(command) = send_writer_command(&mut writer, &installation_id, command).await {
                        pending = Some(command);
                        break "relay send failed".to_owned();
                    }
                }
                incoming = reader.next() => {
                    let Some(incoming) = incoming else {
                        break "relay closed".to_owned();
                    };
                    let Ok(message) = incoming else {
                        break "relay receive failed".to_owned();
                    };
                    if relay_message_confirms_liveness(&message) {
                        last_pong_at = Instant::now();
                    }
                    match message {
                        Message::Text(text) => match serde_json::from_str::<RelayServerFrame>(&text) {
                            Ok(RelayServerFrame::Pong) => {
                            }
                            Ok(RelayServerFrame::Envelope(envelope)) => {
                                let _ = event_tx.send(RelayEvent::Envelope(envelope));
                            }
                            Ok(RelayServerFrame::Forwarded { message_id }) => {
                                let _ = event_tx.send(RelayEvent::MessageTransportOutcome {
                                    message_id,
                                    outcome: torchat_client_runtime::MessageTransportOutcome::Forwarded,
                                });
                            }
                            Ok(RelayServerFrame::DeliveryReceipt { message_id }) => {
                                let _ = event_tx.send(RelayEvent::MessageTransportOutcome {
                                    message_id,
                                    outcome: torchat_client_runtime::MessageTransportOutcome::Delivered,
                                });
                            }
                            Ok(RelayServerFrame::RecipientOffline { message_id }) => {
                                let _ = event_tx.send(RelayEvent::MessageTransportOutcome {
                                    message_id,
                                    outcome: torchat_client_runtime::MessageTransportOutcome::RecipientOffline,
                                });
                            }
                            Ok(RelayServerFrame::Error { code }) => {
                                eprintln!("[TorChat-Engine] relay server error: {code}");
                            }
                            Ok(RelayServerFrame::Ready { .. }) => {}
                            Err(error) => {
                                eprintln!("[TorChat-Engine] invalid relay frame: {error}");
                            }
                        },
                        Message::Ping(payload) => {
                            if writer.send(Message::Pong(payload)).await.is_err() {
                                break "relay pong failed".to_owned();
                            }
                        }
                        Message::Pong(_) => {
                        }
                        Message::Close(_) => break "relay closed".to_owned(),
                        _ => {}
                    }
                }
            }
        };
        let _ = event_tx.send(RelayEvent::Disconnected {
            detail: disconnected_detail.clone(),
        });
        reconnect_attempt = reconnect_attempt.saturating_add(1);
        let reconnect_delay = relay_reconnect_delay(reconnect_attempt);
        let _ = event_tx.send(RelayEvent::Backoff {
            attempt: reconnect_attempt,
            retry_in_ms: reconnect_delay.as_millis() as u64,
            detail: disconnected_detail,
        });
        sleep(reconnect_delay).await;
    }
}

fn relay_reconnect_delay(attempt: u32) -> Duration {
    let seconds = 2_u64.saturating_pow(attempt.saturating_sub(1).min(5));
    Duration::from_secs(seconds.min(60))
}

async fn send_writer_command(
    writer: &mut futures_util::stream::SplitSink<RelayStream, Message>,
    installation_id: &str,
    command: WriterCommand,
) -> Result<(), WriterCommand> {
    match &command {
        WriterCommand::Envelope {
            message_id,
            recipient,
            ciphertext,
        } => {
            let frame = RelayClientFrame::Envelope(RelayEnvelope {
                version: torchat_core::PROTOCOL_VERSION,
                message_id: *message_id,
                sender: installation_id.to_owned(),
                recipient: recipient.clone(),
                ciphertext: ciphertext.clone(),
            });
            let payload = match serde_json::to_string(&frame) {
                Ok(value) => value,
                Err(_) => return Err(command),
            };
            if writer.send(Message::Text(payload.into())).await.is_err() {
                return Err(command);
            }
        }
        WriterCommand::Shutdown => {}
    }
    Ok(())
}

async fn connect_relay(
    connection: &super::RelayConnectionConfig,
    token: &str,
) -> RuntimeResult<RelayStream> {
    let base_url = Url::parse(&connection.relay_onion_url)
        .map_err(|error| RuntimeError::Unavailable(error.to_string()))?;
    validate_relay_url(&base_url)?;
    let host = base_url
        .host_str()
        .ok_or_else(|| RuntimeError::Unavailable("relay URL has no host".to_owned()))?
        .to_owned();
    let port = base_url
        .port_or_known_default()
        .ok_or_else(|| RuntimeError::Unavailable("relay URL has no port".to_owned()))?;

    let socket = if let Some(proxy) = &connection.socks5_url {
        let proxy_url =
            Url::parse(proxy).map_err(|error| RuntimeError::Unavailable(error.to_string()))?;
        let proxy_host = proxy_url
            .host_str()
            .ok_or_else(|| RuntimeError::Unavailable("SOCKS5 proxy has no host".to_owned()))?;
        let proxy_port = proxy_url
            .port_or_known_default()
            .ok_or_else(|| RuntimeError::Unavailable("SOCKS5 proxy has no port".to_owned()))?;
        RelaySocket::Socks(
            timeout(
                connection.connect_timeout,
                Socks5Stream::connect((proxy_host, proxy_port), (host.as_str(), port)),
            )
            .await
            .map_err(http_error)?
            .map_err(http_error)?,
        )
    } else {
        RelaySocket::Direct(
            timeout(
                connection.connect_timeout,
                TcpStream::connect((host.as_str(), port)),
            )
            .await
            .map_err(http_error)?
            .map_err(http_error)?,
        )
    };

    let mut ws_url = base_url.clone();
    ws_url
        .set_scheme(if ws_url.scheme() == "https" {
            "wss"
        } else {
            "ws"
        })
        .map_err(|_| RuntimeError::Unavailable("invalid websocket scheme".to_owned()))?;
    ws_url.set_path("/v1/events");
    let request = Request::builder()
        .uri(ws_url.as_str())
        .header("Host", format!("{host}:{port}"))
        .header("Authorization", format!("Bearer {token}"))
        .header("Upgrade", "websocket")
        .header("Connection", "Upgrade")
        .header("Sec-WebSocket-Key", generate_key())
        .header("Sec-WebSocket-Version", "13")
        .body(())
        .map_err(http_error)?;
    let (mut stream, _) = timeout(connection.connect_timeout, client_async(request, socket))
        .await
        .map_err(http_error)?
        .map_err(http_error)?;
    let ready = timeout(connection.ready_timeout, stream.next())
        .await
        .map_err(http_error)?
        .ok_or_else(|| RuntimeError::Unavailable("relay closed before ready".to_owned()))?
        .map_err(http_error)?;
    let Message::Text(ready) = ready else {
        return Err(RuntimeError::Unavailable(
            "relay returned non-text ready frame".to_owned(),
        ));
    };
    match serde_json::from_str::<RelayServerFrame>(&ready).map_err(http_error)? {
        RelayServerFrame::Ready { .. } => Ok(stream),
        _ => Err(RuntimeError::Unavailable(
            "relay did not return ready".to_owned(),
        )),
    }
}

fn relay_ping_message() -> Message {
    let payload = serde_json::to_string(&RelayClientFrame::Ping)
        .expect("relay ping frame must serialize");
    Message::Text(payload.into())
}

fn relay_message_confirms_liveness(message: &Message) -> bool {
    matches!(
        message,
        Message::Text(_) | Message::Ping(_) | Message::Pong(_) | Message::Binary(_)
    )
}

fn validate_relay_url(base_url: &Url) -> RuntimeResult<()> {
    let host = base_url
        .host_str()
        .ok_or_else(|| RuntimeError::Unavailable("relay URL has no host".to_owned()))?;
    if !is_valid_onion_address(host)
        || !matches!(base_url.scheme(), "http" | "https")
        || !base_url.username().is_empty()
        || base_url.password().is_some()
        || base_url.port().is_some()
        || base_url.path() != "/"
        || base_url.query().is_some()
        || base_url.fragment().is_some()
    {
        return Err(RuntimeError::Unavailable(
            "relay URL must be an exact v3 onion URL".to_owned(),
        ));
    }
    if base_url.scheme() == "http" && !base_url.as_str().starts_with("http://") {
        return Err(RuntimeError::Unavailable("invalid relay URL".to_owned()));
    }
    Ok(())
}

#[derive(Clone, Debug, Deserialize)]
struct ChallengeResponse {
    challenge_id: Uuid,
    challenge: String,
}

#[derive(Clone, Debug, Deserialize)]
struct SessionResponse {
    session_token: String,
}

#[derive(Clone, Debug, Serialize)]
struct RegisterRequest {
    challenge_id: Uuid,
    public_key: String,
    proof: String,
}

#[derive(Clone, Debug, Deserialize)]
struct PairingCodeResponse {
    code: String,
    expires_at: i64,
}

#[derive(Clone, Debug, Serialize)]
struct CreatePairingRequest {
    code: String,
}

#[derive(Clone, Debug, Serialize)]
struct UpdateProfileRequest {
    nickname: String,
}

#[derive(Clone, Debug, Serialize)]
struct ConfirmContactRequest {
    capability: String,
    peer_installation_id: String,
}

#[derive(Clone, Debug, Deserialize)]
struct PairingRequestResponse {
    pairing_id: Uuid,
    expires_at: i64,
    #[serde(default)]
    state: InviteState,
    #[serde(default)]
    sender: Option<ContactCard>,
}

#[derive(Clone, Debug, Deserialize)]
struct PairingInboxItemResponse {
    pairing_id: Uuid,
    sender: ContactCard,
    capability: String,
    expires_at: i64,
    #[serde(default)]
    state: InviteState,
    #[serde(default)]
    offer_invite_id: Option<String>,
    #[serde(default)]
    offer_payload: Option<String>,
}

fn http_error(error: impl std::fmt::Display) -> RuntimeError {
    RuntimeError::Unavailable(format!("relay transport error: {error}"))
}

trait RelayResponseExt {
    fn relay_status(self) -> RuntimeResult<Response>;
}

impl RelayResponseExt for Response {
    fn relay_status(self) -> RuntimeResult<Response> {
        let status = self.status();
        if status.is_success() {
            return Ok(self);
        }
        let message = self
            .json::<RelayErrorResponse>()
            .map(|body| body.error)
            .unwrap_or_else(|_| {
                status
                    .canonical_reason()
                    .unwrap_or("relay request failed")
                    .to_owned()
            });
        Err(relay_status_error(status, message))
    }
}

fn relay_status_error(status: StatusCode, message: String) -> RuntimeError {
    match status {
        StatusCode::BAD_REQUEST | StatusCode::UNPROCESSABLE_ENTITY => {
            RuntimeError::InvalidParams(message)
        }
        StatusCode::NOT_FOUND => RuntimeError::NotFound(message),
        StatusCode::CONFLICT => RuntimeError::Conflict(message),
        StatusCode::REQUEST_TIMEOUT | StatusCode::GATEWAY_TIMEOUT => RuntimeError::Timeout(message),
        _ => RuntimeError::Unavailable(message),
    }
}

#[derive(Deserialize)]
struct RelayErrorResponse {
    error: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relay_statuses_preserve_domain_error_categories() {
        assert_eq!(
            relay_status_error(StatusCode::BAD_REQUEST, "invalid code".to_owned()),
            RuntimeError::InvalidParams("invalid code".to_owned()),
        );
        assert_eq!(
            relay_status_error(StatusCode::NOT_FOUND, "expired code".to_owned()),
            RuntimeError::NotFound("expired code".to_owned()),
        );
        assert_eq!(
            relay_status_error(StatusCode::CONFLICT, "already pending".to_owned()),
            RuntimeError::Conflict("already pending".to_owned()),
        );
        assert_eq!(
            relay_status_error(StatusCode::TOO_MANY_REQUESTS, "try later".to_owned()),
            RuntimeError::Unavailable("try later".to_owned()),
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn blocking_http_client_is_dropped_outside_the_actor_runtime() {
        let result = SharedRelayActor::run_http(|| {
            let client = Client::builder()
                .build()
                .map_err(|error| RuntimeError::Unavailable(error.to_string()))?;
            drop(client);
            Ok(())
        });
        assert!(result.is_ok());
    }

    #[test]
    fn relay_ping_message_uses_application_ping_frame() {
        let message = relay_ping_message();
        let Message::Text(payload) = message else {
            panic!("relay ping must use a text frame");
        };
        let decoded: RelayClientFrame =
            serde_json::from_str(payload.as_ref()).expect("relay ping payload must decode");
        assert!(matches!(decoded, RelayClientFrame::Ping));
    }

    #[test]
    fn incoming_relay_traffic_counts_as_liveness() {
        assert!(relay_message_confirms_liveness(&Message::Text("{}".into())));
        assert!(relay_message_confirms_liveness(&Message::Ping(vec![1].into())));
        assert!(relay_message_confirms_liveness(&Message::Pong(vec![2].into())));
        assert!(!relay_message_confirms_liveness(&Message::Close(None)));
    }

    #[test]
    fn default_relay_timeouts_are_tor_tolerant() {
        let actor = SharedRelayActor::new(
            Url::parse(
                "http://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.onion",
            )
            .expect("test relay URL must parse"),
            Some("socks5://127.0.0.1:9050".to_owned()),
            Identity::generate(),
        );

        assert_eq!(actor.connection.connect_timeout, Duration::from_secs(25));
        assert_eq!(actor.connection.ready_timeout, Duration::from_secs(35));
        assert_eq!(actor.heartbeat.pong_timeout, Duration::from_secs(150));
    }

    #[test]
    fn pairing_request_response_can_include_peer_hint() {
        let decoded: PairingRequestResponse = serde_json::from_value(serde_json::json!({
            "pairing_id": Uuid::nil(),
            "expires_at": 1,
            "state": "PENDING",
            "sender": {
                "installation_id": "installation-torka",
                "nickname": "Torka",
                "public_key": "public-key",
                "fingerprint": "fingerprint"
            }
        }))
        .expect("response should decode");

        assert_eq!(
            decoded.sender.as_ref().map(|value| value.installation_id.as_str()),
            Some("installation-torka")
        );
    }
}
