use std::sync::Mutex;

use tokio::runtime::Runtime;
use torchat_client_engine::ClientEngine;

pub struct EngineHandle {
    pub runtime: Runtime,
    pub state: Mutex<EngineHandleState>,
}

pub struct EngineHandleState {
    pub engine: ClientEngine,
    pub started: bool,
    pub shutdown: bool,
}
