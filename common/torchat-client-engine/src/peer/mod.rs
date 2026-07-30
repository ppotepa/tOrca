use std::{
    collections::HashMap,
    net::{IpAddr, Ipv4Addr, SocketAddr},
    pin::Pin,
    sync::{Arc, RwLock},
    task::{Context, Poll},
    time::Duration,
};

use futures_util::{SinkExt, StreamExt};
use tokio::{
    io::{AsyncRead, AsyncWrite, ReadBuf},
    net::{TcpListener, TcpStream},
    sync::{Semaphore, mpsc, oneshot},
    time::timeout,
};
use tokio_socks::tcp::Socks5Stream;
use tokio_tungstenite::{
    WebSocketStream, accept_hdr_async, client_async,
    tungstenite::{
        Message,
        handshake::server::{Request as ServerRequest, Response as ServerResponse},
        http::Request,
    },
};
use torchat_client_runtime::PeerConnectionStatus;
use torchat_core::{
    Identity, PROTOCOL_VERSION,
    peer_protocol::{
        PEER_PATH, PeerAck, PeerAckKind, PeerClientHello, PeerClientProof, PeerEndpointBundle,
        PeerEndpointUpdate, PeerFrame, PeerMessageEnvelope, PeerServerChallenge, decode_frame,
        encode_frame, handshake_transcript,
    },
    verify_signature,
};
use uuid::Uuid;

use crate::{EngineError, EngineResult};

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);
const ACK_TIMEOUT: Duration = Duration::from_secs(60);
const OUTBOUND_CAPACITY: usize = 64;
const EVENT_CAPACITY: usize = 64;

#[derive(Clone, Debug)]
pub enum PeerDeliveryTag {
    Message { message_id: String },
    Receipt { message_id: String },
    Ephemeral,
    EndpointUpdate,
}

#[derive(Clone, Debug)]
pub struct PeerOutboundCommand {
    pub endpoint: PeerEndpointBundle,
    pub peer_public_key: String,
    pub local_endpoint: PeerEndpointBundle,
    pub endpoint_updates: Vec<PeerEndpointUpdate>,
    pub message_id: Uuid,
    pub conversation_id: String,
    pub sequence: u64,
    pub created_at: i64,
    pub ciphertext: Vec<u8>,
    pub delivery: PeerDeliveryTag,
    pub socks5_url: String,
}

pub enum PeerTransportEvent {
    InboundMessage {
        envelope: PeerMessageEnvelope,
        persisted: oneshot::Sender<Result<PeerAck, String>>,
        delivered: oneshot::Sender<Result<PeerAck, String>>,
    },
    Ack {
        delivery: PeerDeliveryTag,
        kind: PeerAckKind,
        contact_installation_id: String,
        endpoint_sequence: Option<u64>,
    },
    EndpointUpdated {
        endpoint: PeerEndpointBundle,
    },
    ConnectionChanged {
        installation_id: String,
        status: PeerConnectionStatus,
        error: Option<String>,
        delivery: Option<PeerDeliveryTag>,
    },
}

#[derive(Clone)]
struct AuthorizedPeer {
    public_key: String,
    endpoint: PeerEndpointBundle,
}

#[derive(Default)]
struct SharedPeerState {
    local_endpoint: RwLock<Option<PeerEndpointBundle>>,
    authorized: RwLock<HashMap<String, AuthorizedPeer>>,
}

#[derive(Clone)]
pub struct PeerTransportHandle {
    local_port: u16,
    state: Arc<SharedPeerState>,
    identity_private_key: [u8; 32],
    outbound: mpsc::Sender<PeerOutboundCommand>,
}

