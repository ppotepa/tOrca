use std::{fs, path::PathBuf};

use rusqlite::params;
use torchat_client_engine::{ClientDatabase, config::SecretBytes};
use uuid::Uuid;

fn temporary_database_path() -> PathBuf {
    std::env::temp_dir().join(format!(
        "torchat-pairing-recovery-{}.sqlite3",
        Uuid::new_v4()
    ))
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
fn accepted_pairing_response_and_acknowledgement_survive_restart_idempotently() {
    let path = temporary_database_path();
    let key = SecretBytes(vec![0x74; 32]);
    let pairing_id = "pairing-recovery";
    let expires_at = 4_000_000_000_i64;

    {
        let database = ClientDatabase::open(&path, &key).expect("encrypted database should open");
        database
            .connection()
            .execute(
                include_str!("sql/accepted_pairing_response_and_acknowledgement_survive_restart_idempotently/accepted_pairing_response_and_acknowledgement_survive_restart_idempotently_1.sql"),
                params![
                    pairing_id,
                    "peer-pairing",
                    "Pairing peer",
                    "peer-public-key",
                    "peer-fingerprint",
                    "pairing-capability",
                    expires_at,
                    "offer-invite-id",
                    b"durable-offer-payload".as_slice(),
                ],
            )
            .expect("accepted pairing response should be stored");

        database
            .put_pending_pairing_acknowledgement(pairing_id, None)
            .expect("pairing acknowledgement should be stored");
        database
            .put_pending_pairing_acknowledgement(pairing_id, Some("retry after reconnect"))
            .expect("duplicate acknowledgement insert should update one record");

        assert!(
            database
                .claim_pairing_response_attempt(
                    pairing_id,
                    25_000,
                    Some("relay temporarily unavailable"),
                )
                .expect("pairing response should be claimable")
        );
        assert!(
            database
                .claim_pending_pairing_acknowledgement_attempt(
                    pairing_id,
                    30_000,
                    Some("ack relay unavailable"),
                )
                .expect("pairing acknowledgement should be claimable")
        );
    }

    {
        let database = ClientDatabase::open(&path, &key).expect("encrypted database should reopen");
        let response = database
            .pairing_response_retry_record(pairing_id, 1)
            .expect("pairing retry lookup should succeed")
            .expect("accepted response should remain pending");
        assert_eq!(response.pairing_id, pairing_id);
        assert_eq!(response.recipient_installation_id, "peer-pairing");
        assert_eq!(response.state, "ACCEPTED");
        assert_eq!(
            response.offer_payload,
            Some(b"durable-offer-payload".to_vec())
        );
        assert_eq!(response.attempt_count, 1);
        assert_eq!(response.next_attempt_at, 25_000);
        assert_eq!(
            response.last_error.as_deref(),
            Some("relay temporarily unavailable")
        );
        assert_eq!(response.expires_at, expires_at);

        let ack_count: i64 = database
            .connection()
            .query_row(
                include_str!("sql/accepted_pairing_response_and_acknowledgement_survive_restart_idempotently/accepted_pairing_response_and_acknowledgement_survive_restart_idempotently_2.sql"),
                [pairing_id],
                |row| row.get(0),
            )
            .expect("acknowledgement count should be readable");
        assert_eq!(ack_count, 1, "pairing acknowledgement must be deduplicated");

        let ack: (i64, i64, Option<String>) = database
            .connection()
            .query_row(
                include_str!("sql/accepted_pairing_response_and_acknowledgement_survive_restart_idempotently/accepted_pairing_response_and_acknowledgement_survive_restart_idempotently_3.sql"),
                [pairing_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("acknowledgement retry state should survive restart");
        assert_eq!(ack.0, 1);
        assert_eq!(ack.1, 30_000);
        assert_eq!(ack.2.as_deref(), Some("ack relay unavailable"));

        database
            .complete_pairing_response(pairing_id)
            .expect("pairing response should complete atomically");
        assert!(
            database
                .pairing_response_retry_record(pairing_id, 1)
                .expect("completed pairing lookup should succeed")
                .is_none()
        );

        database
            .complete_pending_pairing_acknowledgement(pairing_id)
            .expect("pairing acknowledgement should complete atomically");
        let remaining: i64 = database
            .connection()
            .query_row(
                include_str!("sql/accepted_pairing_response_and_acknowledgement_survive_restart_idempotently/accepted_pairing_response_and_acknowledgement_survive_restart_idempotently_4.sql"),
                [pairing_id],
                |row| row.get(0),
            )
            .expect("remaining acknowledgement count should be readable");
        assert_eq!(remaining, 0);
    }

    remove_database(&path);
}
