use crate::{
    ChatMessage, ContactRecord, ConversationState, ConversationSummary, InviteState, MessageState,
    PairingItem, RuntimeEvent, RuntimeStatusPhase, RuntimeTorStatus, VerificationState,
};
use torchat_core::{ContactInvite, relay::ContactCard};

pub fn runtime_phase_from_str(value: &str) -> RuntimeStatusPhase {
    match value {
        "starting" => RuntimeStatusPhase::Starting,
        "bootstrapping" => RuntimeStatusPhase::Bootstrapping,
        "connecting" | "onion_connecting" => RuntimeStatusPhase::Connecting,
        "degraded" => RuntimeStatusPhase::Degraded,
        "connected" | "api" | "ready" | "external" => RuntimeStatusPhase::Connected,
        "reconnecting" => RuntimeStatusPhase::Reconnecting,
        "offline" => RuntimeStatusPhase::Offline,
        _ => RuntimeStatusPhase::Error,
    }
}

pub fn runtime_status_event(
    phase: &str,
    label: String,
    progress: i32,
    latency_ms: Option<u64>,
) -> RuntimeEvent {
    RuntimeEvent::TorStatus {
        phase: runtime_phase_from_str(phase),
        label,
        detail: String::new(),
        progress: Some(progress),
        latency_ms,
        retry_attempt: 0,
    }
}

pub fn contact_record_from_card(card: &ContactCard, verified: bool) -> ContactRecord {
    ContactRecord {
        installation_id: card.installation_id.clone(),
        nickname: card.nickname.clone(),
        public_key: card.public_key.clone(),
        fingerprint: card.fingerprint.clone(),
        local_alias: None,
        muted: false,
        blocked: false,
        verification: if verified {
            VerificationState::Verified
        } else {
            VerificationState::Unverified
        },
        dev: None,
    }
}

pub fn contact_card_from_invite(invite: &ContactInvite) -> ContactCard {
    ContactCard {
        installation_id: invite.installation_id.clone(),
        public_key: invite.public_key.clone(),
        fingerprint: invite.fingerprint.clone(),
        nickname: invite
            .nickname
            .clone()
            .unwrap_or_else(|| invite.installation_id.clone()),
    }
}

pub fn runtime_message_state(state: &str) -> MessageState {
    match state.to_ascii_uppercase().as_str() {
        "QUEUED" | "PENDING" => MessageState::Queued,
        "SENDING" => MessageState::Sending,
        "SENT" => MessageState::Sent,
        "DELIVERED" => MessageState::Delivered,
        "READ" => MessageState::Read,
        _ => MessageState::Failed,
    }
}