impl PeerTransportHandle {
    pub async fn bind(
        identity_private_key: [u8; 32],
    ) -> EngineResult<(Self, mpsc::Receiver<PeerTransportEvent>)> {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
            .await
            .map_err(|error| EngineError::Transport(format!("bind peer listener: {error}")))?;
        let local_port = listener
            .local_addr()
            .map_err(|error| EngineError::Transport(format!("read peer listener port: {error}")))?
            .port();
        let state = Arc::new(SharedPeerState::default());
        let (event_tx, event_rx) = mpsc::channel(EVENT_CAPACITY);
        let (outbound_tx, mut outbound_rx) =
            mpsc::channel::<PeerOutboundCommand>(OUTBOUND_CAPACITY);

        let ingress_state = state.clone();
        let ingress_events = event_tx.clone();
        let ingress_limit = Arc::new(Semaphore::new(32));
        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    break;
                };
                let Ok(_permit) = ingress_limit.clone().try_acquire_owned() else {
                    drop(stream);
                    continue;
                };
                let state = ingress_state.clone();
                let events = ingress_events.clone();
                tokio::spawn(async move {
                    let _permit = _permit;
                    let _ = serve_inbound(stream, identity_private_key, state, events).await;
                });
            }
        });

        tokio::spawn(async move {
            let mut peer_limits = HashMap::<String, Arc<Semaphore>>::new();
            while let Some(command) = outbound_rx.recv().await {
                let events = event_tx.clone();
                let installation_id = command.endpoint.installation_id.clone();
                let limit = peer_limits
                    .entry(installation_id.clone())
                    .or_insert_with(|| Arc::new(Semaphore::new(2)))
                    .clone();
                tokio::spawn(async move {
                    let Ok(_permit) = limit.acquire_owned().await else {
                        return;
                    };
                    let result =
                        send_outbound(identity_private_key, command.clone(), events.clone()).await;
                    if let Err(error) = result {
                        let _ = events
                            .send(PeerTransportEvent::ConnectionChanged {
                                installation_id,
                                status: PeerConnectionStatus::Backoff,
                                error: Some(error),
                                delivery: Some(command.delivery.clone()),
                            })
                            .await;
                    }
                });
            }
        });

        Ok((
            Self {
                local_port,
                state,
                identity_private_key,
                outbound: outbound_tx,
            },
            event_rx,
        ))
    }

    pub fn local_port(&self) -> u16 {
        self.local_port
    }

    pub fn set_local_endpoint(&self, endpoint: PeerEndpointBundle) {
        if let Ok(mut value) = self.state.local_endpoint.write() {
            *value = Some(endpoint);
        }
    }

    pub fn authorize_contact(&self, endpoint: &PeerEndpointBundle) {
        if let Ok(mut authorized) = self.state.authorized.write() {
            authorized.insert(
                endpoint.installation_id.clone(),
                AuthorizedPeer {
                    public_key: endpoint.identity_public_key.clone(),
                    endpoint: endpoint.clone(),
                },
            );
        }
    }

    pub async fn send(&self, command: PeerOutboundCommand) -> EngineResult<()> {
        self.outbound
            .send(command)
            .await
            .map_err(|_| EngineError::Transport("peer outbound queue is closed".to_owned()))
    }

    pub fn try_send(&self, command: PeerOutboundCommand) -> EngineResult<()> {
        self.outbound.try_send(command).map_err(|error| {
            EngineError::Transport(format!("peer outbound queue is unavailable: {error}"))
        })
    }

    pub fn identity_private_key(&self) -> [u8; 32] {
        self.identity_private_key
    }
}

