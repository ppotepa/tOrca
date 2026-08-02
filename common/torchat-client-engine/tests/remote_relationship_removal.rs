use std::{fs, path::PathBuf, thread, time::Duration};

use rusqlite::params;
use torchat_client_engine::{ClientDatabase, config::SecretBytes};
use uuid::Uuid;

const REMOVAL_PREFIX: &str = "torchat-relationship-removed-v1:";

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

fn iso_now(connection: &rusqlite::Connection) -> String {
    connection
        .query_row("SELECT strftime('%Y-%m-%dT%H:%M:%fZ', 'now');", [], |row| {
            row.get(0)
        })
        .expect("SQLite should format a UTC relationship timestamp")
}

fn removal_body(removed_at: &str, preserve_history: bool) -> String {
    format!(
        "{REMOVAL_PREFIX}{{\"removedAt\":\"{removed_at}\",\"preserveHistory\":{preserve_history}}}"
    )
}

#[test]
fn incoming_removal_is_atomic_and_stale_replay_cannot_remove_fresh_relationship() {
    let path = temporary_database_path();
    let key = SecretBytes(vec![0x37; 32]);

    let database =
        ClientDatabase::open(&path, &key).expect("temporary encrypted database should open");
    let connection = database.connection();
    connection
        .execute(
            "INSERT INTO contacts (
                installation_id, nickname, public_key, fingerprint,
                verification, source
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6);",
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
            "INSERT INTO conversations (
                id, contact_installation_id, state, unread_count,
                last_message_preview, last_message_at
             ) VALUES (?1, ?2, 'ACTIVE', 0, NULL, NULL);",
            params!["conversation-remote", "peer-remote"],
        )
        .expect("conversation should be inserted");
    connection
        .execute(
            "INSERT INTO conversation_mls (conversation_id, snapshot)
             VALUES (?1, ?2);",
            params!["conversation-remote", &[1_u8, 2, 3][..]],
        )
        .expect("MLS snapshot should be inserted");
    connection
        .execute(
            "INSERT INTO messages (
                id, conversation_id, outgoing, body, state, created_at,
                attempt_count, next_attempt_at
             ) VALUES (?1, ?2, 0, ?3, 'DELIVERED', 1, 0, 0);",
            params![
                "ordinary-history",
                "conversation-remote",
                "ordinary message"
            ],
        )
        .expect("ordinary history should be inserted");
    connection
        .execute(
            "INSERT INTO messages (
                id, conversation_id, outgoing, body, state, created_at,
                attempt_count, next_attempt_at
             ) VALUES (?1, ?2, 1, ?3, 'QUEUED', 2, 0, 0);",
            params!["queued-outgoing", "conversation-remote", "queued message"],
        )
        .expect("outgoing queue fixture should be inserted");

    // Ensure the removal timestamp is newer than the relationship boundary
    // recorded by the contact INSERT trigger.
    thread::sleep(Duration::from_millis(15));
    let removed_at = iso_now(connection);
    let removal = removal_body(&removed_at, false);
    connection
        .execute(
            "INSERT INTO messages (
                id, conversation_id, outgoing, body, state, created_at,
                attempt_count, next_attempt_at
             ) VALUES (?1, ?2, 0, ?3, 'DELIVERED', 3, 0, 0);",
            params!["remote-removal", "conversation-remote", removal],
        )
        .expect("remote removal message should be accepted");

    let blocked: i64 = connection
        .query_row(
            "SELECT blocked FROM contacts WHERE installation_id = ?1;",
            ["peer-remote"],
            |row| row.get(0),
        )
        .expect("blocked state should be readable");
    assert_eq!(blocked, 1);

    let offline: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM conversations
             WHERE id = ?1 AND state = 'OFFLINE';",
            ["conversation-remote"],
            |row| row.get(0),
        )
        .expect("conversation state should be readable");
    assert_eq!(offline, 1);

    let tombstone: (i64, i64) = connection
        .query_row(
            "SELECT removed_at, preserve_history
             FROM relationship_tombstones
             WHERE contact_installation_id = ?1;",
            ["peer-remote"],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("remote tombstone should be stored");
    assert_eq!(tombstone.1, 0);

    let remaining_messages: Vec<String> = {
        let mut statement = connection
            .prepare("SELECT id FROM messages ORDER BY id;")
            .expect("message query should prepare");
        statement
            .query_map([], |row| row.get(0))
            .expect("message query should execute")
            .collect::<Result<Vec<_>, _>>()
            .expect("message ids should decode")
    };
    assert_eq!(remaining_messages, vec!["remote-removal".to_owned()]);

    let mls_count: i64 = connection
        .query_row("SELECT COUNT(*) FROM conversation_mls;", [], |row| {
            row.get(0)
        })
        .expect("MLS row count should be readable");
    assert_eq!(mls_count, 0);

    let recreated = connection
        .execute(
            "INSERT INTO conversation_mls (conversation_id, snapshot)
             VALUES (?1, ?2);",
            params!["conversation-remote", &[4_u8, 5, 6][..]],
        )
        .expect("suppressed MLS insertion should not fail the transaction");
    assert_eq!(
        recreated, 0,
        "tombstoned relationship must not restore MLS state"
    );

    // A successful fresh pairing clears the tombstone and records a newer
    // boundary through the blocked -> unblocked contact transition.
    thread::sleep(Duration::from_millis(15));
    database
        .connection()
        .execute(
            "UPDATE contacts SET blocked = 0 WHERE installation_id = ?1;",
            ["peer-remote"],
        )
        .expect("fresh pairing should clear the previous tombstone");
    database
        .connection()
        .execute(
            "DELETE FROM relationship_tombstones WHERE contact_installation_id = ?1;",
            ["peer-remote"],
        )
        .expect("fresh pairing should clear the previous tombstone");

    let unblocked: i64 = database
        .connection()
        .query_row(
            "SELECT blocked FROM contacts WHERE installation_id = ?1;",
            ["peer-remote"],
            |row| row.get(0),
        )
        .expect("fresh contact state should be readable");
    assert_eq!(unblocked, 0);

    let stale_replay = removal_body(&removed_at, true);
    let inserted = database
        .connection()
        .execute(
            "INSERT INTO messages (
                id, conversation_id, outgoing, body, state, created_at,
                attempt_count, next_attempt_at
             ) VALUES (?1, ?2, 0, ?3, 'DELIVERED', 4, 0, 0);",
            params!["stale-removal-replay", "conversation-remote", stale_replay],
        )
        .expect("stale replay should be consumed without an SQL error");
    assert_eq!(inserted, 0, "stale removal message should be ignored");

    let still_unblocked: i64 = database
        .connection()
        .query_row(
            "SELECT blocked FROM contacts WHERE installation_id = ?1;",
            ["peer-remote"],
            |row| row.get(0),
        )
        .expect("contact state should remain readable");
    assert_eq!(still_unblocked, 0);
    drop(database);
    remove_database(&path);
}