pub fn runtime_conversation_summary(
    id: String,
    contact_installation_id: String,
    active: bool,
    unread_count: u32,
    preview: Option<String>,
    last_message_at: i64,
) -> ConversationSummary {
    ConversationSummary {
        id,
        contact_installation_id,
        status: if active {
            ConversationState::Active
        } else {
            ConversationState::Pending
        },
        last_message_preview: preview.unwrap_or_else(|| "Nowa rozmowa".to_owned()),
        last_message_at,
        unread_count,
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeConversationUpdate {
    pub summary: ConversationSummary,
    pub unread_count: u32,
}

pub fn runtime_conversation_summary_on_outgoing(
    current_unread_count: Option<u32>,
    id: String,
    contact_installation_id: String,
    preview: String,
    last_message_at: i64,
) -> ConversationSummary {
    ConversationSummary {
        id,
        contact_installation_id,
        status: ConversationState::Active,
        last_message_preview: preview,
        last_message_at,
        unread_count: current_unread_count.unwrap_or(0),
    }
}

pub fn runtime_conversation_update_on_outgoing(
    current_unread_count: Option<u32>,
    id: String,
    contact_installation_id: String,
    preview: String,
    last_message_at: i64,
) -> RuntimeConversationUpdate {
    let summary = runtime_conversation_summary_on_outgoing(
        current_unread_count,
        id,
        contact_installation_id,
        preview,
        last_message_at,
    );
    RuntimeConversationUpdate {
        unread_count: summary.unread_count,
        summary,
    }
}

pub fn runtime_conversation_unread_after_incoming(
    current_unread_count: Option<u32>,
    selected: bool,
) -> u32 {
    if selected {
        0
    } else {
        current_unread_count.unwrap_or(0) + 1
    }
}

pub fn runtime_conversation_summary_on_incoming(
    current_unread_count: Option<u32>,
    id: String,
    contact_installation_id: String,
    preview: String,
    last_message_at: i64,
    selected: bool,
) -> ConversationSummary {
    ConversationSummary {
        id,
        contact_installation_id,
        status: ConversationState::Active,
        last_message_preview: preview,
        last_message_at,
        unread_count: runtime_conversation_unread_after_incoming(current_unread_count, selected),
    }
}

pub fn runtime_conversation_update_on_incoming(
    current_unread_count: Option<u32>,
    id: String,
    contact_installation_id: String,
    preview: String,
    last_message_at: i64,
    selected: bool,
) -> RuntimeConversationUpdate {
    let summary = runtime_conversation_summary_on_incoming(
        current_unread_count,
        id,
        contact_installation_id,
        preview,
        last_message_at,
        selected,
    );
    RuntimeConversationUpdate {
        unread_count: summary.unread_count,
        summary,
    }
}

pub fn runtime_pairing_item(
    pairing_id: String,
    sender: Option<ContactRecord>,
    capability: Option<String>,
    expires_at: i64,
    state: InviteState,
    received: bool,
) -> PairingItem {
    PairingItem {
        pairing_id,
        sender,
        capability,
        expires_at,
        state,
        received,
        available_actions: crate::pairing_available_actions(state, received),
        offer_invite_id: None,
        offer_payload: None,
    }
}

pub fn runtime_message(
    id: String,
    conversation_id: String,
    outgoing: bool,
    body: String,
    state: &str,
    created_at: i64,
) -> ChatMessage {
    ChatMessage {
        id,
        conversation_id,
        outgoing,
        body,
        reply_to: None,
        state: runtime_message_state(state),
        created_at,
        attempt_count: 0,
        last_attempt_at: None,
        next_attempt_at: 0,
        ack_deadline: None,
        last_transport_error: None,
    }
}

pub fn runtime_status_snapshot(
    phase: &str,
    label: String,
    detail: String,
    progress: Option<i32>,
    latency_ms: Option<u64>,
    retry_attempt: u32,
) -> RuntimeTorStatus {
    RuntimeTorStatus {
        phase: runtime_phase_from_str(phase),
        label,
        detail,
        progress,
        latency_ms,
        retry_attempt,
    }
}

pub fn runtime_status_event_from_snapshot(status: &RuntimeTorStatus) -> RuntimeEvent {
    RuntimeEvent::TorStatus {
        phase: status.phase.clone(),
        label: status.label.clone(),
        detail: status.detail.clone(),
        progress: status.progress,
        latency_ms: status.latency_ms,
        retry_attempt: status.retry_attempt,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_message_states() {
        assert_eq!(runtime_message_state("PENDING"), MessageState::Queued);
        assert_eq!(runtime_message_state("DELIVERED"), MessageState::Delivered);
    }

    #[test]
    fn terminal_message_state_helper_matches_product_rules() {
        assert!(!MessageState::Queued.is_terminal());
        assert!(MessageState::Delivered.is_terminal());
        assert!(MessageState::Failed.is_terminal());
    }

    #[test]
    fn invite_state_helpers_match_pairing_flow_rules() {
        assert!(InviteState::Pending.is_pending());
        assert!(InviteState::Accepted.is_accepted());
        assert!(InviteState::Accepted.is_outstanding());
        assert!(!InviteState::Rejected.is_outstanding());
        assert!(InviteState::Rejected.is_terminal());
        assert!(InviteState::Archived.is_archived());
        assert!(InviteState::Accepted.can_archive());
        assert!(!InviteState::Pending.can_archive());
    }

    #[test]
    fn updates_conversation_summary_for_incoming_messages() {
        let updated = runtime_conversation_summary_on_incoming(
            Some(3),
            "peer".into(),
            "peer".into(),
            "new".into(),
            20,
            false,
        );

        assert_eq!(updated.status, ConversationState::Active);
        assert_eq!(updated.last_message_preview, "new");
        assert_eq!(updated.last_message_at, 20);
        assert_eq!(updated.unread_count, 4);
    }

    #[test]
    fn updates_conversation_summary_for_selected_incoming_messages() {
        let updated = runtime_conversation_summary_on_incoming(
            None,
            "peer".into(),
            "peer".into(),
            "new".into(),
            20,
            true,
        );

        assert_eq!(updated.unread_count, 0);
        assert_eq!(updated.status, ConversationState::Active);
    }

    #[test]
    fn outgoing_summary_preserves_unread_count() {
        let updated = runtime_conversation_summary_on_outgoing(
            Some(7),
            "peer".into(),
            "peer".into(),
            "sent".into(),
            30,
        );

        assert_eq!(updated.unread_count, 7);
        assert_eq!(updated.status, ConversationState::Active);
    }

    #[test]
    fn outgoing_update_wraps_summary_and_unread_count() {
        let updated = runtime_conversation_update_on_outgoing(
            Some(5),
            "peer".into(),
            "peer".into(),
            "sent".into(),
            30,
        );

        assert_eq!(updated.unread_count, 5);
        assert_eq!(updated.summary.last_message_preview, "sent");
    }

    #[test]
    fn unread_helper_matches_summary_rules() {
        assert_eq!(
            runtime_conversation_unread_after_incoming(Some(2), false),
            3
        );
        assert_eq!(runtime_conversation_unread_after_incoming(None, false), 1);
        assert_eq!(runtime_conversation_unread_after_incoming(Some(4), true), 0);
    }

    #[test]
    fn incoming_update_wraps_summary_and_unread_count() {
        let updated = runtime_conversation_update_on_incoming(
            Some(1),
            "peer".into(),
            "peer".into(),
            "hello".into(),
            9,
            false,
        );

        assert_eq!(updated.unread_count, 2);
        assert_eq!(updated.summary.last_message_preview, "hello");
    }

    #[test]
    fn invite_contact_card_uses_nickname_or_installation_id() {
        let identity = torchat_core::Identity::from_private_key_bytes([7; 32]);
        let invite = ContactInvite::from_identity(
            &identity,
            Some("Alice".into()),
            None,
            "package".into(),
            "00000000-0000-4000-8000-000000000000".into(),
            4_102_444_800,
        );

        let card = contact_card_from_invite(&invite);
        assert_eq!(card.nickname, "Alice");
        let fallback_invite = ContactInvite::from_identity(
            &identity,
            None,
            None,
            "package".into(),
            "00000000-0000-4000-8000-000000000000".into(),
            4_102_444_800,
        );
        let fallback = contact_card_from_invite(&fallback_invite);
        assert_eq!(fallback.nickname, fallback_invite.installation_id);
    }
}
