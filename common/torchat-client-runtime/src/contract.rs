use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeType {
    RuntimeReady,
    TorStatus,
    ProfileReady,
    InviteReceived,
    InviteStateChanged,
    MessageReceived,
    MessageStateChanged,
    ConversationReadChanged,
    Changed,
    RuntimeError,
    RuntimeLog,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RuntimeMethod {
    ApplyRemoteProfile,
    ReportRuntimeError,
    ReportRuntimeLog,
    Connect,
    Identity,
    Profile,
    SetNickname,
    RefreshPairingCode,
    PrepareSubmitPairingCode,
    SubmitPairingCode,
    PairingInbox,
    MergePairingInbox,
    PairingOutbox,
    MergePairingOutbox,
    ArchivePairing,
    VerifyContact,
    Contacts,
    Conversations,
    Messages,
    OpenConversation,
    CloseConversation,
    StartConversation,
    SendMessage,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum RuntimeEvent {
    RuntimeReady {
        protocol: u16,
    },
    TorStatus {
        phase: RuntimeStatusPhase,
        label: String,
        #[serde(default)]
        detail: String,
        progress: Option<i32>,
        #[serde(rename = "latencyMs")]
        latency_ms: Option<u64>,
        #[serde(default, rename = "retryAttempt")]
        retry_attempt: u32,
    },
    ProfileReady {
        profile: crate::models::RuntimeProfile,
    },
    InviteReceived {
        #[serde(default, rename = "pairingId")]
        pairing_id: Option<String>,
        #[serde(default)]
        nickname: Option<String>,
    },
    InviteStateChanged {
        #[serde(default, rename = "pairingId")]
        pairing_id: Option<String>,
        #[serde(default)]
        state: Option<crate::models::InviteState>,
    },
    MessageReceived {
        #[serde(default, rename = "messageId")]
        message_id: Option<uuid::Uuid>,
        #[serde(default)]
        text: Option<String>,
    },
    MessageStateChanged {
        #[serde(default, rename = "messageId")]
        message_id: Option<uuid::Uuid>,
        #[serde(default)]
        state: Option<crate::models::MessageState>,
    },
    ConversationReadChanged {
        #[serde(default, rename = "conversationId")]
        conversation_id: Option<String>,
        #[serde(default, rename = "unreadCount")]
        unread_count: Option<u32>,
    },
    Changed {
        #[serde(default)]
        kind: Option<String>,
    },
    RuntimeError {
        message: String,
    },
    RuntimeLog {
        message: String,
    },
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeStatusPhase {
    #[serde(alias = "external")]
    Starting,
    #[serde(alias = "bootstrapping")]
    Bootstrapping,
    #[serde(alias = "onion_connecting")]
    #[serde(alias = "circuit_building")]
    #[serde(alias = "authenticating")]
    #[serde(alias = "waiting_for_ready")]
    #[serde(alias = "api")]
    #[serde(alias = "ready")]
    Connecting,
    Degraded,
    Connected,
    #[serde(alias = "backoff")]
    Reconnecting,
    Offline,
    Error,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "method", content = "params", rename_all = "camelCase")]
pub enum RuntimeCommand {
    ApplyRemoteProfile {
        profile: crate::RuntimeProfile,
    },
    ReportRuntimeError {
        message: String,
    },
    ReportRuntimeLog {
        message: String,
    },
    Connect,
    Identity,
    Profile,
    SetNickname {
        nickname: String,
    },
    RefreshPairingCode,
    PrepareSubmitPairingCode {
        code: String,
    },
    SubmitPairingCode {
        code: String,
    },
    PairingInbox,
    MergePairingInbox {
        items: Vec<crate::PairingItem>,
    },
    PairingOutbox,
    MergePairingOutbox {
        items: Vec<crate::PairingItem>,
    },
    ArchivePairing {
        pairing_id: String,
    },
    VerifyContact {
        installation_id: String,
    },
    Contacts,
    Conversations,
    Messages {
        id: String,
    },
    OpenConversation {
        id: String,
    },
    CloseConversation,
    StartConversation {
        contact_id: String,
    },
    SendMessage {
        id: String,
        text: String,
    },
}
