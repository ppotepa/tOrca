use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ApplicationReply {
    pub message_id: Uuid,
    pub body: String,
    pub outgoing: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ContactRemovedPayloadV1 {
    pub version: u16,
    pub message_id: Uuid,
    pub removed_at: i64,
    pub preserve_history: bool,
}

impl ContactRemovedPayloadV1 {
    pub fn encode(&self) -> Result<Vec<u8>, String> {
        serde_json::to_vec(self).map_err(|error| format!("encode contact removal payload: {error}"))
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, String> {
        serde_json::from_slice(bytes)
            .map_err(|error| format!("decode contact removal payload: {error}"))
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ApplicationPayloadV1 {
    Message {
        version: u16,

        #[serde(rename = "messageId")]
        message_id: Uuid,

        #[serde(rename = "sentAt")]
        sent_at: i64,

        body: String,

        #[serde(default, skip_serializing_if = "Option::is_none")]
        reply_to: Option<ApplicationReply>,
    },

    DeliveryReceipt {
        version: u16,

        #[serde(rename = "messageId")]
        message_id: Uuid,

        #[serde(rename = "receivedAt")]
        received_at: i64,
    },

    Typing {
        version: u16,
        #[serde(rename = "sentAt")]
        sent_at: i64,
        typing: bool,
    },

    Presence {
        version: u16,
        #[serde(rename = "sentAt")]
        sent_at: i64,
        online: bool,
    },

    ReadReceipt {
        version: u16,
        #[serde(rename = "messageIds")]
        message_ids: Vec<Uuid>,
        #[serde(rename = "readAt")]
        read_at: i64,
    },

    RelationshipRemoved {
        version: u16,

        #[serde(rename = "messageId")]
        message_id: Uuid,

        #[serde(rename = "removedAt")]
        removed_at: i64,

        #[serde(rename = "preserveHistory")]
        preserve_history: bool,
    },

    CapabilityOffer {
        version: u16,
        #[serde(rename = "capabilityId")]
        capability_id: String,
        secret: String,
        sequence: u64,
        #[serde(rename = "issuedAt")]
        issued_at: i64,
        #[serde(rename = "expiresAt")]
        expires_at: Option<i64>,
    },

    CapabilityOfferAck {
        version: u16,
        #[serde(rename = "capabilityId")]
        capability_id: String,
        sequence: u64,
    },

    CapabilityRevoked {
        version: u16,
        #[serde(rename = "capabilityId")]
        capability_id: String,
        sequence: u64,
        #[serde(rename = "revokedAt")]
        revoked_at: i64,
    },
}

impl ApplicationPayloadV1 {
    pub fn encode(&self) -> Result<Vec<u8>, String> {
        serde_json::to_vec(self).map_err(|error| format!("encode application payload: {error}"))
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, String> {
        serde_json::from_slice(bytes)
            .map_err(|error| format!("decode application payload: {error}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn payload_round_trips_message_and_receipt() {
        let message = ApplicationPayloadV1::Message {
            version: 1,
            message_id: Uuid::nil(),
            sent_at: 42,
            body: "hi".into(),
            reply_to: Some(ApplicationReply {
                message_id: Uuid::from_u128(7),
                body: "earlier".into(),
                outgoing: false,
            }),
        };
        let encoded = message.encode().unwrap();
        assert_eq!(ApplicationPayloadV1::decode(&encoded).unwrap(), message);

        let receipt = ApplicationPayloadV1::DeliveryReceipt {
            version: 1,
            message_id: Uuid::nil(),
            received_at: 43,
        };
        let encoded = receipt.encode().unwrap();
        assert_eq!(ApplicationPayloadV1::decode(&encoded).unwrap(), receipt);

        for payload in [
            ApplicationPayloadV1::Typing {
                version: 1,
                sent_at: 45,
                typing: true,
            },
            ApplicationPayloadV1::Presence {
                version: 1,
                sent_at: 46,
                online: true,
            },
            ApplicationPayloadV1::ReadReceipt {
                version: 1,
                message_ids: vec![Uuid::from_u128(9)],
                read_at: 47,
            },
            ApplicationPayloadV1::RelationshipRemoved {
                version: 1,
                message_id: Uuid::from_u128(10),
                removed_at: 48,
                preserve_history: false,
            },
        ] {
            let encoded = payload.encode().unwrap();
            assert_eq!(ApplicationPayloadV1::decode(&encoded).unwrap(), payload);
        }
    }

    #[test]
    fn contact_removal_payload_round_trips() {
        let payload = ContactRemovedPayloadV1 {
            version: 1,
            message_id: Uuid::from_u128(8),
            removed_at: 44,
            preserve_history: true,
        };
        let encoded = payload.encode().unwrap();
        assert_eq!(ContactRemovedPayloadV1::decode(&encoded).unwrap(), payload);
    }
}
