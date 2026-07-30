use std::time::Duration;

mod inbound;
mod outbound;
mod queue;
mod session;
mod types;
mod wire;

pub use session::PeerTransportHandle;
pub use types::{PeerDeliveryTag, PeerOutboundCommand, PeerTransportEvent};

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(15);
const ACK_TIMEOUT: Duration = Duration::from_secs(60);
const SESSION_IDLE_TIMEOUT: Duration = Duration::from_secs(90);
const KEEPALIVE_INTERVAL: Duration = Duration::from_secs(25);
const KEEPALIVE_TIMEOUT: Duration = Duration::from_secs(15);
const SESSION_TICK: Duration = Duration::from_millis(100);
const OUTBOUND_CAPACITY: usize = 128;
const SESSION_CAPACITY: usize = 64;
const EVENT_CAPACITY: usize = 128;
const MAX_IN_FLIGHT: usize = 8;
