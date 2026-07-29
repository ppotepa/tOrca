use std::{path::Path, time::Duration};

use rusqlite::{Connection, OptionalExtension, params};
use sha2::Digest;

use crate::{
    EngineError, EngineResult,
    config::SecretBytes,
};

use super::{Migration, MigrationRunner, transaction::SqliteTransaction};

pub const MIGRATION_LOOKUP: &str = include_str!("../../sql/queries/migration_lookup.sql");
pub const MIGRATION_INSERT: &str = include_str!("../../sql/queries/migration_insert.sql");
pub const TABLE_COLUMNS: &str = include_str!("../../sql/queries/table_columns.sql");
pub const CONNECTION_PRAGMAS: &str = include_str!("../../sql/queries/connection_pragmas.sql");

pub const MIGRATIONS: &[Migration] = &[
    Migration {
        version: 0,
        name: "000_schema_migrations.sql",
        sql: include_str!("../../sql/migrations/000_schema_migrations.sql"),
    },
    Migration {
        version: 1,
        name: "001_canonical_client.sql",
        sql: include_str!("../../sql/migrations/001_canonical_client.sql"),
    },
    Migration {
        version: 2,
        name: "002_pairing_inbox_retry.sql",
        sql: include_str!("../../sql/migrations/002_pairing_inbox_retry.sql"),
    },
];

