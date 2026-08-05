use rusqlite::{OptionalExtension, Row};
use serde::de::DeserializeOwned;
use torchat_runtime::{
    ChatMessage, ContactRecord, ContactTransportPolicy, ConversationState, ConversationSummary,
    InviteState, MessageReply, MessageState, PairingItem, PeerConnectionStatus,
    PeerEndpointStatus, PointLookupStorage, RuntimeError, RuntimeResult, VerificationState,
    pairing_available_actions,
    logic::{fallback_contact_nickname, normalized_contact_nickname},
};

use super::ClientDatabase;

const CONTACT_BY_INSTALLATION_ID: &str =
    include_str!("../../sql/queries/contacts/contact_by_installation_id.sql");
const CONVERSATION_BY_ID: &str =
    include_str!("../../sql/queries/conversations/conversation_by_id.sql");
const CONVERSATION_FOR_CONTACT: &str =
    include_str!("../../sql/queries/conversations/conversation_for_contact.sql");
const PAIRING_INBOX_BY_ID: &str =
    include_str!("../../sql/queries/pairing/pairing_inbox_by_id.sql");
const PAIRING_OUTBOX_BY_ID: &str =
    include_str!("../../sql/queries/pairing/pairing_outbox_by_id.sql");
const MESSAGE_BY_ID: &str =
    include_str!("../../sql/queries/messages/message_by_id.sql");

impl ClientDatabase {
    pub fn contact_by_installation_id(
        &self,
        installation_id: &str,
    ) -> RuntimeResult<Option<ContactRecord>> {
        self.connection()
            .query_row(CONTACT_BY_INSTALLATION_ID, [installation_id], decode_contact)
            .optional()
            .map_err(storage_error)?
            .transpose()
    }

    pub fn conversation_by_id(
        &self,
        conversation_id: &str,
    ) -> RuntimeResult<Option<ConversationSummary>> {
        self.connection()
            .query_row(CONVERSATION_BY_ID, [conversation_id], decode_conversation)
            .optional()
            .map_err(storage_error)?
            .transpose()
    }

    pub fn conversation_for_contact(
        &self,
        installation_id: &str,
    ) -> RuntimeResult<Option<ConversationSummary>> {
        self.connection()
            .query_row(CONVERSATION_FOR_CONTACT, [installation_id], decode_conversation)
            .optional()
            .map_err(storage_error)?
            .transpose()
    }

    pub fn pairing_inbox_by_id(
        &self,
        pairing_id: &str,
    ) -> RuntimeResult<Option<PairingItem>> {
        self.connection()
            .query_row(PAIRING_INBOX_BY_ID, [pairing_id], decode_pairing_inbox)
            .optional()
            .map_err(storage_error)?
            .transpose()
    }

    pub fn pairing_outbox_by_id(
        &self,
        pairing_id: &str,
    ) -> RuntimeResult<Option<PairingItem>> {
        self.connection()
            .query_row(PAIRING_OUTBOX_BY_ID, [pairing_id], decode_pairing_outbox)
            .optional()
            .map_err(storage_error)?
            .transpose()
    }

    pub fn message_by_id(&self, message_id: &str) -> RuntimeResult<Option<ChatMessage>> {
        self.connection()
            .query_row(MESSAGE_BY_ID, [message_id], decode_message)
            .optional()
            .map_err(storage_error)?
            .transpose()
    }
}

impl PointLookupStorage for ClientDatabase {
    fn contact_by_installation_id(
        &self,
        installation_id: &str,
    ) -> RuntimeResult<Option<ContactRecord>> {
        ClientDatabase::contact_by_installation_id(self, installation_id)
    }

    fn conversation_by_id(&self, id: &str) -> RuntimeResult<Option<ConversationSummary>> {
        ClientDatabase::conversation_by_id(self, id)
    }

    fn conversation_for_contact(
        &self,
        installation_id: &str,
    ) -> RuntimeResult<Option<ConversationSummary>> {
        ClientDatabase::conversation_for_contact(self, installation_id)
    }

    fn pairing_inbox_by_id(&self, pairing_id: &str) -> RuntimeResult<Option<PairingItem>> {
        ClientDatabase::pairing_inbox_by_id(self, pairing_id)
    }

