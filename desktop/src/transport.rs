use crate::model::{
    ChallengeResponse, ClientFrame, PairingCodeResponse, PairingInboxItem, RegisterRequest,
    ServerFrame, SessionResponse,
};
use anyhow::{Context, Result, bail};
use futures_util::{SinkExt, StreamExt};
use reqwest::{Client, Url};
use std::{
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    task::{Context as TaskContext, Poll},
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncRead, AsyncWrite, ReadBuf},
    net::TcpStream,
    sync::mpsc,
    time::timeout,
};
use tokio_socks::tcp::Socks5Stream;
use tokio_tungstenite::{
    WebSocketStream, client_async,
    tungstenite::{Message, handshake::client::generate_key, http::Request},
};
use torchat_client_runtime::{InviteState, MessageTransportOutcome};
use torchat_core::{Identity, is_valid_onion_address, relay::RelayEnvelope};
use uuid::Uuid;

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

type Relay = WebSocketStream<RelaySocket>;

#[derive(Clone, Copy, Debug)]
enum RelayFailureCode {
    SocksTimeout,
    WsHandshakeTimeout,
    ReadyTimeout,
    PongTimeout,
    RemoteClose,
    ReadError,
    WriteError,
    AuthExpired,
    HttpRetryable,
    HttpPermanent,
    Unknown,
}

fn classify_relay_error(message: &str) -> RelayFailureCode {
    let lowered = message.to_ascii_lowercase();
    if lowered.contains("401") || lowered.contains("403") || lowered.contains("expired") {
        RelayFailureCode::AuthExpired
    } else if lowered.contains("websocket handshake timeout") {
        RelayFailureCode::WsHandshakeTimeout
    } else if lowered.contains("ready timeout") || lowered.contains("did not return ready") {
        RelayFailureCode::ReadyTimeout
    } else if lowered.contains("pong timeout") {
        RelayFailureCode::PongTimeout
    } else if lowered.contains("relay connect timeout") || lowered.contains("timed out") {
        RelayFailureCode::SocksTimeout
    } else if lowered.contains("closed") {
        RelayFailureCode::RemoteClose
    } else if lowered.contains("send failed") || lowered.contains("heartbeat failed") || lowered.contains("pong failed") {
        RelayFailureCode::WriteError
    } else if lowered.contains("receive failed") {
        RelayFailureCode::ReadError
    } else if lowered.contains("429") || lowered.contains("5") && lowered.contains("relay:") {
        RelayFailureCode::HttpRetryable
    } else if lowered.contains("relay:") {
        RelayFailureCode::HttpPermanent
    } else {
        RelayFailureCode::Unknown
    }
}

#[derive(Debug)]
pub enum RelayCommand {
    Send {
        message_id: Uuid,
        recipient: String,
        ciphertext: String,
    },
    UpdateNickname(String),
    RefreshPairingCode,
    SubmitPairingCode(String),
    CancelPairing(Uuid),
    PairingInbox,
    AcknowledgePairing(Uuid),
    ConfirmContact {
        capability: String,
        peer: String,
    },
    Shutdown,
}

#[derive(Debug)]
pub enum RelayEvent {
    Status {
        phase: String,
        label: String,
        progress: i32,
        latency_ms: Option<u64>,
    },
    Connected,
    PairingCode(PairingCodeResponse),
    PairingRequestCreated {
        pairing_id: Uuid,
        expires_at: i64,
        state: InviteState,
    },
    PairingCancelled(Uuid),
    PairingInbox(Vec<PairingInboxItem>),
    PairingAcknowledged,
    ContactConfirmed,
    Envelope(RelayEnvelope),
    MessageTransportOutcome {
        message_id: Uuid,
        outcome: MessageTransportOutcome,
    },
    Error(String),
}

#[derive(Clone)]
pub struct ApiTransport {
    client: Client,
    base_url: Url,
    socks5_proxy: Option<String>,
}

