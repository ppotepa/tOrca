use crate::{ChatMessage, ContactRecord, InviteState, PairingItem};

pub trait RuntimeMessageLike {
    fn runtime_message_id(&self) -> String;
    fn runtime_message_conversation_id(&self) -> String;
    fn runtime_message_outgoing(&self) -> bool;
    fn runtime_message_body(&self) -> String;
    fn runtime_message_state(&self) -> String;
    fn runtime_message_created_at(&self) -> i64;
}

pub trait RuntimePairingItemLike {
    fn runtime_pairing_id(&self) -> String;
    fn runtime_pairing_sender(&self) -> Option<ContactRecord>;
    fn runtime_pairing_capability(&self) -> Option<String>;
    fn runtime_pairing_expires_at(&self) -> i64;
    fn runtime_pairing_state(&self) -> InviteState;
    fn runtime_pairing_received(&self) -> bool;
    fn runtime_pairing_offer_invite_id(&self) -> Option<String> {
        None
    }
    fn runtime_pairing_offer_payload(&self) -> Option<String> {
        None
    }
}

pub fn runtime_messages_from_iter<I, T>(items: I) -> Vec<ChatMessage>
where
    I: IntoIterator<Item = T>,
    T: RuntimeMessageLike,
{
    items
        .into_iter()
        .map(|item| ChatMessage {
            id: item.runtime_message_id(),
            conversation_id: item.runtime_message_conversation_id(),
            outgoing: item.runtime_message_outgoing(),
            body: item.runtime_message_body(),
            reply_to: None,
            state: crate::runtime_message_state(&item.runtime_message_state()),
            created_at: item.runtime_message_created_at(),
            attempt_count: 0,
            last_attempt_at: None,
            next_attempt_at: 0,
            ack_deadline: None,
            last_transport_error: None,
        })
        .collect()
}

pub fn runtime_pairing_items_from_iter<I, T>(items: I) -> Vec<PairingItem>
where
    I: IntoIterator<Item = T>,
    T: RuntimePairingItemLike,
{
    items
        .into_iter()
        .map(|item| {
            let state = item.runtime_pairing_state();
            let received = item.runtime_pairing_received();
            PairingItem {
                pairing_id: item.runtime_pairing_id(),
                sender: item.runtime_pairing_sender(),
                capability: item.runtime_pairing_capability(),
                expires_at: item.runtime_pairing_expires_at(),
                state,
                received,
                available_actions: crate::pairing_available_actions(state, received),
                offer_invite_id: item.runtime_pairing_offer_invite_id(),
                offer_payload: item.runtime_pairing_offer_payload(),
            }
        })
        .collect()
}

pub fn runtime_contacts_from_iter<I, T, F>(items: I, mut record: F) -> Vec<ContactRecord>
where
    I: IntoIterator<Item = T>,
    F: FnMut(T) -> ContactRecord,
{
    items.into_iter().map(&mut record).collect()
}