    fn pairing_outbox_by_id(&self, pairing_id: &str) -> RuntimeResult<Option<PairingItem>> {
        ClientDatabase::pairing_outbox_by_id(self, pairing_id)
    }

    fn message_by_id(&self, message_id: &str) -> RuntimeResult<Option<ChatMessage>> {
        ClientDatabase::message_by_id(self, message_id)
    }
}

fn decode_contact(row: &Row<'_>) -> rusqlite::Result<RuntimeResult<ContactRecord>> {
    let installation_id = row.get::<_, String>("installation_id")?;
    let nickname = row.get::<_, String>("nickname")?;
    let verification = row.get::<_, String>("verification")?;
    let transport_policy = row.get::<_, String>("transport_policy")?;
    let has_peer_endpoint = row.get::<_, i64>("has_peer_endpoint")? != 0;
    let has_pending_peer_exchange = row.get::<_, i64>("has_pending_peer_exchange")? != 0;
    let has_recent_peer_connection = row.get::<_, i64>("has_recent_peer_connection")? != 0;
    Ok((|| {
        Ok(ContactRecord {
            nickname: normalized_contact_nickname(&installation_id, &nickname),
            installation_id,
            public_key: row.get("public_key").map_err(storage_error)?,
            fingerprint: row.get("fingerprint").map_err(storage_error)?,
            local_alias: row.get("local_alias").map_err(storage_error)?,
            muted: row.get::<_, i64>("muted").map_err(storage_error)? != 0,
            blocked: row.get::<_, i64>("blocked").map_err(storage_error)? != 0,
            verification: parse_enum::<VerificationState>(&verification)?,
            peer_endpoint_status: if has_peer_endpoint {
                PeerEndpointStatus::Verified
            } else if has_pending_peer_exchange {
                PeerEndpointStatus::PendingExchange
            } else {
                PeerEndpointStatus::Missing
            },
            peer_connection_status: if has_recent_peer_connection {
                PeerConnectionStatus::Connected
            } else {
                PeerConnectionStatus::Offline
            },
            transport_policy: parse_enum::<ContactTransportPolicy>(&transport_policy)?,
            last_peer_connected_at: row.get("last_connected_at").map_err(storage_error)?,
            last_seen_at: row.get("last_seen_at").map_err(storage_error)?,
            dev: None,
        })
    })())
}

fn decode_conversation(row: &Row<'_>) -> rusqlite::Result<RuntimeResult<ConversationSummary>> {
    let state = row.get::<_, String>("state")?;
    Ok((|| {
        Ok(ConversationSummary {
            id: row.get("id").map_err(storage_error)?,
            contact_installation_id: row
                .get("contact_installation_id")
                .map_err(storage_error)?,
            status: parse_enum::<ConversationState>(&state)?,
            last_message_preview: row.get("last_message_preview").map_err(storage_error)?,
            last_message_at: row.get("last_message_at").map_err(storage_error)?,
            unread_count: checked_u32(row.get("unread_count").map_err(storage_error)?)?,
        })
    })())
}

fn decode_pairing_inbox(row: &Row<'_>) -> rusqlite::Result<RuntimeResult<PairingItem>> {
    let state = row.get::<_, String>("state")?;
    let sender_installation_id = row.get::<_, String>("sender_installation_id")?;
    let sender_nickname = row.get::<_, String>("sender_nickname")?;
    Ok((|| {
        let state = parse_enum::<InviteState>(&state)?;
        Ok(PairingItem {
            pairing_id: row.get("pairing_id").map_err(storage_error)?,
            pair_key: row.get("pair_key").map_err(storage_error)?,
            sender: Some(ContactRecord {
                nickname: normalized_contact_nickname(&sender_installation_id, &sender_nickname),
                installation_id: sender_installation_id,
                public_key: row.get("sender_public_key").map_err(storage_error)?,
                fingerprint: row.get("sender_fingerprint").map_err(storage_error)?,
                local_alias: None,
                muted: false,
                blocked: false,
                verification: VerificationState::Unverified,
                peer_endpoint_status: PeerEndpointStatus::Missing,
                peer_connection_status: PeerConnectionStatus::Offline,
                transport_policy: ContactTransportPolicy::default(),
                last_peer_connected_at: None,
                last_seen_at: None,
                dev: None,
            }),
            capability: Some(row.get("capability").map_err(storage_error)?),
            expires_at: row.get("expires_at").map_err(storage_error)?,
            state,
            received: true,
            available_actions: pairing_available_actions(state, true),
            offer_invite_id: row.get("offer_invite_id").map_err(storage_error)?,
            offer_payload: row
                .get::<_, Option<Vec<u8>>>("offer_payload")
                .map_err(storage_error)?
                .map(|value| String::from_utf8_lossy(&value).into_owned()),
        })
    })())
}