impl ApiTransport {
    pub fn new(server_url: &str, socks5_proxy: Option<&str>) -> Result<Self> {
        let base_url = Url::parse(server_url).context("invalid server URL")?;
        let host = base_url.host_str().context("server URL has no host")?;
        if !is_valid_onion_address(host)
            || !matches!(base_url.scheme(), "http" | "https")
            || base_url.username() != ""
            || base_url.password().is_some()
            || base_url.port().is_some()
            || base_url.path() != "/"
            || base_url.query().is_some()
            || base_url.fragment().is_some()
        {
            bail!("server URL must be an exact v3 onion URL")
        }
        if socks5_proxy.is_none() {
            bail!("TorChat requires a Tor SOCKS proxy")
        }
        let mut builder = Client::builder()
            // Bound one failed onion circuit. The actor retries with backoff
            // instead of leaving a desktop splash stuck on a dead route.
            .connect_timeout(Duration::from_secs(60))
            .timeout(Duration::from_secs(75));
        if let Some(proxy) = socks5_proxy {
            builder = builder.proxy(reqwest::Proxy::all(proxy).context("invalid SOCKS5 proxy")?);
        }
        Ok(Self {
            client: builder.build().context("build HTTP client")?,
            base_url,
            socks5_proxy: socks5_proxy.map(str::to_owned),
        })
    }

    async fn endpoint(&self, path: &str) -> Result<reqwest::Response> {
        Ok(self
            .client
            .post(self.base_url.join(path)?)
            // Axum's JSON extractor rejects a missing body.  These bootstrap
            // commands have no fields, but they still use JSON semantics.
            .json(&serde_json::json!({}))
            .send()
            .await?
            .error_for_status()?)
    }

    async fn warmup_onion(&self) -> Result<u64> {
        let started = Instant::now();
        self.client
            .get(self.base_url.join("/health")?)
            .send()
            .await?
            .error_for_status()?;
        Ok(started.elapsed().as_millis() as u64)
    }

    async fn bootstrap(&self, identity: &Identity) -> Result<SessionResponse> {
        let challenge: ChallengeResponse = self
            .endpoint("/v1/bootstrap/challenge")
            .await?
            .json()
            .await?;
        let request = RegisterRequest {
            challenge_id: challenge.challenge_id,
            public_key: identity.public_key(),
            proof: identity.sign(challenge.challenge.as_bytes()),
        };
        Ok(self
            .client
            .post(self.base_url.join("/v1/installations")?)
            .json(&request)
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?)
    }

    async fn connect_relay(&self, token: &str) -> Result<Relay> {
        let host = self
            .base_url
            .host_str()
            .context("server URL has no host")?
            .to_owned();
        let port = self
            .base_url
            .port_or_known_default()
            .context("server URL has no port")?;
        let socket = if let Some(proxy) = &self.socks5_proxy {
            let proxy_url = Url::parse(proxy).context("invalid SOCKS5 proxy URL")?;
            let proxy_host = proxy_url.host_str().context("SOCKS5 proxy has no host")?;
            let proxy_port = proxy_url
                .port_or_known_default()
                .context("SOCKS5 proxy has no port")?;
            RelaySocket::Socks(
                timeout(
                    Duration::from_secs(180),
                    Socks5Stream::connect((proxy_host, proxy_port), (host.as_str(), port)),
                )
                .await
                .context("relay connect timeout")??,
            )
        } else {
            RelaySocket::Direct(
                timeout(
                    Duration::from_secs(180),
                    TcpStream::connect((host.as_str(), port)),
                )
                .await
                .context("relay connect timeout")??,
            )
        };
        let mut ws_url = self.base_url.clone();
        ws_url
            .set_scheme(if ws_url.scheme() == "https" {
                "wss"
            } else {
                "ws"
            })
            .map_err(|_| anyhow::anyhow!("invalid WebSocket scheme"))?;
        ws_url.set_path("/v1/events");
        let request = Request::builder()
            .uri(ws_url.as_str())
            .header("Host", format!("{host}:{port}"))
            .header("Authorization", format!("Bearer {token}"))
            .header("Upgrade", "websocket")
            .header("Connection", "Upgrade")
            .header("Sec-WebSocket-Key", generate_key())
            .header("Sec-WebSocket-Version", "13")
            .body(())?;
        let (mut stream, _) = timeout(Duration::from_secs(180), client_async(request, socket))
            .await
            .context("relay websocket handshake timeout")??;
        let ready = timeout(Duration::from_secs(60), stream.next())
            .await
            .context("relay ready timeout")?
            .context("relay closed before ready")??;
        let Message::Text(ready) = ready else {
            bail!("relay returned non-text ready frame")
        };
        if !matches!(
            serde_json::from_str::<ServerFrame>(&ready)?,
            ServerFrame::Ready { .. }
        ) {
            bail!("relay did not return ready")
        }
        Ok(stream)
    }

