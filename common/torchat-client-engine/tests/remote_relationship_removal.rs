use std::{fs, path::PathBuf};

use rusqlite::params;
use torchat_client_engine::{
    ClientDatabase, SqliteRuntimeStorage, config::SecretBytes,
    storage::runtime_storage::RelationshipTransition,
};
use torchat_client_runtime::RuntimeStorage;
use uuid::Uuid;

fn temporary_database_path() -> PathBuf {
    std::env::temp_dir().join(format!("torchat-remote-removal-{}.sqlite3", Uuid::new_v4()))
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

#[test]
fn legacy_relationship_marker_is_an_ordinary_message() {
    let path = temporary_database_path();
    let key = SecretBytes(vec![0x37; 32]);

    let database =
        ClientDatabase::open(&path, &key).expect("temporary encrypted database should open");
    let connection = database.connection();
    connection
        .execute(
            include_str!("sql/legacy_relationship_marker_is_an_ordinary_message/legacy_relationship_marker_is_an_ordinary_message_1.sql"),
            params![
                "peer-remote",
                "Remote peer",
                "remote-public-key",
                "remote-fingerprint",
                "VERIFIED",
                "PAIRING"
            ],
        )
        .expect("contact should be inserted");
    connection
        .execute(
            include_str!("sql/legacy_relationship_marker_is_an_ordinary_message/legacy_relationship_marker_is_an_ordinary_message_2.sql"),
            params!["conversation-remote", "peer-remote"],
        )
        .expect("conversation should be inserted");
    connection
        .execute(
            include_str!("sql/legacy_relationship_marker_is_an_ordinary_message/legacy_relationship_marker_is_an_ordinary_message_3.sql"),
            params!["conversation-remote", &[1_u8, 2, 3][..]],
        )
        .expect("MLS snapshot should be inserted");
    connection
        .execute(
            include_str!("sql/legacy_relationship_marker_is_an_ordinary_message/legacy_relationship_marker_is_an_ordinary_message_4.sql"),
            params![
                "ordinary-history",
                "conversation-remote",
                "ordinary message"
            ],
        )
        .expect("ordinary history should be inserted");
    connection
        .execute(
            include_str!("sql/legacy_relationship_marker_is_an_ordinary_message/legacy_relationship_marker_is_an_ordinary_message_5.sql"),
            params!["queued-outgoing", "conversation-remote", "queued message"],
        )
        .expect("outgoing queue fixture should be inserted");

    // A normal message may contain the legacy marker as text. It must not be
    // interpreted as a relationship removal unless the suffix is valid JSON
    // with the removal fields expected by the trigger.
    connection
        .execute(
            include_str!("sql/legacy_relationship_marker_is_an_ordinary_message/legacy_relationship_marker_is_an_ordinary_message_6.sql"),
            params![
                "legacy-marker-ordinary-message",
                "conversation-remote",
                "torchat-relationship-removed-v1:not-a-removal-payload"
            ],
        )
        .expect("legacy marker in ordinary message should be accepted");
    let still_active: i64 = connection
        .query_row(
            include_str!("sql/legacy_relationship_marker_is_an_ordinary_message/legacy_relationship_marker_is_an_ordinary_message_7.sql"),
            ["peer-remote"],
            |row| row.get(0),
        )
        .expect("contact state should remain readable");
    assert_eq!(still_active, 0);

    drop(database);
    remove_database(&path);
}

#[test]
fn local_removal_writes_tombstone_and_typed_outbox_atomically_and_replays_idempotently() {
    let path = temporary_database_path();
    let key = SecretBytes(vec![0x41; 32]);
    let mut database = ClientDatabase::open(&path, &key).expect("database should open");
    database
        .connection()
        .execute(
            include_str!("sql/local_removal_writes_tombstone_and_typed_outbox_atomically_and_replays_idempotently/local_removal_writes_tombstone_and_typed_outbox_atomically_and_replays_idempotently_1.sql"),
            [],
        )
        .expect("contact should be inserted");

    {
        let mut storage = SqliteRuntimeStorage::new(database.transaction().unwrap());
        storage
            .remove_relationship_with_id("peer-local", 100, true, "removal-1", 7)
            .expect("local removal should commit to transaction");
        storage.commit().expect("removal transaction should commit");
    }

    let row: (String, i64) = database
        .connection()
        .query_row(
            include_str!("sql/local_removal_writes_tombstone_and_typed_outbox_atomically_and_replays_idempotently/local_removal_writes_tombstone_and_typed_outbox_atomically_and_replays_idempotently_2.sql"),
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("tombstone should exist");
    assert_eq!(row, ("removal-1".to_owned(), 7));
    let blocked: i64 = database
        .connection()
        .query_row(
            include_str!("sql/local_removal_writes_tombstone_and_typed_outbox_atomically_and_replays_idempotently/local_removal_writes_tombstone_and_typed_outbox_atomically_and_replays_idempotently_3.sql"),
            [],
            |row| row.get(0),
        )
        .expect("contact block state should be readable");
    assert_eq!(blocked, 1);

    let outbox: (String, String, i64) = database
        .connection()
        .query_row(
            include_str!("sql/local_removal_writes_tombstone_and_typed_outbox_atomically_and_replays_idempotently/local_removal_writes_tombstone_and_typed_outbox_atomically_and_replays_idempotently_4.sql"),
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .expect("typed removal outbox should exist");
    assert_eq!(outbox, ("removal-1".to_owned(), "PENDING".to_owned(), 0));

    database
        .mark_relationship_removal_dispatched("removal-1", 200)
        .expect("dispatch state should be durable");
    let dispatched: String = database
        .connection()
        .query_row(
            include_str!("sql/local_removal_writes_tombstone_and_typed_outbox_atomically_and_replays_idempotently/local_removal_writes_tombstone_and_typed_outbox_atomically_and_replays_idempotently_5.sql"),
            [],
            |row| row.get(0),
        )
        .expect("dispatch state should be readable");
    assert_eq!(dispatched, "WAITING_FOR_ACK");
    database
        .complete_relationship_removal_ack("removal-1")
        .expect("ACK should be durable");
    database
        .complete_relationship_removal_ack("removal-1")
        .expect("duplicate ACK should be idempotent");

    for replay in 0..32 {
        let mut storage = SqliteRuntimeStorage::new(database.transaction().unwrap());
        storage
            .remove_relationship_with_id("peer-local", 100 + replay, true, "removal-1", 7)
            .expect("replay should be idempotent");
        storage.commit().expect("replay transaction should commit");
    }
    let count: i64 = database
        .connection()
        .query_row(
            include_str!("sql/local_removal_writes_tombstone_and_typed_outbox_atomically_and_replays_idempotently/local_removal_writes_tombstone_and_typed_outbox_atomically_and_replays_idempotently_6.sql"),
            [],
            |row| row.get(0),
        )
        .expect("outbox count should be readable");
    assert_eq!(count, 1);
    let acknowledged: String = database
        .connection()
        .query_row(
            include_str!("sql/local_removal_writes_tombstone_and_typed_outbox_atomically_and_replays_idempotently/local_removal_writes_tombstone_and_typed_outbox_atomically_and_replays_idempotently_7.sql"),
            [],
            |row| row.get(0),
        )
        .expect("ACK state should be readable");
    assert_eq!(acknowledged, "ACKED");

    drop(database);
    let reopened = ClientDatabase::open(&path, &key).expect("database should reopen");
    let persisted: (i64, String) = reopened
        .connection()
        .query_row(
            include_str!("sql/local_removal_writes_tombstone_and_typed_outbox_atomically_and_replays_idempotently/local_removal_writes_tombstone_and_typed_outbox_atomically_and_replays_idempotently_8.sql"),
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("outbox should survive reopen");
    assert_eq!(persisted, (1, "ACKED".to_owned()));
    remove_database(&path);
}

#[test]
fn fresh_pairing_advances_epoch_beyond_removal_tombstone() {
    let path = temporary_database_path();
    let key = SecretBytes(vec![0x52; 32]);
    let mut database = ClientDatabase::open(&path, &key).expect("database should open");
    database
        .connection()
        .execute(
            include_str!("sql/fresh_pairing_advances_epoch_beyond_removal_tombstone/fresh_pairing_advances_epoch_beyond_removal_tombstone_1.sql"),
            [],
        )
        .expect("contact should be inserted");
    {
        let mut storage = SqliteRuntimeStorage::new(database.transaction().unwrap());
        storage
            .remove_relationship_with_id("peer-repair", 100, true, "removal-repair", 7)
            .expect("removal should be recorded");
        storage.commit().expect("removal should commit");
    }
    {
        let mut storage = SqliteRuntimeStorage::new(database.transaction().unwrap());
        storage
            .begin_verified_relationship("peer-repair", 200)
            .expect("fresh pairing should create a new epoch");
        assert_eq!(
            storage
                .current_relationship_epoch("peer-repair")
                .expect("epoch should be readable"),
            8
        );
        storage.commit().expect("pairing should commit");
    }
    let tombstones: i64 = database
        .connection()
        .query_row(
            include_str!("sql/fresh_pairing_advances_epoch_beyond_removal_tombstone/fresh_pairing_advances_epoch_beyond_removal_tombstone_2.sql"),
            [],
            |row| row.get(0),
        )
        .expect("tombstone count should be readable");
    assert_eq!(tombstones, 0);
    remove_database(&path);
}

#[test]
fn typed_remove_transition_has_atomic_side_effects() {
    let path = temporary_database_path();
    let key = SecretBytes(vec![0x61; 32]);
    let mut database = ClientDatabase::open(&path, &key).expect("database should open");
    database
        .connection()
        .execute(
            include_str!("sql/typed_remove_transition_has_atomic_side_effects/typed_remove_transition_has_atomic_side_effects_1.sql"),
            [],
        )
        .expect("contact should exist");
    database
        .connection()
        .execute(
            include_str!("sql/typed_remove_transition_has_atomic_side_effects/typed_remove_transition_has_atomic_side_effects_2.sql"),
            [],
        )
        .expect("conversation should exist");
    {
        let mut storage = SqliteRuntimeStorage::new(database.transaction().unwrap());
        storage
            .apply_relationship_transition(RelationshipTransition::Remove {
                installation_id: "peer-transition".to_owned(),
                removed_at: 500,
                preserve_history: true,
                removal_id: "removal-transition".to_owned(),
                relationship_epoch: 3,
            })
            .expect("typed remove should commit");
        storage.commit().expect("typed transition should commit");
    }
    let state: (i64, String, i64) = database
        .connection()
        .query_row(
            include_str!("sql/typed_remove_transition_has_atomic_side_effects/typed_remove_transition_has_atomic_side_effects_3.sql"),
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .expect("typed side effects should be readable");
    assert_eq!(state, (1, "PENDING".to_owned(), 3));
    remove_database(&path);
}

#[test]
fn removal_without_history_preserves_tombstone_but_deletes_local_history() {
    let path = temporary_database_path();
    let key = SecretBytes(vec![0x52; 32]);
    let mut database = ClientDatabase::open(&path, &key).expect("database should open");
    database
        .connection()
        .execute(
            include_str!("sql/removal_without_history_preserves_tombstone_but_deletes_local_history/removal_without_history_preserves_tombstone_but_deletes_local_history_1.sql"),
            [],
        )
        .expect("contact should be inserted");
    database
        .connection()
        .execute(
            include_str!("sql/removal_without_history_preserves_tombstone_but_deletes_local_history/removal_without_history_preserves_tombstone_but_deletes_local_history_2.sql"),
            [],
        )
        .expect("conversation should be inserted");
    database
        .connection()
        .execute(
            include_str!("sql/removal_without_history_preserves_tombstone_but_deletes_local_history/removal_without_history_preserves_tombstone_but_deletes_local_history_3.sql"),
            [],
        )
        .expect("message should be inserted");

    {
        let mut storage = SqliteRuntimeStorage::new(database.transaction().unwrap());
        storage
            .remove_relationship_with_id("peer-history", 200, false, "removal-no-history", 3)
            .expect("removal should commit without history");
        storage.commit().expect("removal transaction should commit");
    }

    let message_count: i64 = database
        .connection()
        .query_row(
            include_str!("sql/removal_without_history_preserves_tombstone_but_deletes_local_history/removal_without_history_preserves_tombstone_but_deletes_local_history_4.sql"),
            [],
            |row| row.get(0),
        )
        .expect("message count should be readable");
    assert_eq!(message_count, 0);
    let preserve_history: i64 = database
        .connection()
        .query_row(
            include_str!("sql/removal_without_history_preserves_tombstone_but_deletes_local_history/removal_without_history_preserves_tombstone_but_deletes_local_history_5.sql"),
            [],
            |row| row.get(0),
        )
        .expect("tombstone should be readable");
    assert_eq!(preserve_history, 0);
    let outbox_state: String = database
        .connection()
        .query_row(
            include_str!("sql/removal_without_history_preserves_tombstone_but_deletes_local_history/removal_without_history_preserves_tombstone_but_deletes_local_history_6.sql"),
            [],
            |row| row.get(0),
        )
        .expect("outbox should be readable");
    assert_eq!(outbox_state, "PENDING");
    drop(database);
    remove_database(&path);
}

#[test]
fn stale_relationship_epoch_is_rejected_before_creating_outbox_side_effects() {
    let path = temporary_database_path();
    let key = SecretBytes(vec![0x63; 32]);
    let mut database = ClientDatabase::open(&path, &key).expect("database should open");
    database
        .connection()
        .execute(
            include_str!("sql/stale_relationship_epoch_is_rejected_before_creating_outbox_side_effects/stale_relationship_epoch_is_rejected_before_creating_outbox_side_effects_1.sql"),
            [],
        )
        .expect("contact should be inserted");
    {
        let mut storage = SqliteRuntimeStorage::new(database.transaction().unwrap());
        storage
            .remove_relationship_with_id("peer-epoch", 10, true, "removal-new", 8)
            .unwrap();
        storage.commit().unwrap();
    }
    {
        let mut storage = SqliteRuntimeStorage::new(database.transaction().unwrap());
        storage
            .remove_relationship_with_id("peer-epoch", 20, false, "removal-stale", 7)
            .unwrap();
        storage.commit().unwrap();
    }
    let tombstone: (String, i64, i64) = database
        .connection()
        .query_row(
            include_str!("sql/stale_relationship_epoch_is_rejected_before_creating_outbox_side_effects/stale_relationship_epoch_is_rejected_before_creating_outbox_side_effects_2.sql"),
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    assert_eq!(tombstone, ("removal-new".to_owned(), 8, 1));
    let stale_outbox: i64 = database
        .connection()
        .query_row(
            include_str!("sql/stale_relationship_epoch_is_rejected_before_creating_outbox_side_effects/stale_relationship_epoch_is_rejected_before_creating_outbox_side_effects_3.sql"),
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(stale_outbox, 0);
    drop(database);
    remove_database(&path);
}
