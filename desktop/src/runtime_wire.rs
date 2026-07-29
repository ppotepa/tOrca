use crate::{
    model::{PairingInboxItem, PairingRequestResponse},
    store::StoredMessage,
};
use torchat_client_runtime::{
    ContactRecord, InviteState, RuntimeMessageLike, RuntimePairingItemLike,
    contact_record_from_card,
};

impl RuntimeMessageLike for StoredMessage {
    fn runtime_message_id(&self) -> String {
        self.id.clone()
    }

    fn runtime_message_conversation_id(&self) -> String {
        self.peer.clone()
    }

    fn runtime_message_outgoing(&self) -> bool {
        self.outgoing
    }

    fn runtime_message_body(&self) -> String {
        self.body.clone()
    }

    fn runtime_message_state(&self) -> String {
        self.state.as_str().to_owned()
    }

    fn runtime_message_created_at(&self) -> i64 {
        self.created_at
    }
}

impl RuntimePairingItemLike for PairingInboxItem {
    fn runtime_pairing_id(&self) -> String {
        self.pairing_id.to_string()
    }

    fn runtime_pairing_sender(&self) -> Option<ContactRecord> {
        Some(contact_record_from_card(&self.sender, false))
    }

    fn runtime_pairing_capability(&self) -> Option<String> {
        Some(self.capability.clone())
    }

    fn runtime_pairing_expires_at(&self) -> i64 {
        self.expires_at
    }

    fn runtime_pairing_state(&self) -> InviteState {
        self.state
    }

    fn runtime_pairing_received(&self) -> bool {
        true
    }

    fn runtime_pairing_offer_invite_id(&self) -> Option<String> {
        self.offer_invite_id.clone()
    }

    fn runtime_pairing_offer_payload(&self) -> Option<String> {
        self.offer_payload.clone()
    }
}

impl RuntimePairingItemLike for PairingRequestResponse {
    fn runtime_pairing_id(&self) -> String {
        self.pairing_id.to_string()
    }

    fn runtime_pairing_sender(&self) -> Option<ContactRecord> {
        None
    }

    fn runtime_pairing_capability(&self) -> Option<String> {
        None
    }

    fn runtime_pairing_expires_at(&self) -> i64 {
        self.expires_at
    }

    fn runtime_pairing_state(&self) -> InviteState {
        self.state
    }

    fn runtime_pairing_received(&self) -> bool {
        false
    }
}