async fn serve_inbound(
    stream: TcpStream,
    identity_private_key: [u8; 32],
    state: Arc<SharedPeerState>,
    events: mpsc::Sender<PeerTransportEvent>,
) -> Result<(), String> {
    let websocket = timeout(
        HANDSHAKE_TIMEOUT,
        accept_hdr_async(
            stream,
            |request: &ServerRequest, response: ServerResponse| {
                if request.uri().path() != PEER_PATH {
                    return Err(
                        tokio_tungstenite::tungstenite::handshake::server::ErrorResponse::new(
                            Some("not found".to_owned()),
                        ),
                    );
                }
                Ok(response)
            },
        ),
    )
    .await
    .map_err(|_| "peer websocket handshake timed out".to_owned())?
    .map_err(|error| format!("accept peer websocket: {error}"))?;
    let identity = Identity::from_private_key_bytes(identity_private_key);
    let local_endpoint = state
        .local_endpoint
        .read()
        .map_err(|_| "peer endpoint lock poisoned".to_owned())?
        .clone()
        .ok_or_else(|| "local onion endpoint is unavailable".to_owned())?;

    let (mut websocket, peer_id, peer_key, mut peer_endpoint, session_id) =
        authenticate_inbound(websocket, &identity, &local_endpoint, &state).await?;
    let _ = events
        .send(PeerTransportEvent::ConnectionChanged {
            installation_id: peer_id.clone(),
            status: PeerConnectionStatus::Connected,
            error: None,
            delivery: None,
        })
        .await;

    while let Some(message) = websocket.next().await {
        let message = message.map_err(|error| format!("read peer frame: {error}"))?;
        let frame = message_bytes(message)?;
        match decode_frame(&frame, true)? {
            PeerFrame::Message { envelope } => {
                if envelope.session_id != session_id {
                    return Err("peer message session mismatch".into());
                }
                envelope.verify(&peer_id, &peer_key)?;
                let received = PeerAck {
                    session_id,
                    message_id: envelope.message_id,
                    kind: PeerAckKind::Received,
                    ciphertext_hash: envelope.ciphertext_hash(),
                };
                send_frame(&mut websocket, PeerFrame::Ack { ack: received }).await?;

                let (persisted_tx, persisted_rx) = oneshot::channel();
                let (delivered_tx, delivered_rx) = oneshot::channel();
                events
                    .send(PeerTransportEvent::InboundMessage {
                        envelope,
                        persisted: persisted_tx,
                        delivered: delivered_tx,
                    })
                    .await
                    .map_err(|_| "engine peer event queue is closed".to_owned())?;
                let persisted = timeout(ACK_TIMEOUT, persisted_rx)
                    .await
                    .map_err(|_| "engine persistence acknowledgement timed out".to_owned())?
                    .map_err(|_| "engine dropped persistence acknowledgement".to_owned())??;
                send_frame(&mut websocket, PeerFrame::Ack { ack: persisted }).await?;
                if let Ok(Ok(Ok(delivered))) = timeout(ACK_TIMEOUT, delivered_rx).await {
                    send_frame(&mut websocket, PeerFrame::Ack { ack: delivered }).await?;
                }
            }
            PeerFrame::EndpointUpdate { update } => {
                update.validate(&peer_endpoint, unix_secs())?;
                if update.endpoint.installation_id != peer_id
                    || update.endpoint.identity_public_key != peer_key
                {
                    return Err("peer endpoint update changed authenticated identity".into());
                }
                peer_endpoint = update.endpoint.clone();
                if let Ok(mut authorized) = state.authorized.write() {
                    authorized.insert(
                        peer_id.clone(),
                        AuthorizedPeer {
                            public_key: peer_key.clone(),
                            endpoint: peer_endpoint.clone(),
                        },
                    );
                }
                events
                    .send(PeerTransportEvent::EndpointUpdated {
                        endpoint: peer_endpoint.clone(),
                    })
                    .await
                    .map_err(|_| "engine peer event queue is closed".to_owned())?;
            }
            PeerFrame::Ping { nonce } => {
                send_frame(&mut websocket, PeerFrame::Pong { nonce }).await?;
            }
            PeerFrame::Pong { .. } | PeerFrame::Ack { .. } => {}
            _ => return Err("unexpected authenticated peer frame".into()),
        }
    }
    let _ = events
        .send(PeerTransportEvent::ConnectionChanged {
            installation_id: peer_id,
            status: PeerConnectionStatus::Offline,
            error: None,
            delivery: None,
        })
        .await;
    Ok(())
}