pub struct ClientDatabase {
    connection: Connection,
    migration_runner: MigrationRunner,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PendingWelcomeRecord {
    pub invite_id: String,
    pub recipient_installation_id: String,
    pub payload: Vec<u8>,
    pub expires_at: i64,
    pub attempt_count: u32,
    pub next_attempt_at: i64,
    pub last_error: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ReceivedEnvelopeRecord {
    pub sender_installation_id: String,
    pub message_id: String,
    pub ciphertext_hash: Vec<u8>,
    pub received_at: i64,
    pub receipt_state: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeliveryReceiptRecord {
    pub envelope_id: String,
    pub message_id: String,
    pub conversation_id: String,
    pub original_sender: String,
    pub received_at: i64,
    pub relay_payload: Option<Vec<u8>>,
    pub state: String,
    pub attempt_count: u32,
    pub next_attempt_at: i64,
    pub last_error: Option<String>,
    pub created_at: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredMessageRecord {
    pub id: String,
    pub conversation_id: String,
    pub outgoing: bool,
    pub body: String,
    pub state: String,
    pub created_at: i64,
    pub relay_payload: Option<Vec<u8>>,
    pub ciphertext_hash: Option<Vec<u8>>,
    pub attempt_count: u32,
    pub last_attempt_at: Option<i64>,
    pub next_attempt_at: i64,
    pub ack_deadline: Option<i64>,
    pub last_transport_error: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PairingResponseRecord {
    pub pairing_id: String,
    pub recipient_installation_id: String,
    pub state: String,
    pub offer_payload: Option<Vec<u8>>,
    pub attempt_count: u32,
    pub next_attempt_at: i64,
    pub last_error: Option<String>,
    pub expires_at: i64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RetryKind {
    MessageSend,
    MessageAckDeadline,
    Receipt,
    PendingWelcome,
    PairingResponse,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RetryDeadline {
    pub kind: RetryKind,
    pub at_ms: i64,
}

impl ClientDatabase {
    pub fn open(path: &Path, database_key: &SecretBytes) -> EngineResult<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|error| EngineError::Storage(format!("{error:#}")))?;
        }
        let connection = Connection::open(path).map_err(sqlite_error)?;
        connection
            .execute_batch(&sqlcipher_key_pragma(database_key.expose()))
            .map_err(sqlite_error)?;
        connection.execute_batch(CONNECTION_PRAGMAS).map_err(sqlite_error)?;
        connection
            .busy_timeout(Duration::from_secs(5))
            .map_err(sqlite_error)?;
        let integrity_check: String = connection
            .query_row("PRAGMA integrity_check;", [], |row| row.get("integrity_check"))
            .map_err(sqlite_error)?;
        if integrity_check != "ok" {
            return Err(EngineError::Storage(format!(
                "sqlite integrity_check failed: {integrity_check}"
            )));
        }
        let migration_runner = MigrationRunner::new(MIGRATIONS);
        migration_runner.run(&connection)?;
        Ok(Self {
            connection,
            migration_runner,
        })
    }

    pub fn connection(&self) -> &Connection {
        &self.connection
    }

    pub fn connection_mut(&mut self) -> &mut Connection {
        &mut self.connection
    }

    pub fn migration_runner(&self) -> &MigrationRunner {
        &self.migration_runner
    }

    pub fn transaction(&mut self) -> EngineResult<SqliteTransaction<'_>> {
        let transaction = self.connection.transaction().map_err(sqlite_error)?;
        Ok(SqliteTransaction::new(transaction))
    }

    pub fn mls_inbox_snapshot(&self) -> EngineResult<Option<Vec<u8>>> {
        self.get_setting_blob("mls_inbox_snapshot_v1")
    }

    pub fn put_mls_inbox_snapshot(&self, snapshot: &[u8]) -> EngineResult<()> {
        self.put_setting_blob("mls_inbox_snapshot_v1", snapshot)
    }

    pub fn conversation_mls_snapshots(&self) -> EngineResult<Vec<(String, Vec<u8>)>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT conversation_id, snapshot
                 FROM conversation_mls
                 ORDER BY conversation_id ASC;",
            )
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .map_err(sqlite_error)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(sqlite_error)
    }

    pub fn conversation_mls_snapshot(&self, conversation_id: &str) -> EngineResult<Option<Vec<u8>>> {
        self.connection
            .query_row(
                "SELECT snapshot
                 FROM conversation_mls
                 WHERE conversation_id = ?1;",
                [conversation_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(sqlite_error)
    }

    pub fn put_conversation_mls_snapshot(
        &self,
        conversation_id: &str,
        snapshot: &[u8],
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "INSERT INTO conversation_mls (conversation_id, snapshot, updated_at)
                 VALUES (?1, ?2, unixepoch())
                 ON CONFLICT(conversation_id) DO UPDATE SET
                    snapshot = excluded.snapshot,
                    updated_at = unixepoch();",
                params![conversation_id, snapshot],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn delete_conversation_mls_snapshot(&self, conversation_id: &str) -> EngineResult<()> {
        self.connection
            .execute(
                "DELETE FROM conversation_mls
                 WHERE conversation_id = ?1;",
                [conversation_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn pending_welcomes(&self) -> EngineResult<Vec<PendingWelcomeRecord>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT invite_id, recipient_installation_id, payload, expires_at,
                        attempt_count, next_attempt_at, last_error
                 FROM pending_welcomes
                 ORDER BY expires_at ASC, invite_id ASC;",
            )
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map([], |row| {
                Ok(PendingWelcomeRecord {
                    invite_id: row.get("invite_id")?,
                    recipient_installation_id: row.get("recipient_installation_id")?,
                    payload: row.get("payload")?,
                    expires_at: row.get("expires_at")?,
                    attempt_count: row.get::<_, i64>("attempt_count")? as u32,
                    next_attempt_at: row.get("next_attempt_at")?,
                    last_error: row.get("last_error")?,
                })
            })
            .map_err(sqlite_error)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(sqlite_error)
    }

    pub fn put_pending_welcome(&self, record: &PendingWelcomeRecord) -> EngineResult<()> {
        self.connection
            .execute(
                "INSERT INTO pending_welcomes (
                    invite_id, recipient_installation_id, payload, expires_at,
                    attempt_count, next_attempt_at, last_error
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                 ON CONFLICT(invite_id) DO UPDATE SET
                    recipient_installation_id = excluded.recipient_installation_id,
                    payload = excluded.payload,
                    expires_at = excluded.expires_at,
                    attempt_count = excluded.attempt_count,
                    next_attempt_at = excluded.next_attempt_at,
                    last_error = excluded.last_error;",
                params![
                    record.invite_id,
                    record.recipient_installation_id,
                    record.payload,
                    record.expires_at,
                    i64::from(record.attempt_count),
                    record.next_attempt_at,
                    record.last_error,
                ],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn remove_pending_welcome(&self, invite_id: &str) -> EngineResult<()> {
        self.connection
            .execute(
                "DELETE FROM pending_welcomes
                 WHERE invite_id = ?1;",
                [invite_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn consume_invite(&self, invite_id: &str) -> EngineResult<bool> {
        let inserted = self
            .connection
            .execute(
                "INSERT OR IGNORE INTO used_invites (invite_id, used_at)
                 VALUES (?1, unixepoch());",
                [invite_id],
            )
            .map_err(sqlite_error)?;
        Ok(inserted > 0)
    }

    pub fn received_envelope(
        &self,
        sender_installation_id: &str,
        message_id: &str,
    ) -> EngineResult<Option<ReceivedEnvelopeRecord>> {
        self.connection
            .query_row(
                "SELECT sender_installation_id, message_id, ciphertext_hash, received_at, receipt_state
                 FROM received_envelopes
                 WHERE sender_installation_id = ?1 AND message_id = ?2;",
                params![sender_installation_id, message_id],
                |row| {
                    Ok(ReceivedEnvelopeRecord {
                        sender_installation_id: row.get("sender_installation_id")?,
                        message_id: row.get("message_id")?,
                        ciphertext_hash: row.get("ciphertext_hash")?,
                        received_at: row.get("received_at")?,
                        receipt_state: row.get("receipt_state")?,
                    })
                },
            )
            .optional()
            .map_err(sqlite_error)
    }

    pub fn put_received_envelope(&self, value: &ReceivedEnvelopeRecord) -> EngineResult<()> {
        self.connection
            .execute(
                "INSERT OR REPLACE INTO received_envelopes (
                    sender_installation_id, message_id, ciphertext_hash, received_at, receipt_state
                 ) VALUES (?1, ?2, ?3, ?4, ?5);",
                params![
                    value.sender_installation_id,
                    value.message_id,
                    value.ciphertext_hash,
                    value.received_at,
                    value.receipt_state,
                ],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn put_delivery_receipt(&self, value: &DeliveryReceiptRecord) -> EngineResult<()> {
        self.connection
            .execute(
                "INSERT OR REPLACE INTO delivery_receipts (
                    envelope_id, message_id, conversation_id, original_sender, received_at,
                    relay_payload, state, attempt_count, next_attempt_at, last_error, created_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11);",
                params![
                    value.envelope_id,
                    value.message_id,
                    value.conversation_id,
                    value.original_sender,
                    value.received_at,
                    value.relay_payload,
                    value.state,
                    i64::from(value.attempt_count),
                    value.next_attempt_at,
                    value.last_error,
                    value.created_at,
                ],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn message(&self, message_id: &str) -> EngineResult<Option<StoredMessageRecord>> {
        self.connection
            .query_row(
                "SELECT id, conversation_id, outgoing, body, state, created_at,
                        relay_payload, ciphertext_hash, attempt_count, last_attempt_at,
                        next_attempt_at, ack_deadline, last_transport_error
                 FROM messages
                 WHERE id = ?1;",
                [message_id],
                |row| {
                    Ok(StoredMessageRecord {
                        id: row.get("id")?,
                        conversation_id: row.get("conversation_id")?,
                        outgoing: row.get::<_, i64>("outgoing")? != 0,
                        body: row.get("body")?,
                        state: row.get("state")?,
                        created_at: row.get("created_at")?,
                        relay_payload: row.get("relay_payload")?,
                        ciphertext_hash: row.get("ciphertext_hash")?,
                        attempt_count: row.get::<_, i64>("attempt_count")? as u32,
                        last_attempt_at: row.get("last_attempt_at")?,
                        next_attempt_at: row.get("next_attempt_at")?,
                        ack_deadline: row.get("ack_deadline")?,
                        last_transport_error: row.get("last_transport_error")?,
                    })
                },
            )
            .optional()
            .map_err(sqlite_error)
    }

    pub fn persist_outbound_encryption(
        &self,
        message_id: &str,
        relay_payload: &[u8],
        conversation_id: &str,
        snapshot: &[u8],
    ) -> EngineResult<()> {
        let ciphertext_hash = sha2::Sha256::digest(relay_payload).to_vec();
        let transaction = self.connection.unchecked_transaction().map_err(sqlite_error)?;
        transaction
            .execute(
                "UPDATE messages
                 SET relay_payload = ?2, ciphertext_hash = ?3
                 WHERE id = ?1;",
                params![message_id, relay_payload, ciphertext_hash],
            )
            .map_err(sqlite_error)?;
        transaction
            .execute(
                "INSERT INTO conversation_mls (conversation_id, snapshot, updated_at)
                 VALUES (?1, ?2, unixepoch())
                 ON CONFLICT(conversation_id) DO UPDATE SET
                    snapshot = excluded.snapshot,
                    updated_at = unixepoch();",
                params![conversation_id, snapshot],
            )
            .map_err(sqlite_error)?;
        transaction.commit().map_err(sqlite_error)?;
        Ok(())
    }

    pub fn claim_outgoing_attempt(
        &self,
        message_id: &str,
        next_attempt_at: i64,
        ack_deadline: Option<i64>,
        last_transport_error: Option<&str>,
    ) -> EngineResult<bool> {
        let now_ms = unix_ms();
        let changed = self
            .connection
            .execute(
                "UPDATE messages
                 SET attempt_count = attempt_count + 1,
                     last_attempt_at = ?1,
                     next_attempt_at = ?2,
                     ack_deadline = ?3,
                     last_transport_error = ?4
                 WHERE id = ?5
                   AND outgoing = 1
                   AND UPPER(state) IN ('SENDING', 'SENT', 'QUEUED')
                   AND next_attempt_at <= ?1;",
                params![
                    now_ms,
                    next_attempt_at,
                    ack_deadline,
                    last_transport_error,
                    message_id,
                ],
            )
            .map_err(sqlite_error)?;
        Ok(changed > 0)
    }

    pub fn claim_receipt_attempt(
        &self,
        message_id: &str,
        next_attempt_at: i64,
        last_error: Option<&str>,
    ) -> EngineResult<bool> {
        let now_ms = unix_ms();
        let changed = self
            .connection
            .execute(
                "UPDATE delivery_receipts
                 SET state = 'SENT',
                     attempt_count = attempt_count + 1,
                     next_attempt_at = ?1,
                     last_error = ?2
                 WHERE message_id = ?3
                   AND UPPER(state) IN ('PENDING', 'SENT')
                   AND next_attempt_at <= ?4;",
                params![next_attempt_at, last_error, message_id, now_ms],
            )
            .map_err(sqlite_error)?;
        Ok(changed > 0)
    }

    pub fn requeue_sending_after_disconnect(&self, now_ms: i64) -> EngineResult<()> {
        self.connection
            .execute(
                "UPDATE messages
                 SET state = 'QUEUED',
                     next_attempt_at = ?1,
                     ack_deadline = NULL
                 WHERE outgoing = 1
                   AND UPPER(state) = 'SENDING';",
                params![now_ms],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn due_pending_welcomes(&self, now_ms: i64) -> EngineResult<Vec<PendingWelcomeRecord>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT invite_id, recipient_installation_id, payload, expires_at,
                        attempt_count, next_attempt_at, last_error
                 FROM pending_welcomes
                 WHERE next_attempt_at <= ?1
                 ORDER BY next_attempt_at ASC, invite_id ASC;",
            )
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map([now_ms], |row| {
                Ok(PendingWelcomeRecord {
                    invite_id: row.get("invite_id")?,
                    recipient_installation_id: row.get("recipient_installation_id")?,
                    payload: row.get("payload")?,
                    expires_at: row.get("expires_at")?,
                    attempt_count: row.get::<_, i64>("attempt_count")? as u32,
                    next_attempt_at: row.get("next_attempt_at")?,
                    last_error: row.get("last_error")?,
                })
            })
            .map_err(sqlite_error)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(sqlite_error)
    }

    pub fn claim_pending_welcome_attempt(
        &self,
        invite_id: &str,
        next_attempt_at: i64,
        last_error: Option<&str>,
    ) -> EngineResult<bool> {
        let now_ms = unix_ms();
        let changed = self
            .connection
            .execute(
                "UPDATE pending_welcomes
                 SET attempt_count = attempt_count + 1,
                     next_attempt_at = ?1,
                     last_error = ?2
                 WHERE invite_id = ?3
                   AND next_attempt_at <= ?4;",
                params![next_attempt_at, last_error, invite_id, now_ms],
            )
            .map_err(sqlite_error)?;
        Ok(changed > 0)
    }

    pub fn next_retry_deadline(
        &self,
        _now_ms: i64,
        now_secs: i64,
    ) -> EngineResult<Option<RetryDeadline>> {
        let mut deadlines = Vec::new();
        if let Some(deadline) = self.next_message_retry_deadline_ms()? {
            deadlines.push(RetryDeadline {
                kind: RetryKind::MessageSend,
                at_ms: deadline,
            });
        }
        if let Some(deadline) = self.next_message_ack_deadline_ms()? {
            deadlines.push(RetryDeadline {
                kind: RetryKind::MessageAckDeadline,
                at_ms: deadline,
            });
        }
        if let Some(deadline) = self.next_receipt_retry_deadline_ms()? {
            deadlines.push(RetryDeadline {
                kind: RetryKind::Receipt,
                at_ms: deadline,
            });
        }
        if let Some(deadline) = self.next_pending_welcome_retry_deadline_ms()? {
            deadlines.push(RetryDeadline {
                kind: RetryKind::PendingWelcome,
                at_ms: deadline,
            });
        }
        if let Some(deadline) = self.next_pairing_response_retry_deadline_ms(now_secs)? {
            deadlines.push(RetryDeadline {
                kind: RetryKind::PairingResponse,
                at_ms: deadline,
            });
        }
        Ok(deadlines.into_iter().min_by_key(|deadline| deadline.at_ms))
    }

    pub fn next_message_retry_deadline_ms(&self) -> EngineResult<Option<i64>> {
        self.connection
            .query_row(
                "SELECT MIN(next_attempt_at)
                 FROM messages
                 WHERE outgoing = 1
                   AND UPPER(state) IN ('SENDING', 'SENT', 'QUEUED');",
                [],
                |row| row.get(0),
            )
            .map_err(sqlite_error)
    }

    pub fn next_receipt_retry_deadline_ms(&self) -> EngineResult<Option<i64>> {
        self.connection
            .query_row(
                "SELECT MIN(next_attempt_at)
                 FROM delivery_receipts
                 WHERE UPPER(state) IN ('PENDING', 'SENT');",
                [],
                |row| row.get(0),
            )
            .map_err(sqlite_error)
    }

    pub fn next_message_ack_deadline_ms(&self) -> EngineResult<Option<i64>> {
        self.connection
            .query_row(
                "SELECT MIN(ack_deadline)
                 FROM messages
                 WHERE outgoing = 1
                   AND UPPER(state) = 'SENT'
                   AND ack_deadline IS NOT NULL;",
                [],
                |row| row.get(0),
            )
            .map_err(sqlite_error)
    }

    pub fn next_pending_welcome_retry_deadline_ms(&self) -> EngineResult<Option<i64>> {
        self.connection
            .query_row(
                "SELECT MIN(next_attempt_at)
                 FROM pending_welcomes;",
                [],
                |row| row.get(0),
            )
            .map_err(sqlite_error)
    }

    pub fn next_pairing_response_retry_deadline_ms(
        &self,
        now_secs: i64,
    ) -> EngineResult<Option<i64>> {
        self.connection
            .query_row(
                "SELECT MIN(next_attempt_at)
                 FROM pairing_inbox
                 WHERE expires_at >= ?1
                   AND UPPER(state) IN ('ACCEPTED', 'REJECTED');",
                [now_secs],
                |row| row.get(0),
            )
            .map_err(sqlite_error)
    }

    pub fn pairing_response_retry_record(
        &self,
        pairing_id: &str,
        now_secs: i64,
    ) -> EngineResult<Option<PairingResponseRecord>> {
        self.connection
            .query_row(
                "SELECT pairing_id, sender_installation_id, state, offer_payload,
                        attempt_count, next_attempt_at, last_error, expires_at
                 FROM pairing_inbox
                 WHERE pairing_id = ?1
                   AND expires_at >= ?2
                   AND UPPER(state) IN ('ACCEPTED', 'REJECTED');",
                params![pairing_id, now_secs],
                |row| {
                    Ok(PairingResponseRecord {
                        pairing_id: row.get("pairing_id")?,
                        recipient_installation_id: row.get("sender_installation_id")?,
                        state: row.get("state")?,
                        offer_payload: row.get("offer_payload")?,
                        attempt_count: row.get::<_, i64>("attempt_count")? as u32,
                        next_attempt_at: row.get("next_attempt_at")?,
                        last_error: row.get("last_error")?,
                        expires_at: row.get("expires_at")?,
                    })
                },
            )
            .optional()
            .map_err(sqlite_error)
    }

    pub fn claim_pairing_response_attempt(
        &self,
        pairing_id: &str,
        next_attempt_at: i64,
        last_error: Option<&str>,
    ) -> EngineResult<bool> {
        let now_ms = unix_ms();
        let now_secs = unix_secs();
        let changed = self
            .connection
            .execute(
                "UPDATE pairing_inbox
                 SET attempt_count = attempt_count + 1,
                     next_attempt_at = ?1,
                     last_error = ?2,
                     updated_at = unixepoch()
                 WHERE pairing_id = ?3
                   AND expires_at >= ?4
                   AND UPPER(state) IN ('ACCEPTED', 'REJECTED')
                   AND next_attempt_at <= ?5;",
                params![next_attempt_at, last_error, pairing_id, now_secs, now_ms],
            )
            .map_err(sqlite_error)?;
        Ok(changed > 0)
    }

    pub fn record_pairing_response_error(
        &self,
        pairing_id: &str,
        last_error: &str,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "UPDATE pairing_inbox
                 SET last_error = ?1,
                     updated_at = unixepoch()
                 WHERE pairing_id = ?2;",
                params![last_error, pairing_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn expired_ack_deadline_message_ids(&self, now_ms: i64) -> EngineResult<Vec<String>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT id
                 FROM messages
                 WHERE outgoing = 1
                   AND UPPER(state) = 'SENT'
                   AND ack_deadline IS NOT NULL
                   AND ack_deadline <= ?1
                 ORDER BY ack_deadline ASC, created_at ASC, id ASC;",
            )
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map([now_ms], |row| row.get(0))
            .map_err(sqlite_error)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(sqlite_error)
    }

    fn get_setting_blob(&self, key: &str) -> EngineResult<Option<Vec<u8>>> {
        self.connection
            .query_row(
                "SELECT value
                 FROM settings
                 WHERE key = ?1;",
                [key],
                |row| row.get(0),
            )
            .optional()
            .map_err(sqlite_error)
    }

    fn put_setting_blob(&self, key: &str, value: &[u8]) -> EngineResult<()> {
        self.connection
            .execute(
                "INSERT INTO settings (key, value)
                 VALUES (?1, ?2)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
                params![key, value],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }
}

fn sqlite_error(error: rusqlite::Error) -> EngineError {
    EngineError::Storage(format!("{error:#}"))
}

fn sqlcipher_key_pragma(database_key: &[u8]) -> String {
    let mut hex = String::with_capacity(database_key.len() * 2);
    for byte in database_key {
        use std::fmt::Write as _;
        let _ = write!(&mut hex, "{byte:02x}");
    }
    format!("PRAGMA key = \"x'{hex}'\";")
}

fn unix_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system clock must be after unix epoch")
        .as_millis() as i64
}

fn unix_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system clock must be after unix epoch")
        .as_secs() as i64
}
