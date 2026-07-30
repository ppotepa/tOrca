use std::net::{IpAddr, SocketAddr};

use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::time::timeout;
use tokio_tungstenite::{WebSocketStream, tungstenite::Message};
use torchat_core::peer_protocol::{PeerEndpointBundle, PeerFrame, decode_frame, encode_frame};
use uuid::Uuid;

use super::{HANDSHAKE_TIMEOUT, types::PeerSocket};

pub(super) async fn recv_frame<S>(
    websocket: &mut WebSocketStream<S>,
    authenticated: bool,
) -> Result<PeerFrame, String>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let message = websocket
        .next()
        .await
        .ok_or_else(|| "peer websocket closed".to_owned())?
        .map_err(|error| format!("read peer websocket: {error}"))?;
    decode_message(message, authenticated)?
        .ok_or_else(|| "peer websocket closed".to_owned())
}

pub(super) async fn recv_frame_with_timeout<S>(
    websocket: &mut WebSocketStream<S>,
    authenticated: bool,
    wait: std::time::Duration,
    operation: &str,
) -> Result<PeerFrame, String>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    timeout(wait, recv_frame(websocket, authenticated))
        .await
        .map_err(|_| format!("{operation} timed out"))?
}

pub(super) async fn send_frame<S>(
    websocket: &mut WebSocketStream<S>,
    frame: PeerFrame,
) -> Result<(), String>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    websocket
        .send(Message::Binary(encode_frame(&frame)?.into()))
        .await
        .map_err(|error| format!("write peer websocket: {error}"))
}

pub(super) async fn close_sink<S>(
    sink: &mut futures_util::stream::SplitSink<WebSocketStream<S>, Message>,
) where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let _ = timeout(std::time::Duration::from_secs(5), sink.close()).await;
}

pub(super) fn decode_message(
    message: Message,
    authenticated: bool,
) -> Result<Option<PeerFrame>, String> {
    match message {
        Message::Binary(value) => decode_frame(&value, authenticated).map(Some),
        Message::Close(_) => Ok(None),
        Message::Ping(value) => Ok(Some(PeerFrame::Ping {
            nonce: websocket_control_nonce(&value),
        })),
        Message::Pong(value) => Ok(Some(PeerFrame::Pong {
            nonce: websocket_control_nonce(&value),
        })),
        _ => Err("peer protocol requires binary websocket frames".into()),
    }
}

fn websocket_control_nonce(value: &[u8]) -> u64 {
    let mut bytes = [0_u8; 8];
    let count = value.len().min(bytes.len());
    bytes[..count].copy_from_slice(&value[..count]);
    u64::from_le_bytes(bytes)
}

pub(super) fn random_nonce() -> [u8; 32] {
    let mut nonce = [0_u8; 32];
    nonce[..16].copy_from_slice(Uuid::new_v4().as_bytes());
    nonce[16..].copy_from_slice(Uuid::new_v4().as_bytes());
    nonce
}

pub(super) fn random_u64() -> u64 {
    Uuid::new_v4().as_u128() as u64
}

pub(super) fn unix_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system clock must be after Unix epoch")
        .as_secs() as i64
}

pub(super) fn parse_socks_addr(value: &str) -> Result<SocketAddr, String> {
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

pub(super) fn same_peer_endpoint(
    left: &PeerEndpointBundle,
    right: &PeerEndpointBundle,
) -> bool {
    left.installation_id == right.installation_id
        && left.identity_public_key == right.identity_public_key
        && left.onion_address == right.onion_address
        && left.virtual_port == right.virtual_port
        && left.sequence == right.sequence
}

pub(super) async fn connect_socket(
    socks5_url: &str,
    onion_address: &str,
    virtual_port: u16,
) -> Result<PeerSocket, String> {
    let proxy = parse_socks_addr(socks5_url)?;
    let socket = timeout(HANDSHAKE_TIMEOUT, tokio::net::TcpStream::connect(proxy))
        .await
        .map_err(|_| "connect to Tor SOCKS timed out".to_owned())?
        .map_err(|error| format!("connect to Tor SOCKS: {error}"))?;
    let socks = timeout(
        HANDSHAKE_TIMEOUT,
        tokio_socks::tcp::Socks5Stream::connect_with_socket(
            socket,
            (onion_address, virtual_port),
        ),
    )
    .await
    .map_err(|_| "connect to peer onion timed out".to_owned())?
    .map_err(|error| format!("connect to peer onion: {error}"))?;
    Ok(PeerSocket(socks))
}
