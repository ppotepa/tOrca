use rusqlite::{Connection, params};

const CONNECTION_PRAGMAS: &str =
    include_str!("../sql/queries/connection_pragmas.sql");

#[test]
fn forwarded_welcome_delete_is_converted_to_scheduled_retry() {
    let connection = Connection::open_in_memory().expect("open sqlite");
    connection
        .execute_batch(CONNECTION_PRAGMAS)
        .expect("install pragmas and retention trigger");

    let now: i64 = connection
        .query_row("SELECT unixepoch();", [], |row| row.get(0))
        .expect("read sqlite clock");
    let expires_at = now + 120;
    connection
        .execute(
            "INSERT INTO pending_welcomes (
                invite_id, recipient_installation_id, payload, expires_at,
                attempt_count, next_attempt_at, last_error
             ) VALUES (?1, ?2, ?3, ?4, 3, 0, 'old error');",
            params!["invite-a", "peer-a", b"welcome".as_slice(), expires_at],
        )
        .expect("insert pending welcome");

    connection
        .execute(
            "DELETE FROM pending_welcomes WHERE invite_id = ?1;",
            ["invite-a"],
        )
        .expect("legacy forwarded delete should be intercepted");

    let retained: (i64, Option<String>) = connection
        .query_row(
            "SELECT next_attempt_at, last_error
             FROM pending_welcomes
             WHERE invite_id = ?1;",
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
    connection
        .execute_batch(CONNECTION_PRAGMAS)
        .expect("install pragmas and retention trigger");

    let now: i64 = connection
        .query_row("SELECT unixepoch();", [], |row| row.get(0))
        .expect("read sqlite clock");
    let scheduled = (now + 40) * 1000;
    connection
        .execute(
            "INSERT INTO pending_welcomes (
                invite_id, recipient_installation_id, payload, expires_at,
                attempt_count, next_attempt_at
             ) VALUES (?1, ?2, ?3, ?4, 4, ?5);",
            params![
                "invite-backoff",
                "peer-a",
                b"welcome".as_slice(),
                now + 120,
                scheduled,
            ],
        )
        .expect("insert scheduled pending welcome");

    connection
        .execute(
            "DELETE FROM pending_welcomes WHERE invite_id = ?1;",
            ["invite-backoff"],
        )
        .expect("legacy forwarded delete should be intercepted");

    let retained: i64 = connection
        .query_row(
            "SELECT next_attempt_at FROM pending_welcomes WHERE invite_id = ?1;",
            ["invite-backoff"],
            |row| row.get(0),
        )
        .expect("scheduled welcome must remain");
    assert_eq!(retained, scheduled);
}

#[test]
fn expired_welcome_can_be_deleted_normally() {
    let connection = Connection::open_in_memory().expect("open sqlite");
    connection
        .execute_batch(CONNECTION_PRAGMAS)
        .expect("install pragmas and retention trigger");

    let now: i64 = connection
        .query_row("SELECT unixepoch();", [], |row| row.get(0))
        .expect("read sqlite clock");
    connection
        .execute(
            "INSERT INTO pending_welcomes (
                invite_id, recipient_installation_id, payload, expires_at
             ) VALUES (?1, ?2, ?3, ?4);",
            params!["invite-expired", "peer-a", b"welcome".as_slice(), now - 1],
        )
        .expect("insert expired pending welcome");

    connection
        .execute(
            "DELETE FROM pending_welcomes WHERE invite_id = ?1;",
            ["invite-expired"],
        )
        .expect("expired delete should proceed");

    let count: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM pending_welcomes WHERE invite_id = ?1;",
            ["invite-expired"],
            |row| row.get(0),
        )
        .expect("count pending welcome");
    assert_eq!(count, 0);
}
