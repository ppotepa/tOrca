use std::{fs, path::PathBuf};

use rusqlite::{OptionalExtension, params};
use torchat_client_engine::{ClientDatabase, config::SecretBytes, storage::sqlite::MIGRATIONS};
use uuid::Uuid;

fn temporary_database_path(test_name: &str) -> PathBuf {
    std::env::temp_dir().join(format!("torchat-{test_name}-{}.sqlite3", Uuid::new_v4()))
}

fn database_key() -> SecretBytes {
    SecretBytes(vec![0x5a; 32])
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

fn insert_contact_and_conversation(database: &ClientDatabase) {
    let connection = database.connection();
    connection
        .execute(
            include_str!("sql/fixture/fixture_1.sql"),
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
            include_str!("sql/fixture/fixture_2.sql"),
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
}

#[test]
fn fresh_database_applies_every_registered_migration() {
    let path = temporary_database_path("fresh-migrations");
    let expected_version = MIGRATIONS
        .iter()
        .map(|migration| migration.version)
        .max()
        .expect("at least one migration");

    let database =
        ClientDatabase::open(&path, &database_key()).expect("fresh encrypted database should open");
    let applied_version: i64 = database
        .connection()
        .query_row(include_str!("sql/fresh_database_applies_every_registered_migration/fresh_database_applies_every_registered_migration_1.sql"), [], |row| {
            row.get(0)
        })
        .expect("migration version should be readable");
    let applied_count: i64 = database
        .connection()
        .query_row(include_str!("sql/fresh_database_applies_every_registered_migration/fresh_database_applies_every_registered_migration_2.sql"), [], |row| {
            row.get(0)
        })
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
        insert_contact_and_conversation(&database);
        let connection = database.connection();
        connection
            .execute(
                include_str!("sql/reopening_database_preserves_client_state_across_migrations/reopening_database_preserves_client_state_across_migrations_1.sql"),
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
                include_str!("sql/reopening_database_preserves_client_state_across_migrations/reopening_database_preserves_client_state_across_migrations_2.sql"),
                params!["test.setting", &b"preserved-value"[..]],
            )
            .expect("setting fixture should be stored");
    }

    {
        let database = ClientDatabase::open(&path, &key)
            .expect("existing encrypted database should reopen after migrations");
        let connection = database.connection();

        let contact: (String, String) = connection
            .query_row(
                include_str!("sql/reopening_database_preserves_client_state_across_migrations/reopening_database_preserves_client_state_across_migrations_3.sql"),
                ["peer-installation"],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("contact should survive database reopen");
        assert_eq!(contact, ("Peer nickname".to_owned(), "VERIFIED".to_owned()));

        let conversation: (i64, String) = connection
            .query_row(
                include_str!("sql/reopening_database_preserves_client_state_across_migrations/reopening_database_preserves_client_state_across_migrations_4.sql"),
                ["conversation-1"],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("conversation should survive database reopen");
        assert_eq!(conversation, (3, "preserved preview".to_owned()));

        let message: (String, String, i64) = connection
            .query_row(
                include_str!("sql/reopening_database_preserves_client_state_across_migrations/reopening_database_preserves_client_state_across_migrations_5.sql"),
                ["message-1"],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("message should survive database reopen");
        assert_eq!(
            message,
            (
                "preserved local message".to_owned(),
                "DELIVERED".to_owned(),
                2
            )
        );

        let setting: Vec<u8> = connection
            .query_row(
                include_str!("sql/reopening_database_preserves_client_state_across_migrations/reopening_database_preserves_client_state_across_migrations_6.sql"),
                ["test.setting"],
                |row| row.get(0),
            )
            .expect("setting should survive database reopen");
        assert_eq!(setting, b"preserved-value");

        let applied_version: i64 = connection
            .query_row(include_str!("sql/reopening_database_preserves_client_state_across_migrations/reopening_database_preserves_client_state_across_migrations_7.sql"), [], |row| {
                row.get(0)
            })
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

#[test]
fn message_state_timestamps_are_durable_monotonic_and_cascaded() {
    let path = temporary_database_path("message-state-timestamps");
    let key = database_key();

    let recorded = {
        let database = ClientDatabase::open(&path, &key)
            .expect("encrypted database should open for timestamp test");
        insert_contact_and_conversation(&database);
        let connection = database.connection();
        connection
            .execute(
                include_str!("sql/message_state_timestamps_are_durable_monotonic_and_cascaded/message_state_timestamps_are_durable_monotonic_and_cascaded_1.sql"),
                params![
                    "message-timestamps",
                    "conversation-1",
                    1_i64,
                    "timestamped message",
                    "QUEUED",
                    1_725_000_000_000_i64,
                    0_i64,
                    0_i64
                ],
            )
            .expect("queued message should be stored");

        let empty: Option<(Option<i64>, Option<i64>, Option<i64>)> = connection
            .query_row(
                include_str!("sql/message_state_timestamps_are_durable_monotonic_and_cascaded/message_state_timestamps_are_durable_monotonic_and_cascaded_2.sql"),
                ["message-timestamps"],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()
            .expect("timestamp lookup should succeed");
        assert!(
            empty.is_none(),
            "queued messages must not have delivery timestamps"
        );

        connection
            .execute(
                include_str!("sql/message_state_timestamps_are_durable_monotonic_and_cascaded/message_state_timestamps_are_durable_monotonic_and_cascaded_3.sql"),
                ["message-timestamps"],
            )
            .expect("sent transition should be stored");
        let sent: (Option<i64>, Option<i64>, Option<i64>) = connection
            .query_row(
                include_str!("sql/message_state_timestamps_are_durable_monotonic_and_cascaded/message_state_timestamps_are_durable_monotonic_and_cascaded_4.sql"),
                ["message-timestamps"],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("sent timestamp should be stored");
        let sent_at = sent.0.expect("sent_at must be recorded");
        assert!(sent.1.is_none());
        assert!(sent.2.is_none());

        connection
            .execute(
                include_str!("sql/message_state_timestamps_are_durable_monotonic_and_cascaded/message_state_timestamps_are_durable_monotonic_and_cascaded_5.sql"),
                ["message-timestamps"],
            )
            .expect("delivered transition should be stored");
        let delivered: (Option<i64>, Option<i64>, Option<i64>) = connection
            .query_row(
                include_str!("sql/message_state_timestamps_are_durable_monotonic_and_cascaded/message_state_timestamps_are_durable_monotonic_and_cascaded_6.sql"),
                ["message-timestamps"],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("delivered timestamps should be stored");
        let delivered_at = delivered.1.expect("delivered_at must be recorded");
        assert_eq!(delivered.0, Some(sent_at));
        assert!(delivered_at >= sent_at);
        assert!(delivered.2.is_none());

        connection
            .execute(
                include_str!("sql/message_state_timestamps_are_durable_monotonic_and_cascaded/message_state_timestamps_are_durable_monotonic_and_cascaded_7.sql"),
                ["message-timestamps"],
            )
            .expect("read transition should be stored");
        let read: (Option<i64>, Option<i64>, Option<i64>) = connection
            .query_row(
                include_str!("sql/message_state_timestamps_are_durable_monotonic_and_cascaded/message_state_timestamps_are_durable_monotonic_and_cascaded_8.sql"),
                ["message-timestamps"],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("read timestamps should be stored");
        let read_at = read.2.expect("read_at must be recorded");
        assert_eq!(read.0, Some(sent_at));
        assert_eq!(read.1, Some(delivered_at));
        assert!(read_at >= delivered_at);
        (sent_at, delivered_at, read_at)
    };

    {
        let database = ClientDatabase::open(&path, &key)
            .expect("encrypted database should reopen with timestamp state");
        let connection = database.connection();
        let persisted: (i64, i64, i64) = connection
            .query_row(
                include_str!("sql/message_state_timestamps_are_durable_monotonic_and_cascaded/message_state_timestamps_are_durable_monotonic_and_cascaded_9.sql"),
                ["message-timestamps"],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("timestamps should survive reopen");
        assert_eq!(persisted, recorded);

        let projected: (String, i64, i64, i64) = connection
            .query_row(
                include_str!("sql/message_state_timestamps_are_durable_monotonic_and_cascaded/message_state_timestamps_are_durable_monotonic_and_cascaded_10.sql"),
                ["message-timestamps"],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .expect("timestamp projection should expose message state");
        assert_eq!(
            projected,
            ("READ".to_owned(), recorded.0, recorded.1, recorded.2)
        );

        connection
            .execute(
                include_str!("sql/message_state_timestamps_are_durable_monotonic_and_cascaded/message_state_timestamps_are_durable_monotonic_and_cascaded_11.sql"),
                ["message-timestamps"],
            )
            .expect("message deletion should succeed");
        let remaining: i64 = connection
            .query_row(
                include_str!("sql/message_state_timestamps_are_durable_monotonic_and_cascaded/message_state_timestamps_are_durable_monotonic_and_cascaded_12.sql"),
                ["message-timestamps"],
                |row| row.get(0),
            )
            .expect("timestamp row count should be readable");
        assert_eq!(remaining, 0, "timestamp row must follow message deletion");
    }

    remove_database(&path);
}