    async fn update_nickname(&self, token: &str, nickname: &str) -> Result<()> {
        self.client
            .put(self.base_url.join("/v1/profile")?)
            .bearer_auth(token)
            .json(&serde_json::json!({ "nickname": nickname }))
            .send()
            .await?
            .error_for_status()?;
        Ok(())
    }

    async fn refresh_pairing_code(&self, token: &str) -> Result<PairingCodeResponse> {
        Ok(self
            .client
            .post(self.base_url.join("/v1/pairing-codes/refresh")?)
            .bearer_auth(token)
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?)
    }

    async fn create_pairing_request(
        &self,
        token: &str,
        code: &str,
    ) -> Result<crate::model::PairingRequestResponse> {
        Ok(self
            .client
            .post(self.base_url.join("/v1/pairing-requests")?)
            .bearer_auth(token)
            .json(&serde_json::json!({"code": code}))
            .send()
            .await?
            .error_for_status()?
            .json::<crate::model::PairingRequestResponse>()
            .await?)
    }

    async fn pairing_inbox(&self, token: &str) -> Result<Vec<PairingInboxItem>> {
        Ok(self
            .client
            .get(self.base_url.join("/v1/pairing-requests/inbox")?)
            .bearer_auth(token)
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?)
    }

    async fn acknowledge_pairing(&self, token: &str, pairing_id: Uuid) -> Result<()> {
        self.client
            .post(
                self.base_url
                    .join(&format!("/v1/pairing-requests/{pairing_id}/ack"))?,
            )
            .bearer_auth(token)
            .json(&serde_json::json!({}))
            .send()
            .await?
            .error_for_status()?;
        Ok(())
    }

    async fn cancel_pairing(&self, token: &str, pairing_id: Uuid) -> Result<()> {
        self.client
            .delete(
                self.base_url
                    .join(&format!("/v1/pairing-requests/{pairing_id}"))?,
            )
            .bearer_auth(token)
            .send()
            .await?
            .error_for_status()?;
        Ok(())
    }

    async fn confirm_contact(&self, token: &str, capability: &str, peer: &str) -> Result<()> {
        self.client
            .post(self.base_url.join("/v1/contacts/confirm")?)
            .bearer_auth(token)
            .json(&serde_json::json!({"capability": capability, "peer_installation_id": peer}))
            .send()
            .await?
            .error_for_status()?;
        Ok(())
    }
}

