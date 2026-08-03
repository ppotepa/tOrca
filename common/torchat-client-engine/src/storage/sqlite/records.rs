#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PendingWelcomeRecord {
    pub invite_id: String,
    pub recipient_installation_id: String,
    pub payload: Vec<u8>,
    pub expires_at: i64,
    pub attempt_count: u32,
    pub next_attempt_at: i64,
    pub last_error: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PendingLocalInviteMlsRecord {
    pub invite_id: String,
    pub recipient_installation_id: Option<String>,
    pub snapshot: Vec<u8>,
    pub expires_at: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ReceivedEnvelopeRecord {
    pub sender_installation_id: String,
    pub message_id: String,
    pub ciphertext_hash: Vec<u8>,
    pub received_at: i64,
    pub receipt_state: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeliveryReceiptRecord {
    pub envelope_id: String,
    pub message_id: String,
    pub conversation_id: String,
    pub original_sender: String,
    pub received_at: i64,
    pub relay_payload: Option<Vec<u8>>,
    pub state: String,
    pub attempt_count: u32,
    pub next_attempt_at: i64,
    pub last_error: Option<String>,
    pub created_at: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ReadReceiptOutboxRecord {
    pub receipt_id: String,
    pub contact_installation_id: String,
    pub conversation_id: String,
    pub message_ids_json: String,
    pub read_at: i64,
    pub wire_ciphertext: Option<Vec<u8>>,
    pub state: String,
    pub attempt_count: u32,
    pub next_attempt_at: i64,
    pub last_error: Option<String>,
    pub created_at: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredMessageRecord {
    pub id: String,
    pub conversation_id: String,
    pub outgoing: bool,
    pub body: String,
    pub state: String,
    pub created_at: i64,
    pub wire_ciphertext: Option<Vec<u8>>,
    pub ciphertext_hash: Option<Vec<u8>>,
    pub attempt_count: u32,
    pub last_attempt_at: Option<i64>,
    pub next_attempt_at: i64,
    pub ack_deadline: Option<i64>,
    pub last_transport_error: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OutboundDeliveryRecord {
    pub message_id: String,
    pub contact_installation_id: String,
    pub sequence: u64,
    pub state: String,
    pub attempt_count: u32,
    pub next_attempt_at: i64,
    pub ack_deadline: Option<i64>,
    pub last_error: Option<String>,
    pub created_at: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InboundPeerEnvelopeRecord {
    pub sender_installation_id: String,
    pub message_id: String,
    pub conversation_id: String,
    pub sequence: u64,
    pub ciphertext: Vec<u8>,
    pub ciphertext_hash: Vec<u8>,
    pub state: String,
    pub received_at: i64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InboundEnvelopeStoreResult {
    Stored,
    Duplicate { delivered: bool },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PairingResponseRecord {
    pub pairing_id: String,
    pub recipient_installation_id: String,
    pub state: String,
    pub offer_payload: Option<Vec<u8>>,
    pub attempt_count: u32,
    pub next_attempt_at: i64,
    pub last_error: Option<String>,
    pub expires_at: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PeerEndpointBootstrapRecord {
    pub contact_installation_id: String,
    pub payload: Vec<u8>,
    pub endpoint_sequence: u64,
    pub attempt_count: u32,
    pub next_attempt_at: i64,
    pub last_error: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PendingPeerEndpointInboxRecord {
    pub contact_installation_id: String,
    pub payload: Vec<u8>,
    pub endpoint_sequence: u64,
    pub received_at: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PendingApplicationEnvelopeRecord {
    pub sender_installation_id: String,
    pub message_id: String,
    pub envelope_json: String,
    pub ciphertext: Vec<u8>,
    pub ciphertext_hash: Vec<u8>,
    pub received_at: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CapabilityDeliveryRecord {
    pub delivery_id: String,
    pub contact_installation_id: String,
    pub payload: Vec<u8>,
    pub attempt_count: u32,
    pub next_attempt_at: i64,
    pub last_error: Option<String>,
    pub created_at: i64,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeadLetterRecord {
    pub kind: String,
    pub id: String,
    pub attempt_count: u32,
    pub dead_lettered_at: i64,
    pub last_error: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PendingContactConfirmationRecord {
    pub pairing_id: String,
    pub peer_installation_id: String,
    pub capability: String,
    pub attempt_count: u32,
    pub next_attempt_at: i64,
    pub last_error: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RetryKind {
    MessageSend,
    MessageAckDeadline,
    Receipt,
    PendingWelcome,
    PairingResponse,
    PeerEndpointBootstrap,
    ContactConfirmation,
    PairingAcknowledgement,
    ReadReceipt,
    RelationshipRemoval,
    RelationshipRemovalAck,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RetryDeadline {
    pub kind: RetryKind,
    pub at_ms: i64,
}
use serde::Serialize;