fn decode_pairing_outbox(row: &Row<'_>) -> rusqlite::Result<RuntimeResult<PairingItem>> {
    let state = row.get::<_, String>("state")?;
    let recipient = row.get::<_, Option<String>>("recipient_installation_id")?;
    Ok((|| {
        let state = parse_enum::<InviteState>(&state)?;
        Ok(PairingItem {
            pairing_id: row.get("pairing_id").map_err(storage_error)?,
            pair_key: row.get("pair_key").map_err(storage_error)?,
            sender: recipient.map(|installation_id| ContactRecord {
                nickname: fallback_contact_nickname(&installation_id),
                installation_id,
                public_key: String::new(),
                fingerprint: String::new(),
                local_alias: None,
                muted: false,
                blocked: false,
                verification: VerificationState::Unverified,
                peer_endpoint_status: PeerEndpointStatus::Missing,
                peer_connection_status: PeerConnectionStatus::Offline,
                transport_policy: ContactTransportPolicy::default(),
                last_peer_connected_at: None,
                last_seen_at: None,
                dev: None,
            }),
            capability: row.get("capability").map_err(storage_error)?,
            expires_at: row.get("expires_at").map_err(storage_error)?,
            state,
            received: false,
            available_actions: pairing_available_actions(state, false),
            offer_invite_id: None,
            offer_payload: row
                .get::<_, Option<Vec<u8>>>("payload")
                .map_err(storage_error)?
                .map(|value| String::from_utf8_lossy(&value).into_owned()),
        })
    })())
}

fn decode_message(row: &Row<'_>) -> rusqlite::Result<RuntimeResult<ChatMessage>> {
    let state = row.get::<_, String>("state")?;
    let reply = row.get::<_, Option<String>>("reply_to_json")?;
    Ok((|| {
        Ok(ChatMessage {
            id: row.get("id").map_err(storage_error)?,
            conversation_id: row.get("conversation_id").map_err(storage_error)?,
            outgoing: row.get::<_, i64>("outgoing").map_err(storage_error)? != 0,
            body: row.get("body").map_err(storage_error)?,
            reply_to: reply
                .map(|value| serde_json::from_str::<MessageReply>(&value))
                .transpose()
                .map_err(RuntimeError::from)?,
            state: parse_enum::<MessageState>(&state)?,
            created_at: row.get("created_at").map_err(storage_error)?,
            attempt_count: checked_u32(row.get("attempt_count").map_err(storage_error)?)?,
            last_attempt_at: row.get("last_attempt_at").map_err(storage_error)?,
            next_attempt_at: row.get("next_attempt_at").map_err(storage_error)?,
            ack_deadline: row.get("ack_deadline").map_err(storage_error)?,
            last_transport_error: row.get("last_transport_error").map_err(storage_error)?,
        })
    })())
}

fn parse_enum<T: DeserializeOwned>(value: &str) -> RuntimeResult<T> {
    serde_json::from_value(serde_json::Value::String(value.to_owned())).map_err(RuntimeError::from)
}

fn checked_u32(value: i64) -> RuntimeResult<u32> {
    value
        .try_into()
        .map_err(|_| RuntimeError::Storage(format!("value {value} does not fit u32")))
}

fn storage_error(error: rusqlite::Error) -> RuntimeError {
    RuntimeError::Storage(format!("{error:#}"))
}
