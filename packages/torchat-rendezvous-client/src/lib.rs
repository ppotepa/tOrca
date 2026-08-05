use std::{
    pin::Pin,
    task::{Context, Poll},
};

use futures_util::{SinkExt, StreamExt};
use tokio::{
    io::{AsyncRead, AsyncWrite, ReadBuf},
    net::TcpStream,
};
use tokio_socks::tcp::Socks5Stream;
use tokio_tungstenite::{WebSocketStream, client_async, tungstenite::Message};
use torchat_relay_protocol::{RendezvousClientFrame, RendezvousServerFrame};
use url::Url;
use uuid::Uuid;

enum Socket {
    Direct(TcpStream),
    Socks(Socks5Stream<TcpStream>),
}
impl AsyncRead for Socket {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        b: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        match &mut *self {
            Self::Direct(s) => Pin::new(s).poll_read(cx, b),
            Self::Socks(s) => Pin::new(s).poll_read(cx, b),
        }
    }
}
impl AsyncWrite for Socket {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        b: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        match &mut *self {
            Self::Direct(s) => Pin::new(s).poll_write(cx, b),
            Self::Socks(s) => Pin::new(s).poll_write(cx, b),
        }
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        match &mut *self {
            Self::Direct(s) => Pin::new(s).poll_flush(cx),
            Self::Socks(s) => Pin::new(s).poll_flush(cx),
        }
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        match &mut *self {
            Self::Direct(s) => Pin::new(s).poll_shutdown(cx),
            Self::Socks(s) => Pin::new(s).poll_shutdown(cx),
        }
    }
}

type Stream = WebSocketStream<Socket>;

#[derive(Clone, Debug)]
pub struct PairingSlot {
    pub request_id: Uuid,
    pub slot_handle: String,
    pub display_code: String,
    pub slot_capability: String,
    pub expires_at_unix: i64,
}
#[derive(Clone, Debug)]
pub struct ResolvedSlot {
    pub request_id: Uuid,
    pub slot_handle: String,
    pub owner_rendezvous_public_key: [u8; 32],
    pub expires_at_unix: i64,
}
#[derive(Clone, Debug)]
pub struct PairingStarted {
    pub request_id: Uuid,
    pub pairing_id: Uuid,
    pub joiner_side_token: String,
    pub expires_at_unix: i64,
}

pub struct PairingRendezvousClient {
    stream: Stream,
}

impl PairingRendezvousClient {
    pub async fn connect(relay_url: Url, socks5_url: Option<&str>) -> Result<Self, String> {
        let mut relay_url = relay_url;
        if relay_url.scheme() == "http" {
            relay_url
                .set_scheme("ws")
                .map_err(|_| "invalid relay URL")?;
        }
        if relay_url.scheme() == "https" {
            relay_url
                .set_scheme("wss")
                .map_err(|_| "invalid relay URL")?;
        }
        if relay_url.path() == "/" || relay_url.path().is_empty() {
            relay_url.set_path("/rendezvous");
        }
        let host = relay_url
            .host_str()
            .ok_or("relay URL has no host")?
            .to_owned();
        let port = relay_url
            .port_or_known_default()
            .ok_or("relay URL has no port")?;
        let socket = if let Some(proxy) = socks5_url {
            let proxy = proxy
                .strip_prefix("socks5h://")
                .or_else(|| proxy.strip_prefix("socks5://"))
                .unwrap_or(proxy);
            Socket::Socks(
                Socks5Stream::connect(proxy, (host.as_str(), port))
                    .await
                    .map_err(|e| e.to_string())?,
            )
        } else {
            Socket::Direct(
                TcpStream::connect((host.as_str(), port))
                    .await
                    .map_err(|e| e.to_string())?,
            )
        };
        let (stream, _) = client_async(relay_url.as_str(), socket)
            .await
            .map_err(|e| e.to_string())?;
        Ok(Self { stream })
    }

    pub async fn send(&mut self, frame: RendezvousClientFrame) -> Result<(), String> {
        let bytes = serde_json::to_vec(&frame).map_err(|e| e.to_string())?;
        self.stream
            .send(Message::Binary(bytes.into()))
            .await
            .map_err(|e| e.to_string())
    }

    pub async fn next(&mut self) -> Result<RendezvousServerFrame, String> {
        while let Some(message) = self.stream.next().await {
            match message.map_err(|e| e.to_string())? {
                Message::Binary(bytes) => {
                    return serde_json::from_slice(&bytes).map_err(|e| e.to_string());
                }
                Message::Text(text) => {
                    return serde_json::from_str(&text).map_err(|e| e.to_string());
                }
                Message::Ping(payload) => {
                    self.stream
                        .send(Message::Pong(payload))
                        .await
                        .map_err(|e| e.to_string())?;
                }
                Message::Close(_) => return Err("rendezvous connection closed".to_owned()),
                _ => {}
            }
        }
        Err("rendezvous connection closed".to_owned())
    }

    pub async fn create_slot(
        &mut self,
        rendezvous_public_key: [u8; 32],
        ttl_seconds: u16,
    ) -> Result<PairingSlot, String> {
        let request_id = Uuid::new_v4();
        self.send(RendezvousClientFrame::CreatePairingSlot {
            request_id,
            rendezvous_public_key,
            requested_ttl_seconds: ttl_seconds,
        })
        .await?;
        match self.next().await? {
            RendezvousServerFrame::PairingSlotCreated {
                request_id: received,
                slot_handle,
                display_code,
                slot_capability,
                expires_at_unix,
            } if received == request_id => Ok(PairingSlot {
                request_id,
                slot_handle,
                display_code,
                slot_capability,
                expires_at_unix,
            }),
            RendezvousServerFrame::Error { code, .. } => Err(code),
            _ => Err("unexpected rendezvous response".to_owned()),
        }
    }

    pub async fn resolve_code(&mut self, display_code: String) -> Result<ResolvedSlot, String> {
        let request_id = Uuid::new_v4();
        self.send(RendezvousClientFrame::ResolvePairingCode {
            request_id,
            display_code,
        })
        .await?;
        match self.next().await? {
            RendezvousServerFrame::PairingSlotResolved {
                request_id: received,
                slot_handle,
                owner_rendezvous_public_key,
                expires_at_unix,
            } if received == request_id => Ok(ResolvedSlot {
                request_id,
                slot_handle,
                owner_rendezvous_public_key,
                expires_at_unix,
            }),
            RendezvousServerFrame::Error { code, .. } => Err(code),
            _ => Err("unexpected rendezvous response".to_owned()),
        }
    }

    pub async fn begin_pairing(
        &mut self,
        pairing_id: Uuid,
        slot_handle: String,
        joiner_rendezvous_public_key: [u8; 32],
        encrypted_offer: Vec<u8>,
    ) -> Result<PairingStarted, String> {
        let request_id = Uuid::new_v4();
        self.send(RendezvousClientFrame::BeginPairing {
            request_id,
            pairing_id,
            slot_handle,
            joiner_rendezvous_public_key,
            encrypted_offer,
        })
        .await?;
        match self.next().await? {
            RendezvousServerFrame::PairingStarted {
                request_id: received,
                pairing_id,
                joiner_side_token,
                expires_at_unix,
            } if received == request_id => Ok(PairingStarted {
                request_id,
                pairing_id,
                joiner_side_token,
                expires_at_unix,
            }),
            RendezvousServerFrame::Error { code, .. } => Err(code),
            _ => Err("unexpected rendezvous response".to_owned()),
        }
    }
}
