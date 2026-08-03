use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct RelayEnvelope {
    pub version: u16,
    pub message_id: Uuid,
    pub sender: String,
    pub recipient: String,
    pub ciphertext: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum RelayClientFrame {
    Envelope(RelayEnvelope),
    DeliveryReceipt { message_id: Uuid, sender: String },
    Ping,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum RelayServerFrame {
    Ready { installation_id: String },
    PairingAvailable { pairing_id: Uuid },
    Envelope(RelayEnvelope),
    Forwarded { message_id: Uuid },
    DeliveryReceipt { message_id: Uuid },
    RecipientOffline { message_id: Uuid },
    Error { code: String },
    Pong,
}
