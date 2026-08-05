pub mod peer;

pub use peer::{PeerDeliveryTag, PeerOutboundCommand, PeerTransportEvent, PeerTransportHandle};

#[derive(Debug, Clone, Eq, PartialEq)]
pub enum PeerError {
    Transport(String),
}

impl std::fmt::Display for PeerError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Transport(message) => formatter.write_str(message),
        }
    }
}

impl std::error::Error for PeerError {}