async fn authenticate_inbound(
    mut websocket: WebSocketStream<TcpStream>,
    identity: &Identity,
    local_endpoint: &PeerEndpointBundle,
    state: &SharedPeerState,
) -> Result<
    (
        WebSocketStream<TcpStream>,
        String,
        String,
        PeerEndpointBundle,
        Uuid,
    ),
    String,
> {
    let frame = recv_frame(&mut websocket, false).await?;
    let PeerFrame::ClientHello { hello } = frame else {
        return Err("expected peer client hello".into());
    };
    if hello.protocol_version != PROTOCOL_VERSION {
        return Err("unsupported peer protocol".into());
    }
    let authorized = state
        .authorized
        .read()
        .map_err(|_| "authorized peer lock poisoned".to_owned())?
        .get(&hello.installation_id)
        .cloned()
        .ok_or_else(|| "peer is not an authorized contact".to_owned())?;
    if hello.endpoint_sequence < authorized.endpoint.sequence {
        return Err("peer endpoint sequence is stale".into());
    }

    let server_nonce = random_nonce();
    let session_id = Uuid::new_v4();
    let transcript = handshake_transcript(
        &hello,
        &identity.installation_id(),
        local_endpoint.sequence,
        &server_nonce,
        session_id,
        &local_endpoint.onion_address,
    );
    let challenge = PeerServerChallenge {
        protocol_version: PROTOCOL_VERSION,
        installation_id: identity.installation_id(),
        endpoint_sequence: local_endpoint.sequence,
        nonce: server_nonce,
        session_id,
        signature: identity.sign(&transcript),
    };
    send_frame(&mut websocket, PeerFrame::ServerChallenge { challenge }).await?;
    let PeerFrame::ClientProof { proof } = recv_frame(&mut websocket, false).await? else {
        return Err("expected peer client proof".into());
    };
    if proof.session_id != session_id
        || !verify_signature(&authorized.public_key, &transcript, &proof.signature)
    {
        return Err("peer client proof is invalid".into());
    }
    send_frame(&mut websocket, PeerFrame::HandshakeAccepted { session_id }).await?;
    Ok((
        websocket,
        hello.installation_id,
        authorized.public_key,
        authorized.endpoint,
        session_id,
    ))
}

