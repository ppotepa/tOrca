//! Internal shared client domain runtime used exclusively by `torchat-client-engine`.

pub mod application_snapshot;
pub mod changes;
pub mod clock;
pub mod collections;
pub mod contract;
pub mod error;
pub mod features;
pub mod logic;
pub mod message_rules;
pub mod models;
pub mod retry;
pub mod runtime;
pub mod session;
pub mod storage;
pub mod testing;
pub mod transport;

pub use application_snapshot::{
    APPLICATION_SNAPSHOT_SCHEMA_VERSION, ApplicationSnapshot, ConversationProjection,
    PairingSummary, ProjectionStamp, UiCheckpoint,
};
pub use changes::{
    ChangePublisher, ChangeSections, ChangeSet, ChangedEntities, CommittedChange, DomainEffect,
    FeatureResult,
};
pub use clock::{RuntimeClock, SystemRuntimeClock};
pub use collections::{
    RuntimeMessageLike, RuntimePairingItemLike, runtime_contacts_from_iter,
    runtime_messages_from_iter, runtime_pairing_items_from_iter,
};
pub use contract::{
    RuntimeEvent, RuntimeStatusPhase, RuntimeType, StartupReadinessSnapshot, TransportComponent,
    TransportProbeState,
};
pub use error::{RuntimeError, RuntimeResult};
pub use features::pairing::rules as pairing_rules;
pub use logic::RuntimeConversationUpdate;
pub use logic::{
    contact_card_from_invite, contact_record_from_card, runtime_conversation_summary,
    runtime_conversation_summary_on_incoming, runtime_conversation_summary_on_outgoing,
    runtime_conversation_unread_after_incoming, runtime_conversation_update_on_incoming,
    runtime_conversation_update_on_outgoing, runtime_message, runtime_message_state,
    runtime_pairing_item, runtime_phase_from_str, runtime_status_event,
    runtime_status_event_from_snapshot, runtime_status_snapshot,
};
pub use message_rules::{message_state_after_transport_outcome, message_state_on_send_prepare};
pub use models::{
    CapabilityStatus, ChatMessage, ContactRecord, ContactTransportPolicy, ConversationState,
    ConversationSummary, InviteCode, InviteState, MessageReply, MessageSendEffect, MessageState,
    MessageTransportOutcome, PairingAcknowledgeEffect, PairingAvailableAction, PairingCancelEffect,
    PairingItem, PairingPeerOutcome, PairingPreparation, PairingRelationshipState,
    PairingSendEffect, PairingSendKind, PairingSyncResult, PeerConnectionStatus,
    PeerEndpointStatus, ReceiptSendEffect, RuntimeBootstrap, RuntimeEnvelope, RuntimeFixture,
    RuntimeIdentity, RuntimeProfile, RuntimeSendEffect, RuntimeTorStatus, VerificationState,
    WelcomeAcceptedResult, pairing_available_actions,
};
pub use pairing_rules::{
    PairingAction, RuntimePairingExpiryLike, RuntimePairingIdLike, RuntimePairingStateLike,
    RuntimePairingTransitionError, RuntimePairingTransitionLike, RuntimePairingUuidLike,
    expire_pairing_items, pairing_has_outstanding_request, pairing_items_can_archive,
    pairing_items_contains_id, pairing_items_contains_uuid, pairing_items_transition_after_action,
    pairing_state_after_action, pairing_state_on_accept, pairing_state_on_archive,
    pairing_state_on_cancel, pairing_state_on_reject, pairing_target_state,
    transition_pairing_record,
};
pub use pairing_rules::{expire_pairing_state, pairing_can_archive, pairing_is_active};
pub use runtime::ClientRuntime;
pub use session::RuntimeSession;
pub use storage::{RelationshipTransition, RuntimeStorage};
pub use transport::RuntimeTransport;

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn fixture_models_match_contract() {
        let fixture = crate::models::RuntimeFixture::from_json(include_str!(
            "../../../common/internal-runtime-fixtures.json"
        ))
        .expect("fixture should parse");

        assert_eq!(fixture.profile.nickname, "Alice");
        assert_eq!(fixture.contact.verification, VerificationState::Verified);
        assert_eq!(fixture.conversation.status, ConversationState::Active);
        assert_eq!(fixture.message.state, crate::models::MessageState::Delivered);
        assert_eq!(
            fixture.message_send_effect.recipient_installation_id,
            "installation-bob"
        );
        assert_eq!(fixture.message_transport_outcomes.len(), 3);
        assert_eq!(
            fixture.pairing_preparation.recipient_installation_id,
            "installation-bob"
        );
        assert_eq!(fixture.pairing_send_effects.len(), 2);
        assert_eq!(fixture.pairing_peer_outcomes.len(), 3);
        assert_eq!(fixture.pairing_sync_result.acknowledgements.len(), 1);
        assert_eq!(fixture.pairing_inbox_item.state, InviteState::Pending);
        assert_eq!(fixture.pairing_outbox_item.state, InviteState::Pending);

        let events: Vec<RuntimeEvent> = fixture.events.clone();
        assert!(
            events
                .iter()
                .any(|event| matches!(event, RuntimeEvent::RuntimeReady { protocol: 1 }))
        );
        assert!(events.iter().any(|event| matches!(event, RuntimeEvent::TorStatus { .. })));
    }

    #[test]
    fn canonical_states_reject_noncanonical_aliases() {
        assert!(serde_json::from_str::<crate::models::MessageState>("\"PENDING\"").is_err());
        assert!(serde_json::from_str::<ConversationState>("\"NEW\"").is_err());
    }

    #[test]
    fn fixture_canonical_tor_status_includes_retry_attempt() {
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("../../../common/internal-runtime-fixtures.json"))
                .expect("fixture should parse");

        let retry_attempt = fixture["events"][1]["retryAttempt"]
            .as_i64()
            .expect("retryAttempt should be present");
        assert_eq!(retry_attempt, 0);
    }

    #[test]
    fn runtime_status_snapshot_round_trips_retry_attempt() {
        let snapshot = runtime_status_snapshot(
            "reconnecting",
            "Ponowne łączenie".to_owned(),
            "Brak odpowiedzi relaya".to_owned(),
            Some(85),
            Some(123),
            4,
        );

        assert_eq!(snapshot.retry_attempt, 4);
        match runtime_status_event_from_snapshot(&snapshot) {
            RuntimeEvent::TorStatus {
                retry_attempt,
                phase,
                progress,
                latency_ms,
                ..
            } => {
                assert_eq!(retry_attempt, 4);
                assert_eq!(phase, RuntimeStatusPhase::Reconnecting);
                assert_eq!(progress, Some(85));
                assert_eq!(latency_ms, Some(123));
            }
            other => panic!("expected TorStatus event, got {other:?}"),
        }
    }
}
