use rusqlite::{Connection, params};

const CANONICAL_SCHEMA: &str = include_str!("../sql/migrations/001_canonical_client.sql");
const INTEGRITY_MIGRATION: &str = include_str!("../sql/migrations/014_runtime_integrity.sql");

fn configure_pragmas(connection: &Connection) {
    connection
        .pragma_update(None, "foreign_keys", true)
        .expect("install foreign keys");
    connection
        .pragma_update(None, "journal_mode", "WAL")
        .expect("install journal mode");
}

#[test]
fn forwarded_welcome_delete_is_converted_to_scheduled_retry() {
    let connection = Connection::open_in_memory().expect("open sqlite");
    configure_pragmas(&connection);
    connection
        .execute_batch(CANONICAL_SCHEMA)
        .and_then(|_| connection.execute_batch(INTEGRITY_MIGRATION))
        .expect("install schema and retention trigger");

    let now: i64 = connection
        .query_row(include_str!("sql/forwarded_welcome_delete_is_converted_to_scheduled_retry/forwarded_welcome_delete_is_converted_to_scheduled_retry_1.sql"), [], |row| row.get(0))
        .expect("read sqlite clock");
    let expires_at = now + 120;
    connection
        .execute(
            include_str!("sql/forwarded_welcome_delete_is_converted_to_scheduled_retry/forwarded_welcome_delete_is_converted_to_scheduled_retry_2.sql"),
            params!["invite-a", "peer-a", b"welcome".as_slice(), expires_at],
        )
        .expect(include_str!("sql/forwarded_welcome_delete_is_converted_to_scheduled_retry/forwarded_welcome_delete_is_converted_to_scheduled_retry_3.sql"));

    connection
        .execute(
            include_str!("sql/forwarded_welcome_delete_is_converted_to_scheduled_retry/forwarded_welcome_delete_is_converted_to_scheduled_retry_4.sql"),
            ["invite-a"],
        )
        .expect("forwarded delete should be intercepted");

    let retained: (i64, Option<String>) = connection
        .query_row(
            include_str!("sql/forwarded_welcome_delete_is_converted_to_scheduled_retry/forwarded_welcome_delete_is_converted_to_scheduled_retry_5.sql"),
            ["invite-a"],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("welcome must remain available for retransmission");
    assert!(retained.0 >= (now + 5) * 1000);
    assert!(retained.0 < expires_at * 1000);
    assert_eq!(retained.1, None);
}

#[test]
fn forwarded_welcome_preserves_scheduler_backoff_deadline() {
    let connection = Connection::open_in_memory().expect("open sqlite");
    configure_pragmas(&connection);
    connection
        .execute_batch(CANONICAL_SCHEMA)
        .and_then(|_| connection.execute_batch(INTEGRITY_MIGRATION))
        .expect("install schema and retention trigger");

    let now: i64 = connection
        .query_row(include_str!("sql/forwarded_welcome_preserves_scheduler_backoff_deadline/forwarded_welcome_preserves_scheduler_backoff_deadline_1.sql"), [], |row| row.get(0))
        .expect("read sqlite clock");
    let scheduled = (now + 40) * 1000;
    connection
        .execute(
            include_str!("sql/forwarded_welcome_preserves_scheduler_backoff_deadline/forwarded_welcome_preserves_scheduler_backoff_deadline_2.sql"),
            params![
                "invite-backoff",
                "peer-a",
                b"welcome".as_slice(),
                now + 120,
                scheduled,
            ],
        )
        .expect(include_str!("sql/forwarded_welcome_preserves_scheduler_backoff_deadline/forwarded_welcome_preserves_scheduler_backoff_deadline_3.sql"));

    connection
        .execute(
            include_str!("sql/forwarded_welcome_preserves_scheduler_backoff_deadline/forwarded_welcome_preserves_scheduler_backoff_deadline_4.sql"),
            ["invite-backoff"],
        )
        .expect("forwarded delete should be intercepted");

    let retained: i64 = connection
        .query_row(
            include_str!("sql/forwarded_welcome_preserves_scheduler_backoff_deadline/forwarded_welcome_preserves_scheduler_backoff_deadline_5.sql"),
            ["invite-backoff"],
            |row| row.get(0),
        )
        .expect("scheduled welcome must remain");
    assert_eq!(retained, scheduled);
}

#[test]
fn expired_welcome_can_be_deleted_normally() {
    let connection = Connection::open_in_memory().expect("open sqlite");
    configure_pragmas(&connection);
    connection
        .execute_batch(CANONICAL_SCHEMA)
        .and_then(|_| connection.execute_batch(INTEGRITY_MIGRATION))
        .expect("install schema and retention trigger");

    let now: i64 = connection
        .query_row(include_str!("sql/expired_welcome_can_be_deleted_normally/expired_welcome_can_be_deleted_normally_1.sql"), [], |row| row.get(0))
        .expect("read sqlite clock");
    connection
        .execute(
            include_str!("sql/expired_welcome_can_be_deleted_normally/expired_welcome_can_be_deleted_normally_2.sql"),
            params!["invite-expired", "peer-a", b"welcome".as_slice(), now - 1],
        )
        .expect(include_str!("sql/expired_welcome_can_be_deleted_normally/expired_welcome_can_be_deleted_normally_3.sql"));

    connection
        .execute(
            include_str!("sql/expired_welcome_can_be_deleted_normally/expired_welcome_can_be_deleted_normally_4.sql"),
            ["invite-expired"],
        )
        .expect("expired delete should proceed");

    let count: i64 = connection
        .query_row(
            include_str!("sql/expired_welcome_can_be_deleted_normally/expired_welcome_can_be_deleted_normally_5.sql"),
            ["invite-expired"],
            |row| row.get(0),
        )
        .expect("count pending welcome");
    assert_eq!(count, 0);
}
