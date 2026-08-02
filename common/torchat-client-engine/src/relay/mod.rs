pub mod actor;
pub mod connection;
pub mod error;
pub mod heartbeat;
pub mod writer;

use torchat_client_runtime::{
    InviteCode, MessageTransportOutcome, PairingItem, RuntimeError, RuntimeResult,
};
use torchat_core::relay::RelayEnvelope;

pub use actor::SharedRelayActor;
pub use connection::RelayConnectionConfig;
pub use error::RelayUnavailableReason;
pub use heartbeat::RelayHeartbeatConfig;
pub use writer::RelayWriterConfig;

#[derive(Clone, Debug)]
pub enum RelayEvent {
    Connected,
    PairingAvailable {
        pairing_id: uuid::Uuid,
    },
    Backoff {
        attempt: u32,
        retry_in_ms: u64,
        detail: String,
    },
    Disconnected {
        detail: String,
    },
    Envelope(RelayEnvelope),
    MessageTransportOutcome {
        message_id: uuid::Uuid,
        outcome: MessageTransportOutcome,
    },
}

pub trait EngineRelay: Send {
    fn set_socks5_url(&mut self, socks5_url: Option<String>);
    fn shutdown(&mut self);
    fn ensure_session(&mut self) -> RuntimeResult<()>;
    fn update_profile(&mut self, nickname: &str) -> RuntimeResult<()>;
    fn send_envelope(
        &mut self,
        message_id: uuid::Uuid,
        recipient: &str,
        ciphertext: &str,
    ) -> RuntimeResult<()>;
    fn poll_event(&mut self) -> Option<RelayEvent>;
    fn refresh_pairing_code(&mut self) -> RuntimeResult<InviteCode>;
    fn submit_pairing_code(&mut self, code: &str) -> RuntimeResult<PairingItem>;
    fn pairing_inbox(&mut self) -> RuntimeResult<Vec<PairingItem>>;
    fn acknowledge_pairing(&mut self, pairing_id: &str) -> RuntimeResult<()>;
    fn cancel_pairing(&mut self, pairing_id: &str) -> RuntimeResult<()>;
    fn confirm_contact(
        &mut self,
        capability: &str,
        peer_installation_id: &str,
    ) -> RuntimeResult<()>;
}

#[derive(Default)]
pub struct NoopEngineRelay;

impl EngineRelay for NoopEngineRelay {
    fn set_socks5_url(&mut self, _socks5_url: Option<String>) {}

    fn shutdown(&mut self) {}

    fn ensure_session(&mut self) -> RuntimeResult<()> {
        Err(RuntimeError::Unavailable(
            RelayUnavailableReason::ActorNotAttached.to_string(),
        ))
    }

    fn update_profile(&mut self, _nickname: &str) -> RuntimeResult<()> {
        Err(RuntimeError::Unavailable(
            RelayUnavailableReason::ActorNotAttached.to_string(),
        ))
    }

    fn send_envelope(
        &mut self,
        _message_id: uuid::Uuid,
        _recipient: &str,
        _ciphertext: &str,
    ) -> RuntimeResult<()> {
        Err(RuntimeError::Unavailable(
            RelayUnavailableReason::ActorNotAttached.to_string(),
        ))
    }

    fn poll_event(&mut self) -> Option<RelayEvent> {
        None
    }

    fn refresh_pairing_code(&mut self) -> RuntimeResult<InviteCode> {
        Err(RuntimeError::Unavailable(
            RelayUnavailableReason::ActorNotAttached.to_string(),
        ))
    }

    fn submit_pairing_code(&mut self, _code: &str) -> RuntimeResult<PairingItem> {
        Err(RuntimeError::Unavailable(
            RelayUnavailableReason::ActorNotAttached.to_string(),
        ))
    }

    fn pairing_inbox(&mut self) -> RuntimeResult<Vec<PairingItem>> {
        Err(RuntimeError::Unavailable(
            RelayUnavailableReason::ActorNotAttached.to_string(),
        ))
    }

    fn acknowledge_pairing(&mut self, _pairing_id: &str) -> RuntimeResult<()> {
        Err(RuntimeError::Unavailable(
            RelayUnavailableReason::ActorNotAttached.to_string(),
        ))
    }

    fn cancel_pairing(&mut self, _pairing_id: &str) -> RuntimeResult<()> {
        Err(RuntimeError::Unavailable(
            RelayUnavailableReason::ActorNotAttached.to_string(),
        ))
    }

    fn confirm_contact(
        &mut self,
        _capability: &str,
        _peer_installation_id: &str,
    ) -> RuntimeResult<()> {
        Err(RuntimeError::Unavailable(
            RelayUnavailableReason::ActorNotAttached.to_string(),
        ))
    }
}
