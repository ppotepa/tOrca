use std::{
    collections::HashMap,
    pin::Pin,
    sync::{Arc, RwLock},
    task::{Context, Poll},
};

use tokio::{
    io::{AsyncRead, AsyncWrite, ReadBuf},
    net::TcpStream,
    sync::{mpsc, oneshot},
};
use tokio_socks::tcp::Socks5Stream;
use torchat_client_runtime::PeerConnectionStatus;
use torchat_core::peer_protocol::{
    PeerAck, PeerAckKind, PeerEndpointBundle, PeerEndpointUpdate, PeerMessageEnvelope,
};
use uuid::Uuid;

#[derive(Clone, Debug)]
pub enum PeerDeliveryTag {
    Message { message_id: String },
    Receipt { message_id: String },
    Ephemeral,
    EndpointUpdate,
}

impl PeerDeliveryTag {
    pub(super) fn dedupe_key(&self) -> Option<String> {
        match self {
            Self::Message { message_id } => Some(format!("message:{message_id}")),
            Self::Receipt { message_id } => Some(format!("receipt:{message_id}")),
            Self::Ephemeral | Self::EndpointUpdate => None,
        }
    }

    pub(super) fn is_durable(&self) -> bool {
        matches!(
            self,
            Self::Message { .. } | Self::Receipt { .. } | Self::EndpointUpdate
        )
    }
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
    IngressError {
        error: String,
    },
    ConnectionChanged {
        installation_id: String,
        session_id: Option<Uuid>,
        status: PeerConnectionStatus,
        error: Option<String>,
        delivery: Option<PeerDeliveryTag>,
    },
}

pub(super) struct PeerSessionLease {
    pub(super) events: mpsc::Sender<PeerTransportEvent>,
    pub(super) installation_id: String,
    pub(super) session_id: Uuid,
}

impl Drop for PeerSessionLease {
    fn drop(&mut self) {
        let _ = self.events.try_send(PeerTransportEvent::ConnectionChanged {
            installation_id: self.installation_id.clone(),
            session_id: Some(self.session_id),
            status: PeerConnectionStatus::Offline,
            error: None,
            delivery: None,
        });
    }
}

#[derive(Clone)]
pub(super) struct AuthorizedPeer {
    pub(super) public_key: String,
    pub(super) endpoint: PeerEndpointBundle,
}

#[derive(Default)]
pub(super) struct SharedPeerState {
    pub(super) local_endpoint: RwLock<Option<PeerEndpointBundle>>,
    pub(super) authorized: RwLock<HashMap<String, AuthorizedPeer>>,
}

pub(super) type SharedState = Arc<SharedPeerState>;

pub(super) struct PeerSocket(pub(super) Socks5Stream<TcpStream>);

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
