use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;
use tokio::time::Duration;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConnectionState {
    WaitingForTor,
    Disconnected,
    Connecting,
    Authenticating,
    WaitingForReady,
    Connected,
    Backoff { attempt: u32, retry_in_ms: u64 },
    Stopped,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectionSnapshot {
    pub state: ConnectionState,
    pub generation: u64,
    pub detail: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NotificationKind {
    MessageReceived,
    PairingRequest,
    PairingCompleted,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotificationRequest {
    pub id: String,
    pub kind: NotificationKind,
    pub conversation_id: Option<String>,
    pub preview_text: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineLogEvent {
    pub level: String,
    pub message: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineFatalError {
    pub code: String,
    pub message: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub enum PlatformAction {
    ConfigureOnionService {
        local_port: u16,
        virtual_port: u16,
        generation: u64,
    },
    RotateOnionService {
        generation: u64,
    },
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub enum ResponsePayload {
    #[default]
    Empty,
    Json {
        value: serde_json::Value,
    },
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum ResponseResult {
    Ok {
        #[serde(default)]
        payload: ResponsePayload,
    },
    Error {
        code: String,
        message: String,
    },
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub enum EngineEvent {
    Response {
        request_id: String,
        result: ResponseResult,
    },
    Runtime {
        event: torchat_client_runtime::RuntimeEvent,
    },
    Connection {
        snapshot: ConnectionSnapshot,
    },
    PlatformAction {
        action: PlatformAction,
    },
    NotificationRequested {
        notification: NotificationRequest,
    },
    Log {
        log: EngineLogEvent,
    },
    Fatal {
        error: EngineFatalError,
    },
}

pub struct EngineEventReceiver {
    receiver: mpsc::Receiver<EngineEvent>,
}

impl EngineEventReceiver {
    pub fn new(receiver: mpsc::Receiver<EngineEvent>) -> Self {
        Self { receiver }
    }

    pub async fn recv(&mut self) -> Option<EngineEvent> {
        self.receiver.recv().await
    }

    pub fn try_recv(&mut self) -> Result<EngineEvent, mpsc::error::TryRecvError> {
        self.receiver.try_recv()
    }

    pub async fn recv_timeout(&mut self, timeout: Duration) -> Option<EngineEvent> {
        tokio::time::timeout(timeout, self.receiver.recv())
            .await
            .ok()
            .flatten()
    }
}