async fn send_outbound(
    identity_private_key: [u8; 32],
    command: PeerOutboundCommand,
    events: mpsc::Sender<PeerTransportEvent>,
) -> Result<(), String> {
    let identity = Identity::from_private_key_bytes(identity_private_key);
    let _ = events
        .send(PeerTransportEvent::ConnectionChanged {
            installation_id: command.endpoint.installation_id.clone(),
            status: PeerConnectionStatus::Connecting,
            error: None,
            delivery: Some(command.delivery.clone()),
        })
        .await;
    let proxy = parse_socks_addr(&command.socks5_url)?;
    let socket = timeout(HANDSHAKE_TIMEOUT, TcpStream::connect(proxy))
        .await
        .map_err(|_| "connect to Tor SOCKS timed out".to_owned())?
        .map_err(|error| format!("connect to Tor SOCKS: {error}"))?;
    let socks = timeout(
        HANDSHAKE_TIMEOUT,
        Socks5Stream::connect_with_socket(
            socket,
            (
                command.endpoint.onion_address.as_str(),
                command.endpoint.virtual_port,
            ),
        ),
    )
    .await
    .map_err(|_| "connect to peer onion timed out".to_owned())?
    .map_err(|error| format!("connect to peer onion: {error}"))?;
    let request = Request::builder()
        .method("GET")
        .uri(format!(
            "ws://{}:{}{}",
            command.endpoint.onion_address, command.endpoint.virtual_port, PEER_PATH
        ))
        .header("Host", command.endpoint.onion_address.as_str())
        .header("Connection", "Upgrade")
        .header("Upgrade", "websocket")
        .header("Sec-WebSocket-Version", "13")
        .header(
            "Sec-WebSocket-Key",
            tokio_tungstenite::tungstenite::handshake::client::generate_key(),
        )
        .body(())
        .map_err(|error| format!("build peer websocket request: {error}"))?;
    let (mut websocket, _) = timeout(HANDSHAKE_TIMEOUT, client_async(request, PeerSocket(socks)))
        .await
        .map_err(|_| "peer websocket handshake timed out".to_owned())?
        .map_err(|error| format!("connect peer websocket: {error}"))?;
    let _ = events
        .send(PeerTransportEvent::ConnectionChanged {
            installation_id: command.endpoint.installation_id.clone(),
            status: PeerConnectionStatus::Authenticating,
            error: None,
            delivery: Some(command.delivery.clone()),
        })
        .await;

    let nonce = random_nonce();
    let hello = PeerClientHello {
        protocol_version: PROTOCOL_VERSION,
        installation_id: identity.installation_id(),
        endpoint_sequence: command.local_endpoint.sequence,
        nonce,
    };
    send_frame(
        &mut websocket,
        PeerFrame::ClientHello {
            hello: hello.clone(),
        },
    )
    .await?;
    let PeerFrame::ServerChallenge { challenge } = recv_frame(&mut websocket, false).await? else {
        return Err("expected peer server challenge".into());
    };
    if challenge.installation_id != command.endpoint.installation_id
        || challenge.endpoint_sequence != command.endpoint.sequence
    {
        return Err("peer server identity or endpoint sequence mismatch".into());
    }
    let transcript = handshake_transcript(
        &hello,
        &challenge.installation_id,
        challenge.endpoint_sequence,
        &challenge.nonce,
        challenge.session_id,
        &command.endpoint.onion_address,
    );
    if !verify_signature(&command.peer_public_key, &transcript, &challenge.signature) {
        return Err("peer server challenge signature is invalid".into());
    }
    send_frame(
        &mut websocket,
        PeerFrame::ClientProof {
            proof: PeerClientProof {
                session_id: challenge.session_id,
                signature: identity.sign(&transcript),
            },
        },
    )
    .await?;
    let PeerFrame::HandshakeAccepted { session_id } = recv_frame(&mut websocket, false).await?
    else {
        return Err("expected peer handshake acceptance".into());
    };
    if session_id != challenge.session_id {
        return Err("peer handshake session mismatch".into());
    }
    let _ = events
        .send(PeerTransportEvent::ConnectionChanged {
            installation_id: command.endpoint.installation_id.clone(),
            status: PeerConnectionStatus::Connected,
            error: None,
            delivery: None,
        })
        .await;
    for update in &command.endpoint_updates {
        send_frame(
            &mut websocket,
            PeerFrame::EndpointUpdate {
                update: update.clone(),
            },
        )
        .await?;
    }
    if matches!(command.delivery, PeerDeliveryTag::EndpointUpdate) {
        let nonce = command.sequence;
        send_frame(&mut websocket, PeerFrame::Ping { nonce }).await?;
        loop {
            match timeout(ACK_TIMEOUT, recv_frame(&mut websocket, true))
                .await
                .map_err(|_| "peer endpoint update acknowledgement timed out".to_owned())??
            {
                PeerFrame::Pong { nonce: value } if value == nonce => {
                    let _ = events
                        .send(PeerTransportEvent::Ack {
                            delivery: PeerDeliveryTag::EndpointUpdate,
                            kind: PeerAckKind::Persisted,
                            contact_installation_id: command.endpoint.installation_id.clone(),
                            endpoint_sequence: command
                                .endpoint_updates
                                .last()
                                .map(|update| update.endpoint.sequence),
                        })
                        .await;
                    return Ok(());
                }
                _ => continue,
            }
        }
    }
    let envelope = PeerMessageEnvelope::new(
        &identity,
        session_id,
        command.message_id,
        command.conversation_id,
        command.sequence,
        command.created_at,
        command.ciphertext,
    );
    let expected_ciphertext_hash = envelope.ciphertext_hash();
    send_frame(&mut websocket, PeerFrame::Message { envelope }).await?;

    loop {
        let frame = timeout(ACK_TIMEOUT, recv_frame(&mut websocket, true))
            .await
            .map_err(|_| "peer acknowledgement timed out".to_owned())??;
        let PeerFrame::Ack { ack } = frame else {
            continue;
        };
        if ack.session_id != session_id || ack.message_id != command.message_id {
            continue;
        }
        if ack.ciphertext_hash != expected_ciphertext_hash {
            return Err("peer acknowledgement ciphertext hash mismatch".to_owned());
        }
        let kind = ack.kind;
        let _ = events
            .send(PeerTransportEvent::Ack {
                delivery: command.delivery.clone(),
                kind,
                contact_installation_id: command.endpoint.installation_id.clone(),
                endpoint_sequence: command
                    .endpoint_updates
                    .last()
                    .map(|update| update.endpoint.sequence),
            })
            .await;
        if matches!(kind, PeerAckKind::Persisted | PeerAckKind::Delivered) {
            break;
        }
    }
    Ok(())
}

