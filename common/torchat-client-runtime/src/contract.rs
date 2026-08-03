use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeType {
    RuntimeReady,
    TorStatus,
    TransportStatusChanged,
    ProfileReady,
    InviteReceived,
    InviteStateChanged,
    MessageReceived,
    MessageStateChanged,
    ConversationReadChanged,
    TypingChanged,
    ConversationFocusChanged,
    PresenceChanged,
    PeerEndpointChanged,
    PeerConnectionChanged,
    Changed,
    RuntimeError,
    RuntimeLog,
    ProjectionChanged,
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
    TransportStatusChanged {
        component: TransportComponent,
        state: TransportProbeState,
        detail: String,
        #[serde(default)]
        progress: Option<i32>,
        #[serde(default, rename = "latencyMs")]
        latency_ms: Option<u64>,
        #[serde(default, rename = "retryAttempt")]
        retry_attempt: u32,
        #[serde(default, rename = "retryInMs")]
        retry_in_ms: Option<u64>,
        #[serde(default)]
        generation: u64,
        #[serde(default)]
        endpoint: Option<String>,
        #[serde(default, rename = "updatedAt")]
        updated_at: i64,
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
        #[serde(default, rename = "conversationId")]
        conversation_id: Option<String>,
        #[serde(default)]
        text: Option<String>,
    },
    MessageStateChanged {
        #[serde(default, rename = "messageId")]
        message_id: Option<uuid::Uuid>,
        #[serde(default, rename = "conversationId")]
        conversation_id: Option<String>,
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
    ConversationFocusChanged {
        #[serde(rename = "conversationId")]
        conversation_id: String,
        focused: bool,
        #[serde(rename = "expiresAt")]
        expires_at: i64,
    },
    PresenceChanged {
        #[serde(rename = "contactId")]
        contact_id: String,
        online: bool,
        #[serde(default)]
        idle: bool,
        #[serde(rename = "observedAt")]
        observed_at: i64,
        #[serde(rename = "expiresAt")]
        expires_at: i64,
    },
    PeerEndpointChanged {
        #[serde(rename = "contactId")]
        contact_id: String,
        status: crate::models::PeerEndpointStatus,
    },
    PeerConnectionChanged {
        #[serde(rename = "contactId")]
        contact_id: String,
        status: crate::models::PeerConnectionStatus,
        #[serde(default, rename = "retryInMs")]
        retry_in_ms: Option<u64>,
    },
    ContactCapabilityChanged {
        #[serde(rename = "contactId")]
        contact_id: String,
        #[serde(rename = "capabilityId")]
        capability_id: String,
        sequence: u64,
        status: crate::models::CapabilityStatus,
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
    ProjectionChanged {
        #[serde(rename = "storeId")]
        store_id: String,
        #[serde(rename = "engineSessionId")]
        engine_session_id: String,
        revision: u64,
        #[serde(default)]
        application: bool,
        #[serde(default, rename = "conversationIds")]
        conversation_ids: Vec<String>,
    },
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum TransportComponent {
    Engine,
    Relay,
    Peer,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum TransportProbeState {
    Idle,
    Starting,
    Ready,
    Degraded,
    Error,
    Offline,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StartupReadinessSnapshot {
    pub engine_ready: bool,
    pub local_data_ready: bool,
    pub tor_ready: bool,
    pub peer_listener_ready: bool,
    pub onion_service_ready: bool,
    pub relay_ready: bool,
    pub generation: u64,
    pub detail: String,
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
