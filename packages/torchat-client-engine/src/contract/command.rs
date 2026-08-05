use serde::{Deserialize, Serialize};

use super::PlatformFact;

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
    ListPairings,
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
    GetContactEndpointCapability {
        installation_id: String,
    },
    RotateContactEndpointCapability {
        installation_id: String,
    },
    RevokeContactEndpointCapability {
        installation_id: String,
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
    UpdateContactSettings {
        installation_id: String,
        #[serde(default)]
        local_alias: Option<String>,
        #[serde(default)]
        muted: bool,
        #[serde(default)]
        blocked: bool,
        #[serde(default)]
        transport_policy: Option<torchat_runtime::ContactTransportPolicy>,
    },
    RequestRelationshipRemoval {
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
    RetryDeadLetter {
        kind: String,
        id: String,
    },
    ListDeadLetters,
    DeleteMessageLocal {
        message_id: String,
    },
    SetTyping {
        conversation_id: String,
        typing: bool,
    },
    SetConversationFocus {
        conversation_id: String,
        focused: bool,
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
