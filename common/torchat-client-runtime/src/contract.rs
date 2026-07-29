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
    TypingChanged,
    PresenceChanged,
    Changed,
    RuntimeError,
    RuntimeLog,
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
    TypingChanged {
        #[serde(rename = "conversationId")]
        conversation_id: String,
        typing: bool,
        #[serde(rename = "expiresAt")]
        expires_at: i64,
    },
    PresenceChanged {
        #[serde(rename = "contactId")]
        contact_id: String,
        online: bool,
        #[serde(rename = "observedAt")]
        observed_at: i64,
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
    Starting,
    Bootstrapping,
    Connecting,
    Degraded,
    Connected,
    Reconnecting,
    Offline,
    Error,
}
