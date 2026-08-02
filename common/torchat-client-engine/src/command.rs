use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlatformKind {
    Android,
    Desktop,
    Ios,
    Macos,
    Linux,
    Windows,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TorPhase {
    Starting,
    Bootstrapping,
    Ready,
    Failed,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PlatformFact {
    TorStatus {
        phase: TorPhase,
        progress: u8,
        detail: String,
    },
    TorEndpointAvailable {
        socks5_url: String,
    },
    TorEndpointLost {
        reason: String,
    },
    OnionServiceAvailable {
        onion_address: String,
        virtual_port: u16,
        generation: u64,
    },
    OnionServiceLost {
        reason: String,
    },
    AppVisibilityChanged {
        foreground: bool,
    },
    NetworkChanged {
        #[serde(default = "default_true")]
        online: bool,
    },
    PowerModeChanged {
        #[serde(default)]
        battery_saver: bool,
        #[serde(default)]
        device_idle: bool,
    },
    BackgroundExecutionRestricted {
        restricted: bool,
    },
}

const fn default_true() -> bool {
    true
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum EngineCommand {
    Bootstrap,
    Connect,
    GetIdentity,
    GetProfile,
    GetStartupReadiness,
    GetApplicationSnapshot,
    PairingInbox,
    PairingOutbox,
    ListContacts,
    ListConversations,
    ListMessages {
        conversation_id: String,
    },
    GetPeerEndpoint,
    RetryPeerConnection {
        installation_id: String,
    },
    RotatePeerEndpoint,
    SetNickname {
        nickname: String,
    },
    RefreshPairingCode,
    SubmitPairingCode {
        code: String,
    },
    AcceptPairing {
        pairing_id: String,
    },
    RejectPairing {
        pairing_id: String,
    },
    CancelPairing {
        pairing_id: String,
    },
    ArchivePairing {
        pairing_id: String,
    },
    VerifyContact {
        installation_id: String,
    },
    UpdateContactSettings {
        installation_id: String,
        #[serde(default)]
        local_alias: Option<String>,
        #[serde(default)]
        muted: bool,
        #[serde(default)]
        blocked: bool,
        #[serde(default)]
        transport_policy: Option<torchat_client_runtime::ContactTransportPolicy>,
    },
    RemoveRelationship {
        installation_id: String,
        #[serde(default = "default_true")]
        preserve_history: bool,
    },
    StartConversation {
        contact_id: String,
    },
    OpenConversation {
        conversation_id: String,
    },
    CloseConversation,
    SendMessage {
        conversation_id: String,
        body: String,
        #[serde(default)]
        reply_to_message_id: Option<String>,
    },
    RetryMessage {
        message_id: String,
    },
    DeleteMessageLocal {
        message_id: String,
    },
    SetTyping {
        conversation_id: String,
        typing: bool,
    },
    SetPresence {
        online: bool,
    },
    SendReadReceipts {
        conversation_id: String,
    },
    PlatformFact {
        fact: PlatformFact,
    },
    Shutdown,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum EngineQuery {
    GetIdentity,
    GetProfile,
    GetStartupReadiness,
    GetPairingInbox,
    GetPairingOutbox,
    ListContacts,
    ListConversations,
    ListMessages { conversation_id: String },
    GetPeerEndpoint,
    GetApplicationSnapshot,
    GetDiagnostics,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "request", rename_all = "snake_case")]
pub enum EngineRequest {
    Command(EngineCommand),
    Query(EngineQuery),
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineCommandEnvelope {
    pub request_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command_id: Option<String>,
    pub command: EngineCommand,
}