pub fn spawn_relay_actor(
    runtime: &tokio::runtime::Runtime,
    transport: ApiTransport,
    identity: Arc<Identity>,
    nickname: String,
    tor_ready: Arc<AtomicBool>,
) -> (
    mpsc::Sender<RelayCommand>,
    std::sync::mpsc::Receiver<RelayEvent>,
) {
    let (command_tx, mut command_rx) = mpsc::channel(256);
    let (event_tx, event_rx) = std::sync::mpsc::channel();
    runtime.spawn(async move {
        while !tor_ready.load(Ordering::Acquire) {
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        let retry_delays = [1_u64, 2, 5, 10, 30];
        let mut retry_index = 0_usize;
        let mut cached_token: Option<String> = None;
        loop {
            eprintln!(
                "[TorChat-Relay] phase=connecting retryAttempt={retry_index} step=warmup_start"
            );
            let _ = event_tx.send(RelayEvent::Status {
                phase: "connecting".into(),
                label: "Rozgrzewanie circuitu onion…".into(),
                progress: 76,
                latency_ms: None,
            });
            let connected = async {
                let latency_ms = transport.warmup_onion().await?;
                eprintln!(
                    "[TorChat-Relay] phase=authenticating retryAttempt={retry_index} step=bootstrap_start latencyMs={latency_ms}"
                );
                let _ = event_tx.send(RelayEvent::Status {
                    phase: "api".into(),
                    label: "Circuit onion gotowy · uwierzytelnianie relaya".into(),
                    progress: 86,
                    latency_ms: Some(latency_ms),
                });
                if let Some(token) = cached_token.as_deref() {
                    if let Ok(relay) = transport.connect_relay(token).await {
                        eprintln!(
                            "[TorChat-Relay] phase=connected retryAttempt={retry_index} step=session_resume latencyMs={latency_ms}"
                        );
                        return Ok::<_, anyhow::Error>((token.to_owned(), relay, latency_ms));
                    }
                    cached_token = None;
                }
                let session = transport.bootstrap(&identity).await?;
                if !nickname.trim().is_empty() {
                    transport
                        .update_nickname(&session.session_token, &nickname)
                        .await?;
                }
                let relay = transport.connect_relay(&session.session_token).await?;
                cached_token = Some(session.session_token.clone());
                eprintln!(
                    "[TorChat-Relay] phase=connected retryAttempt={retry_index} step=fresh_session latencyMs={latency_ms}"
                );
                Ok::<_, anyhow::Error>((session.session_token, relay, latency_ms))
            }
            .await;
            let (token, relay, _latency_ms) = match connected {
                Ok(value) => value,
                Err(error) => {
                    let detail = format!("{error:#}");
                    let code = classify_relay_error(&detail);
                    eprintln!(
                        "[TorChat-Relay] phase=backoff retryAttempt={retry_index} code={code:?} detail={detail}"
                    );
                    let _ = event_tx.send(RelayEvent::Error(format!("{error:#}")));
                    let delay = retry_delays[retry_index.min(retry_delays.len() - 1)];
                    retry_index = (retry_index + 1).min(retry_delays.len() - 1);
                    tokio::time::sleep(Duration::from_secs(delay)).await;
                    continue;
                }
            };
            retry_index = 0;
            let _ = event_tx.send(RelayEvent::Connected);
            eprintln!("[TorChat-Relay] phase=connected retryAttempt=0 step=websocket_ready");
            let (mut writer, mut reader) = relay.split();
            let mut last_pong_at = Instant::now();
            let mut heartbeat = tokio::time::interval(Duration::from_secs(25));
            heartbeat.tick().await;
            let disconnected = loop {
                tokio::select! {
                    _ = heartbeat.tick() => {
                        if last_pong_at.elapsed() > Duration::from_secs(75) {
                            break "relay websocket pong timeout".into();
                        }
                        if let Err(error) = writer.send(Message::Ping(Vec::new().into())).await {
                            break format!("relay heartbeat failed: {error}");
                        }
                    }
                    command = command_rx.recv() => {
                        match command {
                            Some(RelayCommand::UpdateNickname(nickname)) => {
                                if let Err(error) = transport.update_nickname(&token, &nickname).await {
                                    let _ = event_tx.send(RelayEvent::Error(format!("nickname update failed: {error:#}")));
                                }
                            }
                            Some(RelayCommand::Send { message_id, recipient, ciphertext }) => {
                                let frame = ClientFrame::Envelope(RelayEnvelope {
                                    version: torchat_core::PROTOCOL_VERSION,
                                    message_id,
                                    sender: identity.installation_id(),
                                    recipient,
                                    ciphertext,
                                });
                                if let Err(error) = writer.send(Message::Text(
                                    match serde_json::to_string(&frame) {
                                        Ok(value) => value.into(),
                                        Err(error) => {
                                            let _ = event_tx.send(RelayEvent::Error(error.to_string()));
                                            continue;
                                        }
                                    }
                                )).await {
                                    break format!("relay send failed: {error}");
                                }
                            }
                            Some(RelayCommand::RefreshPairingCode) => {
                                match transport.refresh_pairing_code(&token).await {
                                    Ok(code) => { let _ = event_tx.send(RelayEvent::PairingCode(code)); }
                                    Err(error) => { let _ = event_tx.send(RelayEvent::Error(format!("pairing code refresh failed: {error:#}"))); }
                                }
                            }
                            Some(RelayCommand::SubmitPairingCode(code)) => {
                                match transport.create_pairing_request(&token, &code).await {
                                    Ok(value) => { let _ = event_tx.send(RelayEvent::PairingRequestCreated { pairing_id: value.pairing_id, expires_at: value.expires_at, state: value.state }); }
                                    Err(error) => { let _ = event_tx.send(RelayEvent::Error(format!("pairing request failed: {error:#}"))); }
                                }
                            }
                            Some(RelayCommand::CancelPairing(pairing_id)) => {
                                match transport.cancel_pairing(&token, pairing_id).await {
                                    Ok(()) => { let _ = event_tx.send(RelayEvent::PairingCancelled(pairing_id)); }
                                    Err(error) => { let _ = event_tx.send(RelayEvent::Error(format!("pairing cancellation failed: {error:#}"))); }
                                }
                            }
                            Some(RelayCommand::PairingInbox) => {
                                match transport.pairing_inbox(&token).await {
                                    Ok(items) => { let _ = event_tx.send(RelayEvent::PairingInbox(items)); }
                                    Err(error) => { let _ = event_tx.send(RelayEvent::Error(format!("pairing inbox failed: {error:#}"))); }
                                }
                            }
                            Some(RelayCommand::AcknowledgePairing(pairing_id)) => {
                                match transport.acknowledge_pairing(&token, pairing_id).await {
                                    Ok(()) => { let _ = event_tx.send(RelayEvent::PairingAcknowledged); }
                                    Err(error) => { let _ = event_tx.send(RelayEvent::Error(format!("pairing acknowledgement failed: {error:#}"))); }
                                }
                            }
                            Some(RelayCommand::ConfirmContact { capability, peer }) => {
                                match transport.confirm_contact(&token, &capability, &peer).await {
                                    Ok(()) => { let _ = event_tx.send(RelayEvent::ContactConfirmed); }
                                    Err(error) => { let _ = event_tx.send(RelayEvent::Error(format!("contact confirmation failed: {error:#}"))); }
                                }
                            }
                            Some(RelayCommand::Shutdown) | None => return,
                        }
                    }
                    message = reader.next() => {
                        let message = match message {
                            Some(Ok(message)) => message,
                            Some(Err(error)) => break format!("relay receive failed: {error}"),
                            None => break "relay closed".into(),
                        };
                        match message {
                            Message::Text(text) => match serde_json::from_str::<ServerFrame>(&text) {
                                Ok(ServerFrame::Envelope(envelope)) => {
                                    let _ = event_tx.send(RelayEvent::Envelope(envelope));
                                }
                                Ok(ServerFrame::Forwarded { message_id }) => {
                                    let _ = event_tx.send(RelayEvent::MessageTransportOutcome {
                                        message_id,
                                        outcome: MessageTransportOutcome::Forwarded,
                                    });
                                }
                                Ok(ServerFrame::DeliveryReceipt { message_id }) => {
                                    let _ = event_tx.send(RelayEvent::MessageTransportOutcome {
                                        message_id,
                                        outcome: MessageTransportOutcome::Delivered,
                                    });
                                }
                                Ok(ServerFrame::RecipientOffline { message_id }) => {
                                    let _ = event_tx.send(RelayEvent::MessageTransportOutcome {
                                        message_id,
                                        outcome: MessageTransportOutcome::RecipientOffline,
                                    });
                                }
                                Ok(ServerFrame::Error { code }) => {
                                    let _ = event_tx.send(RelayEvent::Error(format!("relay: {code}")));
                                }
                                Ok(_) => {}
                                Err(error) => {
                                    let _ = event_tx.send(RelayEvent::Error(format!("invalid relay frame: {error}")));
                                }
                            },
                            Message::Ping(payload) => {
                                if let Err(error) = writer.send(Message::Pong(payload)).await {
                                    break format!("relay pong failed: {error}");
                                }
                            }
                            Message::Pong(_) => {
                                last_pong_at = Instant::now();
                            }
                            Message::Close(_) => break "relay closed".into(),
                            _ => {}
                        }
                    }
                }
            };
            let reconnect_label = disconnected.clone();
            let _ = event_tx.send(RelayEvent::Status {
                phase: "reconnecting".into(),
                label: reconnect_label,
                progress: 70,
                latency_ms: None,
            });
            let code = classify_relay_error(&disconnected);
            eprintln!(
                "[TorChat-Relay] phase=reconnecting retryAttempt=0 code={code:?} detail={disconnected}"
            );
        }
    });
    (command_tx, event_rx)
}

#[cfg(test)]
mod tests {
    use super::*;

    const ONION: &str = "36xcrek7ncoujoz72g4icexl45b4atzbk5gjhqrnb6thngmgcbci4cqd.onion";

    #[test]
    fn transport_requires_exact_onion_and_tor_proxy() {
        assert!(
            ApiTransport::new(&format!("http://{ONION}"), Some("socks5h://127.0.0.1:9050")).is_ok()
        );
        assert!(
            ApiTransport::new("http://127.0.0.1:8080", Some("socks5h://127.0.0.1:9050")).is_err()
        );
        assert!(
            ApiTransport::new(
                &format!("http://{ONION}/other"),
                Some("socks5h://127.0.0.1:9050")
            )
            .is_err()
        );
        assert!(ApiTransport::new(&format!("http://{ONION}"), None).is_err());
    }
}
