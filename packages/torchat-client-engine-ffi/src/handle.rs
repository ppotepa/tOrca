use std::sync::Mutex;

use tokio::runtime::Runtime;
use tokio_util::sync::CancellationToken;
use torchat_client_engine::{EngineCommandSender, event::EngineEventReceiver};

pub struct EngineHandle {
    pub runtime: Runtime,
    /// Lifecycle and command submission are independent from event polling.
    /// `poll_json` may wait for hundreds of milliseconds, so it must never
    /// hold this mutex and delay a platform fact or a user command.
    pub command_state: Mutex<EngineHandleCommandState>,
    pub events: Mutex<EngineEventReceiver>,
}

pub struct EngineHandleCommandState {
    pub commands: EngineCommandSender,
    pub shutdown_token: CancellationToken,
    pub started: bool,
    pub shutdown: bool,
}
