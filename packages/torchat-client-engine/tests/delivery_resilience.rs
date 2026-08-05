use std::{fs, path::PathBuf};

use rusqlite::params;
use torchat_client_engine::{
    ClientDatabase,
    config::SecretBytes,
    storage::{DeliveryReceiptRecord, InboundEnvelopeStoreResult},
};
use torchat_core::{Identity, peer_protocol::PeerMessageEnvelope};
use uuid::Uuid;

fn temporary_database_path(test_name: &str) -> PathBuf {
    std::env::temp_dir().join(format!("torchat-{test_name}-{}.sqlite3", Uuid::new_v4()))
}

fn database_key() -> SecretBytes {
    SecretBytes(vec![0x6b; 32])
}

fn remove_database(path: &std::path::Path) {
    for candidate in [
        path.to_path_buf(),
        PathBuf::from(format!("{}-wal", path.display())),
        PathBuf::from(format!("{}-shm", path.display())),
    ] {
        let _ = fs::remove_file(candidate);
    }
}

fn insert_outbound_fixture(database: &ClientDatabase) {
    let connection = database.connection();
    connection
        .execute(
            include_str!("sql/fixture/fixture_1.sql"),
            params![
                "peer-delivery",
                "Peer",
                "public-key",
                "fingerprint",
                "verified",
                "test"
            ],
        )
        .expect("contact should be stored");
    connection
        .execute(
            include_str!("sql/fixture/fixture_2.sql"),
            params!["peer-delivery", "peer-delivery", "ACTIVE", 0_i64, "", 0_i64],
        )
        .expect("conversation should be stored");
    connection
        .execute(
            include_str!("sql/fixture/fixture_3.sql"),
            params![
                "outbound-message",
                "peer-delivery",
                "durable payload",
                100_i64,
                &[9_u8, 8, 7][..]
            ],
        )
        .expect("outgoing message should be stored");
}

#[test]
fn in_flight_outbound_delivery_requeues_after_database_restart_without_duplication() {
    let path = temporary_database_path("outbound-restart");
    let key = database_key();

    {
        let database = ClientDatabase::open(&path, &key).expect("encrypted database should open");
        insert_outbound_fixture(&database);
        database
            .enqueue_outbound_delivery("outbound-message", "peer-delivery", 7, 100)
            .expect("delivery should be enqueued");
        assert!(
            database
                .claim_outbound_delivery("outbound-message", 50_000, 60_000)
                .expect("delivery should be claimable")
        );

        let claimed = database
            .outbound_delivery("outbound-message")
            .expect("delivery lookup should succeed")
            .expect("delivery should exist");
        assert_eq!(claimed.state, "IN_FLIGHT");
        assert_eq!(claimed.attempt_count, 1);
        assert_eq!(claimed.ack_deadline, Some(60_000));

        database
            .connection()
            .execute(
                include_str!("sql/in_flight_outbound_delivery_requeues_after_database_restart_without_duplication/in_flight_outbound_delivery_requeues_after_database_restart_without_duplication_1.sql"),
                params!["outbound-message", i64::MAX],
            )
            .expect("lease should be extendable");
        assert!(
            !database
                .claim_outbound_delivery("outbound-message", i64::MAX, i64::MAX)
                .expect("active delivery lookup should succeed")
        );
        assert_eq!(
            database
                .outbound_delivery("outbound-message")
                .unwrap()
                .unwrap()
                .attempt_count,
            1
        );
    }

    {
        let database = ClientDatabase::open(&path, &key).expect("encrypted database should reopen");
        database
            .requeue_peer_deliveries(1_000)
            .expect("restart recovery should requeue in-flight deliveries");

        // Re-enqueueing the same public message id is intentionally idempotent.
        database
            .enqueue_outbound_delivery("outbound-message", "peer-delivery", 7, 100)
            .expect("duplicate enqueue should be harmless");

        let due = database
            .due_outbound_deliveries(1_000, 10)
            .expect("due deliveries should be readable");
        assert_eq!(due.len(), 1);
        assert_eq!(due[0].message_id, "outbound-message");
        assert_eq!(due[0].state, "QUEUED");
        assert_eq!(due[0].attempt_count, 1);
        assert_eq!(due[0].next_attempt_at, 1_000);
        assert_eq!(due[0].ack_deadline, None);

        let message_state: String = database
            .connection()
            .query_row(
                include_str!("sql/in_flight_outbound_delivery_requeues_after_database_restart_without_duplication/in_flight_outbound_delivery_requeues_after_database_restart_without_duplication_2.sql"),
                ["outbound-message"],
                |row| row.get(0),
            )
            .expect("message state should be readable");
        assert_eq!(message_state, "QUEUED");
    }

    remove_database(&path);
}

