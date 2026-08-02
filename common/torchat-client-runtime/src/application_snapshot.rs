use serde::{Deserialize, Serialize};

use crate::{
    ContactRecord, ConversationSummary, PeerConnectionStatus, PeerEndpointStatus, RuntimeIdentity,
    RuntimeProfile,
};

pub const APPLICATION_SNAPSHOT_SCHEMA_VERSION: u32 = 1;

/// Identifies the durable store and the engine session that produced a
/// projection.  The revision is persisted with the domain mutation, so a
/// client can reject stale responses even when transports deliver events out
/// of order.
#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectionStamp {
    #[serde(default)]
    pub store_id: String,
    #[serde(default)]
    pub engine_session_id: String,
    #[serde(default)]
    pub revision: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApplicationSnapshot {
    pub schema_version: u32,
    pub generation: u64,
    pub created_at_ms: i64,
    pub identity: RuntimeIdentity,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<RuntimeProfile>,
    pub contacts: Vec<ContactRecord>,
    pub conversations: Vec<ConversationSummary>,
    pub pairing_summary: PairingSummary,
    pub peer_endpoint_available: bool,
    pub ui_checkpoint: UiCheckpoint,
    #[serde(default)]
    pub projection: ProjectionStamp,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversationProjection {
    pub projection: ProjectionStamp,
    pub conversation_id: String,
    pub messages: Vec<crate::ChatMessage>,
    #[serde(default)]
    pub has_more: bool,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingSummary {
    pub pending_inbox: u32,
    pub pending_outbox: u32,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UiCheckpoint {
    #[serde(default)]
    pub destination: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected_conversation_id: Option<String>,
}

impl ApplicationSnapshot {
    pub fn normalize(mut self) -> Self {
        self.schema_version = APPLICATION_SNAPSHOT_SCHEMA_VERSION;
        self.contacts.sort_by(|left, right| {
            left.nickname
                .to_lowercase()
                .cmp(&right.nickname.to_lowercase())
                .then(left.installation_id.cmp(&right.installation_id))
        });
        self.conversations.sort_by(|left, right| {
            right
                .last_message_at
                .cmp(&left.last_message_at)
                .then(left.id.cmp(&right.id))
        });
        self
    }

    pub fn direct_session_count(&self) -> usize {
        self.contacts
            .iter()
            .filter(|contact| contact.peer_connection_status == PeerConnectionStatus::Connected)
            .count()
    }

    pub fn verified_endpoint_count(&self) -> usize {
        self.contacts
            .iter()
            .filter(|contact| contact.peer_endpoint_status == PeerEndpointStatus::Verified)
            .count()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ContactTransportPolicy, ConversationState, VerificationState};

    #[test]
    fn snapshot_normalization_is_deterministic() {
        let identity = RuntimeIdentity::from_parts(
            "local".to_owned(),
            "public".to_owned(),
            "fingerprint".to_owned(),
        );
        let snapshot = ApplicationSnapshot {
            schema_version: 0,
            generation: 4,
            created_at_ms: 5,
            identity,
            profile: None,
            contacts: vec![
                ContactRecord {
                    installation_id: "b".to_owned(),
                    nickname: "Zulu".to_owned(),
                    public_key: String::new(),
                    fingerprint: String::new(),
                    local_alias: None,
                    muted: false,
                    blocked: false,
                    verification: VerificationState::Unverified,
                    peer_endpoint_status: PeerEndpointStatus::Missing,
                    peer_connection_status: PeerConnectionStatus::Offline,
                    transport_policy: ContactTransportPolicy::PeerOnly,
                    last_peer_connected_at: None,
                    dev: None,
                },
                ContactRecord {
                    installation_id: "a".to_owned(),
                    nickname: "Alice".to_owned(),
                    public_key: String::new(),
                    fingerprint: String::new(),
                    local_alias: None,
                    muted: false,
                    blocked: false,
                    verification: VerificationState::Verified,
                    peer_endpoint_status: PeerEndpointStatus::Verified,
                    peer_connection_status: PeerConnectionStatus::Connected,
                    transport_policy: ContactTransportPolicy::PeerOnly,
                    last_peer_connected_at: None,
                    dev: None,
                },
            ],
            conversations: vec![
                ConversationSummary {
                    id: "older".to_owned(),
                    contact_installation_id: "b".to_owned(),
                    status: ConversationState::Active,
                    last_message_preview: String::new(),
                    last_message_at: 1,
                    unread_count: 0,
                },
                ConversationSummary {
                    id: "newer".to_owned(),
                    contact_installation_id: "a".to_owned(),
                    status: ConversationState::Active,
                    last_message_preview: String::new(),
                    last_message_at: 2,
                    unread_count: 1,
                },
            ],
            pairing_summary: PairingSummary::default(),
            peer_endpoint_available: true,
            ui_checkpoint: UiCheckpoint::default(),
            projection: ProjectionStamp::default(),
        }
        .normalize();

        assert_eq!(snapshot.schema_version, APPLICATION_SNAPSHOT_SCHEMA_VERSION);
        assert_eq!(snapshot.contacts[0].installation_id, "a");
        assert_eq!(snapshot.conversations[0].id, "newer");
        assert_eq!(snapshot.direct_session_count(), 1);
        assert_eq!(snapshot.verified_endpoint_count(), 1);
    }
}
