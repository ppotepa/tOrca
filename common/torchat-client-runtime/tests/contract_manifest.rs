use serde_json::Value;
use std::collections::BTreeSet;
use torchat_client_runtime::{
    ConversationState, InviteState, MessageState, MessageTransportOutcome, PairingAvailableAction,
    PairingPeerOutcome, RuntimeMethod, RuntimeType,
};

fn manifest() -> Value {
    serde_json::from_str(include_str!("../../client-runtime-contract.json"))
        .expect("contract manifest must parse")
}

fn string_array(value: &Value, key: &str) -> Vec<String> {
    value[key]
        .as_array()
        .unwrap_or_else(|| panic!("manifest key {key} must be an array"))
        .iter()
        .map(|item| {
            item.as_str()
                .expect("manifest item must be a string")
                .to_owned()
        })
        .collect()
}

fn unique(values: &[String]) -> bool {
    values.iter().collect::<BTreeSet<_>>().len() == values.len()
}

fn serialized<T: serde::Serialize>(values: &[T]) -> Vec<String> {
    values
        .iter()
        .map(|value| {
            serde_json::to_value(value)
                .expect("value must serialize")
                .as_str()
                .expect("value must serialize as string")
                .to_owned()
        })
        .collect()
}

#[test]
fn manifest_method_names_match_runtime_serialization() {
    let manifest = manifest();
    let public = string_array(&manifest["methods"], "public");
    let internal = string_array(&manifest["methods"], "internal");

    assert!(unique(&public));
    assert!(unique(&internal));
    assert!(public.iter().all(|method| !internal.contains(method)));

    let mut expected = public;
    expected.extend(internal);

    let actual = serialized(&[
        RuntimeMethod::ApplyRemoteProfile,
        RuntimeMethod::ReportRuntimeError,
        RuntimeMethod::ReportRuntimeLog,
        RuntimeMethod::Connect,
        RuntimeMethod::Identity,
        RuntimeMethod::Profile,
        RuntimeMethod::SetNickname,
        RuntimeMethod::RefreshPairingCode,
        RuntimeMethod::PrepareSubmitPairingCode,
        RuntimeMethod::SubmitPairingCode,
        RuntimeMethod::PairingInbox,
        RuntimeMethod::MergePairingInbox,
        RuntimeMethod::PairingOutbox,
        RuntimeMethod::MergePairingOutbox,
        RuntimeMethod::ArchivePairing,
        RuntimeMethod::VerifyContact,
        RuntimeMethod::Contacts,
        RuntimeMethod::Conversations,
        RuntimeMethod::Messages,
        RuntimeMethod::OpenConversation,
        RuntimeMethod::CloseConversation,
        RuntimeMethod::StartConversation,
        RuntimeMethod::SendMessage,
    ]);

    let expected_set = expected.into_iter().collect::<BTreeSet<_>>();
    let actual_set = actual.into_iter().collect::<BTreeSet<_>>();
    assert_eq!(actual_set, expected_set);
}

#[test]
fn manifest_event_and_enum_names_match_runtime_serialization() {
    let manifest = manifest();
    assert_eq!(
        manifest["protocol"].as_u64(),
        Some(torchat_core::PROTOCOL_VERSION as u64)
    );

    assert_eq!(
        string_array(&manifest, "events"),
        serialized(&[
            RuntimeType::RuntimeReady,
            RuntimeType::TorStatus,
            RuntimeType::ProfileReady,
            RuntimeType::InviteReceived,
            RuntimeType::InviteStateChanged,
            RuntimeType::MessageReceived,
            RuntimeType::MessageStateChanged,
            RuntimeType::ConversationReadChanged,
            RuntimeType::Changed,
            RuntimeType::RuntimeError,
            RuntimeType::RuntimeLog,
        ])
    );
    assert_eq!(
        string_array(&manifest, "messageStates"),
        serialized(&[
            MessageState::Queued,
            MessageState::Sending,
            MessageState::Sent,
            MessageState::Delivered,
            MessageState::Failed,
        ])
    );
    assert_eq!(
        string_array(&manifest, "conversationStates"),
        serialized(&[
            ConversationState::Pending,
            ConversationState::Verifying,
            ConversationState::Active,
            ConversationState::Offline,
            ConversationState::Failed,
        ])
    );
    assert_eq!(
        string_array(&manifest, "inviteStates"),
        serialized(&[
            InviteState::Pending,
            InviteState::Accepted,
            InviteState::Rejected,
            InviteState::Completed,
            InviteState::Expired,
            InviteState::Archived,
            InviteState::Cancelled,
        ])
    );
    assert_eq!(
        string_array(&manifest, "messageTransportOutcomes"),
        serialized(&[
            MessageTransportOutcome::Forwarded,
            MessageTransportOutcome::Delivered,
            MessageTransportOutcome::RecipientOffline,
            MessageTransportOutcome::RetryableFailure,
            MessageTransportOutcome::PermanentFailure,
        ])
    );
    assert_eq!(
        string_array(&manifest, "pairingPeerOutcomes"),
        serialized(&[
            PairingPeerOutcome::OfferReceived,
            PairingPeerOutcome::RejectionReceived,
            PairingPeerOutcome::WelcomePrepared,
        ])
    );
    assert_eq!(
        string_array(&manifest, "pairingAvailableActions"),
        serialized(&[
            PairingAvailableAction::Accept,
            PairingAvailableAction::Reject,
            PairingAvailableAction::Archive,
            PairingAvailableAction::Cancel,
        ])
    );
}
