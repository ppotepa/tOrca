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
    AppVisibilityChanged {
        foreground: bool,
    },
    NetworkChanged,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum EngineCommand {
    Bootstrap,
    Connect,
    GetIdentity,
    GetProfile,
    PairingInbox,
    PairingOutbox,
    ListContacts,
    ListConversations,
    ListMessages {
        conversation_id: String,
    },
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
    },
    PlatformFact {
        fact: PlatformFact,
    },
    Shutdown,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineCommandEnvelope {
    pub request_id: String,
    pub command: EngineCommand,
}
