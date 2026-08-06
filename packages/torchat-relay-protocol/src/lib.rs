//! Strict opaque rendezvous wire frames shared by the client and relay.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub const MAX_PAIRING_BLOB_BYTES: usize = 48 * 1024;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum RendezvousClientFrame {
    CreatePairingSlot {
        request_id: Uuid,
        rendezvous_public_key: [u8; 32],
        requested_ttl_seconds: u16,
    },
    ResolvePairingCode {
        request_id: Uuid,
        display_code: String,
    },
    BeginPairing {
        request_id: Uuid,
        pairing_id: Uuid,
        slot_handle: String,
        joiner_rendezvous_public_key: [u8; 32],
        encrypted_offer: Vec<u8>,
    },
    AcceptPairing {
        pairing_id: Uuid,
        side_token: String,
        encrypted_response: Vec<u8>,
    },
    RejectPairing {
        pairing_id: Uuid,
        side_token: String,
    },
    PairingCommitted {
        pairing_id: Uuid,
        side_token: String,
    },
    PairingFinalized {
        pairing_id: Uuid,
        side_token: String,
    },
    CancelPairing {
        pairing_id: Uuid,
        side_token: String,
    },
    CancelPairingSlot {
        slot_handle: String,
        slot_capability: String,
    },
    Ping,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum RendezvousServerFrame {
    PairingSlotCreated {
        request_id: Uuid,
        slot_handle: String,
        display_code: String,
        slot_capability: String,
        expires_at_unix: i64,
    },
    PairingSlotResolved {
        request_id: Uuid,
        slot_handle: String,
        owner_rendezvous_public_key: [u8; 32],
        expires_at_unix: i64,
    },
    PairingRequested {
        pairing_id: Uuid,
        slot_handle: String,
        owner_side_token: String,
        joiner_rendezvous_public_key: [u8; 32],
        encrypted_offer: Vec<u8>,
        expires_at_unix: i64,
    },
    PairingStarted {
        request_id: Uuid,
        pairing_id: Uuid,
        joiner_side_token: String,
        expires_at_unix: i64,
    },
    PairingAccepted {
        pairing_id: Uuid,
        encrypted_response: Vec<u8>,
    },
    PairingRejected {
        pairing_id: Uuid,
    },
    PairingCommitted {
        pairing_id: Uuid,
    },
    PairingFinalized {
        pairing_id: Uuid,
    },
    PairingCancelled {
        pairing_id: Uuid,
    },
    Error {
        request_id: Option<Uuid>,
        code: String,
    },
    Pong,
}

#[cfg(test)]
mod tests {
    use super::{RendezvousClientFrame, RendezvousServerFrame};
    use uuid::Uuid;

    #[test]
    fn client_frame_round_trips_with_stable_wire_tag() {
        let frame = RendezvousClientFrame::CreatePairingSlot {
            request_id: Uuid::nil(),
            rendezvous_public_key: [7; 32],
            requested_ttl_seconds: 120,
        };
        let encoded = serde_json::to_vec(&frame).unwrap();
        assert!(
            String::from_utf8(encoded.clone())
                .unwrap()
                .contains("create_pairing_slot")
        );
        assert!(matches!(
            serde_json::from_slice::<RendezvousClientFrame>(&encoded).unwrap(),
            RendezvousClientFrame::CreatePairingSlot { .. }
        ));
    }

    #[test]
    fn server_frame_round_trips_error_request_id() {
        let frame = RendezvousServerFrame::Error {
            request_id: Some(Uuid::nil()),
            code: "invalid_frame".into(),
        };
        let encoded = serde_json::to_vec(&frame).unwrap();
        assert!(matches!(
            serde_json::from_slice::<RendezvousServerFrame>(&encoded).unwrap(),
            RendezvousServerFrame::Error { .. }
        ));
    }
}
