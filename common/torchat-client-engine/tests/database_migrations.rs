use std::{fs, path::PathBuf};

use rusqlite::params;
use torchat_client_engine::{
    ClientDatabase,
    config::SecretBytes,
    storage::sqlite::MIGRATIONS,
};
use uuid::Uuid;

fn temporary_database_path(test_name: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "torchat-{test_name}-{}.sqlite3",
        Uuid::new_v4()
    ))
}

fn database_key() -> SecretBytes {
    SecretBytes(vec![0x5a; 32])
}

fn remove_database(path: &PathBuf) {
    for candidate in [
        path.clone(),
        PathBuf::from(format!("{}-wal", path.display())),
        PathBuf::from(format!("{}-shm", path.display())),
    ] {
        let _ = fs::remove_file(candidate);
    }
}

#[test]
fn fresh_database_applies_every_registered_migration() {
    let path = temporary_database_path("fresh-migrations");
    let expected_version = MIGRATIONS
        .iter()
        .map(|migration| migration.version)
        .max()
        .expect("at least one migration");

    let database = ClientDatabase::open(&path, &database_key())
        .expect("fresh encrypted database should open");
    let applied_version: i64 = database
        .connection()
        .query_row("SELECT MAX(version) FROM schema_migrations;", [], |row| row.get(0))
        .expect("migration version should be readable");
    let applied_count: i64 = database
        .connection()
        .query_row("SELECT COUNT(*) FROM schema_migrations;", [], |row| row.get(0))
        .expect("migration count should be readable");

    assert_eq!(applied_version, expected_version);
    assert_eq!(applied_count as usize, MIGRATIONS.len());

    drop(database);
    remove_database(&path);
}

#[test]
fn reopening_database_preserves_client_state_across_migrations() {
    let path = temporary_database_path("migration-preservation");
    let key = database_key();

    {
        let database = ClientDatabase::open(&path, &key)
            .expect("encrypted database should open for initial write");
        let connection = database.connection();
        connection
            .execute(
                "INSERT INTO contacts (
                    installation_id, nickname, public_key, fingerprint,
                    verification, source
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6);",
                params![
                    "peer-installation",
                    "Peer nickname",
                    "peer-public-key",
                    "peer-fingerprint",
                    "VERIFIED",
                    "PAIRING"
                ],
            )
            .expect("contact fixture should be stored");
        connection
            .execute(
                "INSERT INTO conversations (
                    id, contact_installation_id, state, unread_count,
                    last_message_preview, last_message_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6);",
                params![
                    "conversation-1",
                    "peer-installation",
                    "ACTIVE",
                    3_i64,
                    "preserved preview",
                    1_725_000_000_000_i64
                ],
            )
            .expect("conversation fixture should be stored");
        connection
            .execute(
                "INSERT INTO messages (
                    id, conversation_id, outgoing, body, state, created_at,
                    attempt_count, next_attempt_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);",
                params![
                    "message-1",
                    "conversation-1",
                    1_i64,
                    "preserved local message",
                    "DELIVERED",
                    1_725_000_000_000_i64,
                    2_i64,
                    0_i64
                ],
            )
            .expect("message fixture should be stored");
        connection
            .execute(
                "INSERT INTO settings (key, value) VALUES (?1, ?2);",
                params!["test.setting", b"preserved-value".as_slice()],
            )
            .expect("setting fixture should be stored");
    }

    {
        let database = ClientDatabase::open(&path, &key)
            .expect("existing encrypted database should reopen after migrations");
        let connection = database.connection();

        let contact: (String, String) = connection
            .query_row(
                "SELECT nickname, verification FROM contacts WHERE installation_id = ?1;",
                ["peer-installation"],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("contact should survive database reopen");
        assert_eq!(contact, ("Peer nickname".to_owned(), "VERIFIED".to_owned()));

        let conversation: (i64, String) = connection
            .query_row(
                "SELECT unread_count, last_message_preview FROM conversations WHERE id = ?1;",
                ["conversation-1"],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("conversation should survive database reopen");
        assert_eq!(conversation, (3, "preserved preview".to_owned()));

        let message: (String, String, i64) = connection
            .query_row(
                "SELECT body, state, attempt_count FROM messages WHERE id = ?1;",
                ["message-1"],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("message should survive database reopen");
        assert_eq!(
            message,
            ("preserved local message".to_owned(), "DELIVERED".to_owned(), 2)
        );

        let setting: Vec<u8> = connection
            .query_row(
                "SELECT value FROM settings WHERE key = ?1;",
                ["test.setting"],
                |row| row.get(0),
            )
            .expect("setting should survive database reopen");
        assert_eq!(setting, b"preserved-value");

        let applied_version: i64 = connection
            .query_row("SELECT MAX(version) FROM schema_migrations;", [], |row| row.get(0))
            .expect("latest migration version should remain recorded");
        assert_eq!(
            applied_version,
            MIGRATIONS
                .iter()
                .map(|migration| migration.version)
                .max()
                .expect("at least one migration")
        );
    }

    remove_database(&path);
}