async fn recv_frame<S>(
    websocket: &mut WebSocketStream<S>,
    authenticated: bool,
) -> Result<PeerFrame, String>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let message = timeout(HANDSHAKE_TIMEOUT, websocket.next())
        .await
        .map_err(|_| "peer frame timed out".to_owned())?
        .ok_or_else(|| "peer websocket closed".to_owned())?
        .map_err(|error| format!("read peer websocket: {error}"))?;
    decode_frame(&message_bytes(message)?, authenticated)
}

async fn send_frame<S>(websocket: &mut WebSocketStream<S>, frame: PeerFrame) -> Result<(), String>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    websocket
        .send(Message::Binary(encode_frame(&frame)?.into()))
        .await
        .map_err(|error| format!("write peer websocket: {error}"))
}

fn message_bytes(message: Message) -> Result<Vec<u8>, String> {
    match message {
        Message::Binary(value) => Ok(value.to_vec()),
        Message::Close(_) => Err("peer websocket closed".into()),
        _ => Err("peer protocol requires binary websocket frames".into()),
    }
}

fn random_nonce() -> [u8; 32] {
    let mut nonce = [0_u8; 32];
    nonce[..16].copy_from_slice(Uuid::new_v4().as_bytes());
    nonce[16..].copy_from_slice(Uuid::new_v4().as_bytes());
    nonce
}

fn unix_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system clock must be after Unix epoch")
        .as_secs() as i64
}

fn parse_socks_addr(value: &str) -> Result<SocketAddr, String> {
    let url = url::Url::parse(value).map_err(|error| format!("parse SOCKS URL: {error}"))?;
    let host = url
        .host_str()
        .ok_or_else(|| "SOCKS URL is missing host".to_owned())?;
    let ip: IpAddr = host
        .parse()
        .map_err(|_| "SOCKS URL must use a local IP address".to_owned())?;
    if !ip.is_loopback() {
        return Err("SOCKS endpoint must be loopback".into());
    }
    Ok(SocketAddr::new(
        ip,
        url.port()
            .ok_or_else(|| "SOCKS URL is missing port".to_owned())?,
    ))
}

struct PeerSocket(Socks5Stream<TcpStream>);

impl AsyncRead for PeerSocket {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.0).poll_read(cx, buf)
    }
}

impl AsyncWrite for PeerSocket {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        Pin::new(&mut self.0).poll_write(cx, buf)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.0).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.0).poll_shutdown(cx)
    }
}
