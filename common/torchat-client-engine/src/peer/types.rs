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
    ReadReceipt { receipt_id: String },
    RelationshipRemovalAck { removal_id: String },
    Ephemeral,
    Probe,
    EndpointUpdate,
    Presence { online: bool },
    Typing { typing: bool },
    ConversationFocus { focused: bool },
}

impl PeerDeliveryTag {
    pub(super) fn dedupe_key(&self) -> Option<String> {
        match self {
            Self::Message { message_id } => Some(format!("message:{message_id}")),
            Self::Receipt { message_id } => Some(format!("receipt:{message_id}")),
            Self::ReadReceipt { receipt_id } => Some(format!("read-receipt:{receipt_id}")),
            Self::RelationshipRemovalAck { removal_id } => {
                Some(format!("relationship-removal-ack:{removal_id}"))
            }
            Self::Ephemeral
            | Self::Probe
            | Self::EndpointUpdate
            | Self::Presence { .. }
            | Self::Typing { .. }
            | Self::ConversationFocus { .. } => None,
        }
    }

    pub(super) fn is_durable(&self) -> bool {
        matches!(
            self,
            Self::Message { .. }
                | Self::Receipt { .. }
                | Self::ReadReceipt { .. }
                | Self::EndpointUpdate
        )
    }
}

#[derive(Clone, Debug)]
pub struct PeerOutboundCommand {
    pub endpoint: PeerEndpointBundle,
    pub capability_id: String,
    pub capability_secret: Vec<u8>,
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
    PresenceChanged {
        installation_id: String,
        online: bool,
        idle: bool,
        observed_at: i64,
        expires_at: i64,
    },
    TypingChanged {
        installation_id: String,
        typing: bool,
        expires_at: i64,
    },
    ConversationFocusChanged {
        installation_id: String,
        focused: bool,
        expires_at: i64,
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
    /// Exact local endpoint bundle advertised to this contact.
    pub(super) local_endpoint: PeerEndpointBundle,
    /// Capability issued locally to this peer. Inbound handshakes must
    /// present this identifier and prove possession of this secret.
    pub(super) inbound_capability_id: String,
    pub(super) capability_secret: Vec<u8>,
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