#[test]
fn relay_offline_then_restart_and_forwarded_is_exactly_once() {
    let path = temporary_database_path("relay-offline-restart");
    let key = database_key();

    {
        let database = ClientDatabase::open(&path, &key).expect("encrypted database should open");
        insert_outbound_fixture(&database);
        database
            .enqueue_outbound_delivery("outbound-message", "peer-delivery", 7, 100)
            .expect("relay delivery should be durable");
        database
            .requeue_outbound_delivery("outbound-message", 2_000, "recipient offline")
            .expect("recipient offline should keep delivery queued");
        let queued = database
            .outbound_delivery("outbound-message")
            .expect("queued delivery should be readable")
            .expect("queued delivery should exist");
        assert_eq!(queued.state, "QUEUED");
        assert_eq!(queued.next_attempt_at, 2_000);
    }

    {
        let database = ClientDatabase::open(&path, &key).expect("database should reopen");
        assert_eq!(
            database
                .due_outbound_deliveries(2_000, 10)
                .expect("delivery should be due after restart")
                .len(),
            1
        );
        assert!(
            database
                .claim_outbound_delivery("outbound-message", 2_100, 3_000)
                .expect("forwarded retry should claim once")
        );
        database
            .complete_outbound_delivery("outbound-message")
            .expect("forwarded delivery should complete");
        assert!(
            database
                .outbound_delivery("outbound-message")
                .expect("delivery lookup should succeed")
                .is_none()
        );
        database
            .complete_outbound_delivery("outbound-message")
            .expect("duplicate forwarded event should remain idempotent");
    }

    remove_database(&path);
}

#[test]
fn inbound_peer_envelope_is_idempotent_across_restart_and_rejects_mutation() {
    let path = temporary_database_path("inbound-idempotency");
    let key = database_key();
    let identity = Identity::from_private_key_bytes([0x2c; 32]);
    let session_id = Uuid::new_v4();
    let message_id = Uuid::new_v4();
    let envelope = PeerMessageEnvelope::new(
        &identity,
        session_id,
        message_id,
        "conversation-id",
        1,
        200,
        vec![1, 2, 3, 4],
    );

    {
        let database = ClientDatabase::open(&path, &key).expect("encrypted database should open");
        assert_eq!(
            database
                .store_inbound_peer_envelope(&envelope, 201)
                .expect("first inbound envelope should be stored"),
            InboundEnvelopeStoreResult::Stored
        );
    }

    {
        let database = ClientDatabase::open(&path, &key).expect("encrypted database should reopen");
        assert_eq!(
            database
                .store_inbound_peer_envelope(&envelope, 202)
                .expect("identical replay should be classified"),
            InboundEnvelopeStoreResult::Duplicate { delivered: false }
        );

        let pending = database
            .pending_inbound_peer_envelopes()
            .expect("pending inbound envelopes should be readable");
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].message_id, message_id.to_string());
        assert_eq!(pending[0].ciphertext, vec![1, 2, 3, 4]);

        let mutated = PeerMessageEnvelope::new(
            &identity,
            session_id,
            message_id,
            "conversation-id",
            1,
            200,
            vec![4, 3, 2, 1],
        );
        let error = database
            .store_inbound_peer_envelope(&mutated, 203)
            .expect_err("same message id with different ciphertext must be rejected");
        assert!(
            error.to_string().contains("different ciphertext"),
            "unexpected error: {error}"
        );
    }

    remove_database(&path);
}

#[test]
fn inbound_delivery_receipt_survives_restart_after_message_commit() {
    let path = temporary_database_path("delivery-receipt-restart");
    let key = database_key();
    let message_id = Uuid::new_v4().to_string();
    let receipt = DeliveryReceiptRecord {
        envelope_id: Uuid::new_v4().to_string(),
        message_id: message_id.clone(),
        conversation_id: "peer-receipt".to_owned(),
        original_sender: "peer-receipt".to_owned(),
        received_at: 300,
        wire_ciphertext: None,
        state: "PENDING".to_owned(),
        attempt_count: 0,
        next_attempt_at: 0,
        last_error: None,
        created_at: 300,
    };
    {
        let database = ClientDatabase::open(&path, &key).expect("database should open");
        database
            .put_delivery_receipt(&receipt)
            .expect("receipt should commit with inbound message");
    }
    let reopened = ClientDatabase::open(&path, &key).expect("database should reopen");
    let stored = reopened
        .delivery_receipt(&message_id)
        .expect("receipt lookup should work")
        .expect("pending receipt should survive restart");
    assert_eq!(stored, receipt);
    remove_database(&path);
}
