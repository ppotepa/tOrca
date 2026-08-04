pub mod actor;
pub mod connection;
pub mod error;
pub mod heartbeat;
pub mod rendezvous;
pub mod writer;

use torchat_client_runtime::{InviteCode, PairingItem, RuntimeResult};
use torchat_core::relay::RelayEnvelope;

pub use actor::SharedRelayActor;
pub use connection::RelayConnectionConfig;
pub use error::RelayUnavailableReason;
pub use heartbeat::RelayHeartbeatConfig;
pub use rendezvous::{PairingRendezvousClient, PairingSlot, PairingStarted, ResolvedSlot};
pub use writer::RelayWriterConfig;

#[derive(Clone, Debug)]
pub enum RelayEvent {
    PairingAvailable {
        pairing_id: uuid::Uuid,
    },
    PairingFinalized {
        pairing_id: uuid::Uuid,
    },
    Envelope(RelayEnvelope),
}

pub trait EngineRelay: Send {
    fn set_socks5_url(&mut self, socks5_url: Option<String>);
    fn invalidate_session(&mut self) {}
    fn shutdown(&mut self);
    fn ensure_session(&mut self) -> RuntimeResult<()>;
    fn send_envelope(
        &mut self,
        message_id: uuid::Uuid,
        recipient: &str,
        ciphertext: &str,
    ) -> RuntimeResult<()>;
    fn poll_event(&mut self) -> Option<RelayEvent>;
    fn refresh_pairing_code(&mut self) -> RuntimeResult<InviteCode>;
    fn submit_pairing_code(&mut self, code: &str) -> RuntimeResult<PairingItem>;
    fn submit_pairing_code_with_offer(
        &mut self,
        code: &str,
        pairing_id: uuid::Uuid,
        offer: String,
    ) -> RuntimeResult<PairingItem>;
    fn cancel_pairing(&mut self, pairing_id: &str) -> RuntimeResult<()>;
}

