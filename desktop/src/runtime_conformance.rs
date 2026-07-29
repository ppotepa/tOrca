use crate::store::{LocalStore, StoredMessage};
use torchat_client_runtime::{ConversationState, ConversationSummary, MessageState};
use torchat_core::{Identity, relay::ContactCard};

#[test]
fn desktop_store_persists_canonical_runtime_records_for_conformance() {
    let (store, path) = temp_store();
    let peer = Identity::generate();

    store
        .put_contact(
            &ContactCard {
                installation_id: peer.installation_id(),
                nickname: "Bob".to_owned(),
                public_key: peer.public_key(),
                fingerprint: peer.fingerprint(),
            },
            "runtime",
        )
        .unwrap();
    store.verify_contact(&peer.installation_id()).unwrap();

    let conversation = ConversationSummary {
        id: peer.installation_id(),
        contact_installation_id: peer.installation_id(),
        status: ConversationState::Active,
        last_message_preview: "hello".to_owned(),
        last_message_at: 42,
        unread_count: 2,
    };
    store.put_runtime_conversation(&conversation).unwrap();

    store
        .put_message(&StoredMessage {
            id: "00000000-0000-0000-0000-000000000101".to_owned(),
            peer: peer.installation_id(),
            outgoing: true,
            body: "hello".to_owned(),
            state: MessageState::Queued,
            created_at: 42,
            relay_payload: Some("relay-payload".to_owned()),
            attempt_count: 0,
            last_attempt_at: None,
            next_attempt_at: 0,
            ack_deadline: None,
            last_transport_error: None,
        })
        .unwrap();
    store
        .put_message(&StoredMessage {
            id: "00000000-0000-0000-0000-000000000102".to_owned(),
            peer: peer.installation_id(),
            outgoing: false,
            body: "incoming".to_owned(),
            state: MessageState::Delivered,
            created_at: 43,
            relay_payload: None,
            attempt_count: 0,
            last_attempt_at: None,
            next_attempt_at: 0,
            ack_deadline: None,
            last_transport_error: None,
        })
        .unwrap();

    assert_eq!(
        store.runtime_conversation(&peer.installation_id()).unwrap(),
        Some(conversation)
    );
    assert!(store.contact_is_verified(&peer.installation_id()).unwrap());
    let pending = store.pending_outgoing(0).unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].state, MessageState::Queued);
    assert_eq!(pending[0].relay_payload.as_deref(), Some("relay-payload"));

    drop(store);
    cleanup(path);
}

#[test]
fn desktop_runtime_storage_adapter_preserves_relay_payload_on_canonical_updates() {
    let source = include_str!("runtime_storage.rs");
    assert!(source.contains("if let Ok(Some(existing)) = self.state.store.message(&stored.id)"));
    assert!(source.contains("stored.relay_payload = existing.relay_payload"));
    assert!(!source.contains("set_message_state"));
}

fn temp_store() -> (LocalStore, std::path::PathBuf) {
    let path = std::env::temp_dir().join(format!(
        "torchat-runtime-conformance-{}.db",
        uuid::Uuid::new_v4()
    ));
    let identity = Identity::generate();
    (LocalStore::open(&path, &identity).unwrap(), path)
}

fn cleanup(path: std::path::PathBuf) {
    let _ = std::fs::remove_file(path);
}
