use serde::{Deserialize, Serialize};
use uuid::Uuid;

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
    },

    DeliveryReceipt {
        version: u16,

        #[serde(rename = "messageId")]
        message_id: Uuid,

        #[serde(rename = "receivedAt")]
        received_at: i64,
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
    }
}
