use crate::contract::RuntimeEvent;
use serde::{Deserialize, Serialize};
use torchat_core::PROTOCOL_VERSION;
use uuid::Uuid;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeIdentity {
    pub installation_id: String,
    pub public_key: String,
    pub fingerprint: String,
}

impl RuntimeIdentity {
    pub fn from_parts(installation_id: String, public_key: String, fingerprint: String) -> Self {
        Self {
            installation_id,
            public_key,
            fingerprint,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeProfile {
    pub installation_id: String,
    pub nickname: String,
    pub public_key: String,
    pub fingerprint: String,
}

impl RuntimeProfile {
    pub fn from_parts(
        installation_id: String,
        nickname: String,
        public_key: String,
        fingerprint: String,
    ) -> Self {
        Self {
            installation_id,
            nickname,
            public_key,
            fingerprint,
        }
    }

    pub fn from_identity(identity: &RuntimeIdentity, nickname: String) -> Self {
        Self {
            installation_id: identity.installation_id.clone(),
            nickname,
            public_key: identity.public_key.clone(),
            fingerprint: identity.fingerprint.clone(),
        }
    }
}

pub use torchat_domain::{
    CapabilityStatus, ContactTransportPolicy, ConversationState, MessageState,
    MessageTransportOutcome, PeerConnectionStatus, PeerEndpointStatus, VerificationState,
};

fn default_verification_state() -> VerificationState {
    VerificationState::Unverified
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContactRecord {
    pub installation_id: String,
    pub nickname: String,
    pub public_key: String,
    pub fingerprint: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub local_alias: Option<String>,
    #[serde(default)]
    pub muted: bool,
    #[serde(default)]
    pub blocked: bool,
    #[serde(default = "default_verification_state")]
    pub verification: VerificationState,
    #[serde(default)]
    pub peer_endpoint_status: PeerEndpointStatus,
    #[serde(default)]
    pub peer_connection_status: PeerConnectionStatus,
    #[serde(default)]
    pub transport_policy: ContactTransportPolicy,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_peer_connected_at: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_seen_at: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dev: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversationSummary {
    pub id: String,
    pub contact_installation_id: String,
    pub status: ConversationState,
    pub last_message_preview: String,
    pub last_message_at: i64,
    pub unread_count: u32,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatMessage {
    pub id: String,
    pub conversation_id: String,
    pub outgoing: bool,
    pub body: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reply_to: Option<MessageReply>,
    pub state: MessageState,
    pub created_at: i64,
    #[serde(default)]
    pub attempt_count: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_attempt_at: Option<i64>,
    #[serde(default)]
    pub next_attempt_at: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ack_deadline: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_transport_error: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageReply {
    pub message_id: String,
    pub body: String,
    pub outgoing: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageSendEffect {
    pub message_id: String,
    pub conversation_id: String,
    pub recipient_installation_id: String,
    pub body: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reply_to: Option<MessageReply>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReceiptSendEffect {
    pub envelope_id: String,
    pub message_id: String,
    pub conversation_id: String,
    pub recipient_installation_id: String,
    pub received_at: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeSendEffect {
    pub message: Option<MessageSendEffect>,
    pub receipt: Option<ReceiptSendEffect>,
    pub pairing: Option<PairingSendEffect>,
}

impl From<MessageSendEffect> for RuntimeSendEffect {
    fn from(effect: MessageSendEffect) -> Self {
        Self {
            message: Some(effect),
            receipt: None,
            pairing: None,
        }
    }
}

impl From<ReceiptSendEffect> for RuntimeSendEffect {
    fn from(effect: ReceiptSendEffect) -> Self {
        Self {
            message: None,
            receipt: Some(effect),
            pairing: None,
        }
    }
}

impl From<PairingSendEffect> for RuntimeSendEffect {
    fn from(effect: PairingSendEffect) -> Self {
        Self {
            message: None,
            receipt: None,
            pairing: Some(effect),
        }
    }
}

impl RuntimeSendEffect {
    pub fn recipient_installation_id(&self) -> &str {
        if let Some(effect) = &self.message {
            return &effect.recipient_installation_id;
        }
        if let Some(effect) = &self.receipt {
            return &effect.recipient_installation_id;
        }
        if let Some(effect) = &self.pairing {
            return &effect.recipient_installation_id;
        }
        panic!("runtime send effect is missing payload");
    }

    pub fn message(&self) -> Option<&MessageSendEffect> {
        self.message.as_ref()
    }

    pub fn pairing(&self) -> Option<&PairingSendEffect> {
        self.pairing.as_ref()
    }

    pub fn receipt(&self) -> Option<&ReceiptSendEffect> {
        self.receipt.as_ref()
    }
}

impl Serialize for RuntimeSendEffect {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        if let Some(effect) = &self.message {
            return effect.serialize(serializer);
        }
        if let Some(effect) = &self.receipt {
            return effect.serialize(serializer);
        }
        if let Some(effect) = &self.pairing {
            return effect.serialize(serializer);
        }
        serializer.serialize_none()
    }
}

impl<'de> Deserialize<'de> for RuntimeSendEffect {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = serde_json::Value::deserialize(deserializer)?;
        if value.get("messageId").is_some() {
            if value.get("body").is_none() && value.get("receivedAt").is_some() {
                return serde_json::from_value::<ReceiptSendEffect>(value)
                    .map(|receipt| Self {
                        message: None,
                        receipt: Some(receipt),
                        pairing: None,
                    })
                    .map_err(serde::de::Error::custom);
            }
            return serde_json::from_value::<MessageSendEffect>(value)
                .map(|message| Self {
                    message: Some(message),
                    receipt: None,
                    pairing: None,
                })
                .map_err(serde::de::Error::custom);
        }
        if value.get("pairingId").is_some() {
            return serde_json::from_value::<PairingSendEffect>(value)
                .map(|pairing| Self {
                    message: None,
                    receipt: None,
                    pairing: Some(pairing),
                })
                .map_err(serde::de::Error::custom);
        }
        Err(serde::de::Error::custom("unknown runtime send effect"))
    }
}

pub use torchat_domain::{
    InviteState, PairingAvailableAction, PairingPeerOutcome, PairingRelationshipState,
    PairingSendKind, pairing_available_actions,
};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InviteCode {
    pub code: String,
    pub expires_at: i64,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingItem {
    pub pairing_id: String,
    /// Symmetric identity of the two-device pairing session. It is populated
    /// once both installation IDs are known and is deliberately optional for
    /// legacy/local records created before the peer identity was received.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pair_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sender: Option<ContactRecord>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub capability: Option<String>,
    pub expires_at: i64,
    pub state: InviteState,
    #[serde(default)]
    pub received: bool,
    #[serde(default, rename = "availableActions")]
    pub available_actions: Vec<PairingAvailableAction>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "offerInviteId"
    )]
    pub offer_invite_id: Option<String>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "offerPayload"
    )]
    pub offer_payload: Option<String>,
}

impl PairingItem {
    pub fn relationship_state(&self) -> PairingRelationshipState {
        match self.state {
            InviteState::Pending if self.received => {
                PairingRelationshipState::AwaitingLocalApproval
            }
            InviteState::Pending => PairingRelationshipState::AwaitingRemoteApproval,
            InviteState::Accepted => PairingRelationshipState::Finalizing,
            InviteState::Completed => PairingRelationshipState::Active,
            InviteState::Rejected
            | InviteState::Expired
            | InviteState::Archived
            | InviteState::Cancelled => PairingRelationshipState::Terminal,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingPreparation {
    pub pairing_id: String,
    pub recipient_installation_id: String,
    pub capability: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingSendEffect {
    pub pairing_id: String,
    pub recipient_installation_id: String,
    pub kind: PairingSendKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub payload: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingCancelEffect {
    pub pairing_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingAcknowledgeEffect {
    pub pairing_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingSyncResult {
    pub items: Vec<PairingItem>,
    #[serde(default)]
    pub acknowledgements: Vec<PairingAcknowledgeEffect>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WelcomeAcceptedResult {
    pub conversation: ConversationSummary,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeTorStatus {
    pub phase: crate::contract::RuntimeStatusPhase,
    pub label: String,
    pub detail: String,
    pub progress: Option<i32>,
    pub latency_ms: Option<u64>,
    pub retry_attempt: u32,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeFixture {
    pub profile: RuntimeProfile,
    pub contact: ContactRecord,
    pub conversation: ConversationSummary,
    pub message: ChatMessage,
    pub pairing_code: InviteCode,
    pub pairing_inbox_item: PairingItem,
    pub pairing_outbox_item: PairingItem,
    pub pairing_preparation: PairingPreparation,
    pub pairing_send_effects: Vec<PairingSendEffect>,
    pub pairing_peer_outcomes: Vec<PairingPeerOutcome>,
    pub pairing_sync_result: PairingSyncResult,
    pub pairing_completion_result: WelcomeAcceptedResult,
    pub message_send_effect: MessageSendEffect,
    pub message_transport_outcomes: Vec<MessageTransportOutcome>,
    pub events: Vec<RuntimeEvent>,
}

impl RuntimeFixture {
    pub fn from_json(value: &str) -> serde_json::Result<Self> {
        serde_json::from_str(value)
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeBootstrap {
    pub protocol_version: u16,
    pub installation_id: String,
    pub public_key: String,
}

impl RuntimeBootstrap {
    pub fn new(installation_id: String, public_key: String) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION,
            installation_id,
            public_key,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeEnvelope {
    pub message_id: Uuid,
    pub sender: String,
    pub recipient: String,
    pub ciphertext: String,
}

#[cfg(test)]
mod pairing_relationship_tests {
    use super::{InviteState, PairingItem, PairingRelationshipState};

    fn item(state: InviteState, received: bool) -> PairingItem {
        PairingItem {
            pairing_id: "pairing-test".to_owned(),
            pair_key: None,
            sender: None,
            capability: None,
            expires_at: 0,
            state,
            received,
            available_actions: Vec::new(),
            offer_invite_id: None,
            offer_payload: None,
        }
    }

    #[test]
    fn relationship_state_is_active_only_after_completion() {
        assert_eq!(
            item(InviteState::Pending, true).relationship_state(),
            PairingRelationshipState::AwaitingLocalApproval
        );
        assert_eq!(
            item(InviteState::Accepted, true).relationship_state(),
            PairingRelationshipState::Finalizing
        );
        assert_eq!(
            item(InviteState::Completed, true).relationship_state(),
            PairingRelationshipState::Active
        );
    }
}
