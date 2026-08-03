use std::{
    collections::HashSet,
    path::Path,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use rusqlite::{Connection, OptionalExtension, params};
use sha2::Digest;
use torchat_client_runtime::CapabilityStatus;
use torchat_core::peer_protocol::{PeerEndpointBundle, PeerEndpointUpdate, PeerMessageEnvelope};
use uuid::Uuid;

use crate::{EngineError, EngineResult, config::SecretBytes};

use super::{MigrationRunner, transaction::SqliteTransaction};

pub type ContactEndpointCapability = (String, Vec<u8>, u64, CapabilityStatus);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RelationshipRemovalOutboxRecord {
    pub removal_id: String,
    pub contact_installation_id: String,
    pub removed_at: i64,
    pub relationship_epoch: i64,
    pub preserve_history: bool,
    pub attempt_count: u32,
}

pub struct ClientDatabase {
    connection: Connection,
    migration_runner: MigrationRunner,
}

mod messages;
mod migrations;
mod pairing;
mod peer_endpoints;
mod projection;
mod read_receipts;
mod receipts;
mod records;
use migrations::{BASELINE_SCHEMA, CONNECTION_PRAGMAS};
pub use migrations::{MIGRATION_LOOKUP, MIGRATIONS, TABLE_COLUMNS};
pub use records::*;

impl ClientDatabase {
    pub fn record_delivery_dead_letter(
        &self,
        kind: &str,
        item_id: &str,
        contact_installation_id: Option<&str>,
        attempt_count: u32,
        error: &str,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "INSERT INTO delivery_dead_letters
                 (kind, item_id, contact_installation_id, attempt_count, last_error, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, unixepoch(), unixepoch())
                 ON CONFLICT(kind, item_id) DO UPDATE SET
                    contact_installation_id = excluded.contact_installation_id,
                    attempt_count = excluded.attempt_count,
                    last_error = excluded.last_error,
                    updated_at = unixepoch();",
                rusqlite::params![kind, item_id, contact_installation_id, attempt_count, error],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn record_contact_seen(&self, contact_id: &str, observed_at: i64) -> EngineResult<()> {
        self.connection
            .execute(
                "UPDATE contacts SET last_seen_at = ?1, updated_at = unixepoch() WHERE installation_id = ?2",
                rusqlite::params![observed_at, contact_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn open(path: &Path, database_key: &SecretBytes) -> EngineResult<Self> {
        if database_key.expose().len() != 32 {
            return Err(EngineError::InvalidConfig(
                "databaseKey must contain exactly 32 bytes".to_owned(),
            ));
        }
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|error| EngineError::Storage(format!("{error:#}")))?;
        }
        let connection = Connection::open(path).map_err(sqlite_error)?;
        connection
            .execute_batch(&sqlcipher_key_pragma(database_key.expose()))
            .map_err(sqlite_error)?;
        connection
            .execute_batch(CONNECTION_PRAGMAS)
            .map_err(sqlite_error)?;
        connection
            .busy_timeout(Duration::from_secs(5))
            .map_err(sqlite_error)?;
        let integrity_check: String = connection
            .query_row("PRAGMA integrity_check;", [], |row| {
                row.get("integrity_check")
            })
            .map_err(sqlite_error)?;
        if integrity_check != "ok" {
            return Err(EngineError::Storage(format!(
                "sqlite integrity_check failed: {integrity_check}"
            )));
        }
        let has_schema_migrations = connection
            .query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM sqlite_master
                    WHERE type = 'table' AND name = 'schema_migrations'
                );",
                [],
                |row| row.get::<_, i64>(0),
            )
            .map_err(sqlite_error)?
            != 0;
        let has_client_tables = connection
            .query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM sqlite_master
                    WHERE type = 'table' AND name IN ('contacts', 'messages')
                );",
                [],
                |row| row.get::<_, i64>(0),
            )
            .map_err(sqlite_error)?
            != 0;
        if !has_schema_migrations && has_client_tables {
            return Err(EngineError::Storage(
                "unversioned client database detected; run deploy-clean or reset the client database"
                    .to_owned(),
            ));
        }
        let migration_runner = MigrationRunner::new(MIGRATIONS);
        if !has_schema_migrations {
            connection
                .execute_batch(BASELINE_SCHEMA)
                .map_err(sqlite_error)?;
        } else {
            migration_runner.run(&connection)?;
        }
        let database = Self {
            connection,
            migration_runner,
        };
        database.prune_processed_commands(
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|duration| duration.as_secs() as i64)
                .unwrap_or_default(),
            Self::PROCESSED_COMMAND_RETENTION_SECS,
            Self::MAX_PROCESSED_COMMANDS,
        )?;
        Ok(database)
    }

    pub fn connection(&self) -> &Connection {
        &self.connection
    }

    pub fn connection_mut(&mut self) -> &mut Connection {
        &mut self.connection
    }

    /// Rotate the SQLCipher key while the database is open under its current
    /// key. Callers must persist the new key only after this returns success.
    pub fn rekey(&mut self, new_key: &SecretBytes) -> EngineResult<()> {
        if new_key.expose().len() != 32 {
            return Err(EngineError::InvalidConfig(
                "databaseKey must contain exactly 32 bytes".to_owned(),
            ));
        }
        self.connection
            .execute_batch(&sqlcipher_rekey_pragma(new_key.expose()))
            .map_err(sqlite_error)?;
        let integrity: String = self
            .connection
            .query_row("PRAGMA integrity_check;", [], |row| row.get(0))
            .map_err(sqlite_error)?;
        if integrity != "ok" {
            return Err(EngineError::Storage(format!(
                "sqlcipher rekey integrity check failed: {integrity}"
            )));
        }
        Ok(())
    }

    pub fn migration_runner(&self) -> &MigrationRunner {
        &self.migration_runner
    }

    pub fn transaction(&mut self) -> EngineResult<SqliteTransaction<'_>> {
        let transaction = self.connection.transaction().map_err(sqlite_error)?;
        Ok(SqliteTransaction::new(transaction))
    }

    pub fn due_relationship_removals(
        &self,
        now_ms: i64,
    ) -> EngineResult<Vec<RelationshipRemovalOutboxRecord>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT o.removal_id, o.contact_installation_id, t.removed_at,
                    o.relationship_epoch, o.preserve_history, o.attempt_count
             FROM relationship_removal_outbox o
             JOIN relationship_tombstones t
               ON t.contact_installation_id = o.contact_installation_id
              AND t.removal_id = o.removal_id
             WHERE o.state = 'PENDING' AND o.next_attempt_at <= ?1
             ORDER BY o.next_attempt_at ASC, o.removal_id ASC;",
            )
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map([now_ms], |row| {
                Ok(RelationshipRemovalOutboxRecord {
                    removal_id: row.get(0)?,
                    contact_installation_id: row.get(1)?,
                    removed_at: row.get(2)?,
                    relationship_epoch: row.get(3)?,
                    preserve_history: row.get::<_, i64>(4)? != 0,
                    attempt_count: row.get::<_, i64>(5)?.max(0) as u32,
                })
            })
            .map_err(sqlite_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sqlite_error)?;
        Ok(rows)
    }

    pub fn mark_relationship_removal_dispatched(
        &self,
        removal_id: &str,
        next_attempt_at: i64,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "UPDATE relationship_removal_outbox
             SET state = 'DISPATCHED', attempt_count = attempt_count + 1,
                 next_attempt_at = ?2, updated_at = unixepoch()
             WHERE removal_id = ?1 AND state = 'PENDING';",
                rusqlite::params![removal_id, next_attempt_at],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn complete_relationship_removal_ack(&self, removal_id: &str) -> EngineResult<()> {
        self.connection
            .execute(
                "UPDATE relationship_removal_outbox
                 SET state = 'ACKED', updated_at = unixepoch()
                 WHERE removal_id = ?1;",
                [removal_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
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
            .query_map([], |row| {
                Ok((row.get("conversation_id")?, row.get("snapshot")?))
            })
            .map_err(sqlite_error)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(sqlite_error)
    }

    pub fn conversation_mls_snapshot(
        &self,
        conversation_id: &str,
    ) -> EngineResult<Option<Vec<u8>>> {
        self.connection
            .query_row(
                "SELECT snapshot
                 FROM conversation_mls
                 WHERE conversation_id = ?1;",
                [conversation_id],
                |row| row.get("snapshot"),
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

    pub fn put_pending_application_envelope(
        &self,
        record: &PendingApplicationEnvelopeRecord,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "INSERT INTO pending_application_envelopes (
                    sender_installation_id, message_id, envelope_json,
                    ciphertext, ciphertext_hash, received_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(sender_installation_id, message_id) DO UPDATE SET
                    envelope_json = excluded.envelope_json,
                    ciphertext = excluded.ciphertext,
                    ciphertext_hash = excluded.ciphertext_hash,
                    received_at = excluded.received_at;",
                params![
                    record.sender_installation_id,
                    record.message_id,
                    record.envelope_json,
                    record.ciphertext,
                    record.ciphertext_hash,
                    record.received_at,
                ],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn pending_application_envelopes(
        &self,
        sender_installation_id: &str,
    ) -> EngineResult<Vec<PendingApplicationEnvelopeRecord>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT sender_installation_id, message_id, envelope_json,
                        ciphertext, ciphertext_hash, received_at
                 FROM pending_application_envelopes
                 WHERE sender_installation_id = ?1
                 ORDER BY received_at ASC, message_id ASC;",
            )
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map([sender_installation_id], |row| {
                Ok(PendingApplicationEnvelopeRecord {
                    sender_installation_id: row.get("sender_installation_id")?,
                    message_id: row.get("message_id")?,
                    envelope_json: row.get("envelope_json")?,
                    ciphertext: row.get("ciphertext")?,
                    ciphertext_hash: row.get("ciphertext_hash")?,
                    received_at: row.get("received_at")?,
                })
            })
            .map_err(sqlite_error)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(sqlite_error)
    }

    pub fn remove_pending_application_envelope(
        &self,
        sender_installation_id: &str,
        message_id: &str,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "DELETE FROM pending_application_envelopes
                 WHERE sender_installation_id = ?1 AND message_id = ?2;",
                params![sender_installation_id, message_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn put_capability_delivery(&self, record: &CapabilityDeliveryRecord) -> EngineResult<()> {
        self.connection
            .execute(
                "INSERT INTO capability_delivery_outbox (
                    delivery_id, contact_installation_id, payload,
                    attempt_count, next_attempt_at, last_error, created_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                 ON CONFLICT(delivery_id) DO UPDATE SET
                    payload = excluded.payload,
                    attempt_count = excluded.attempt_count,
                    next_attempt_at = excluded.next_attempt_at,
                    last_error = excluded.last_error;",
                params![
                    record.delivery_id,
                    record.contact_installation_id,
                    record.payload,
                    i64::from(record.attempt_count),
                    record.next_attempt_at,
                    record.last_error,
                    record.created_at,
                ],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn due_capability_deliveries(
        &self,
        now_ms: i64,
    ) -> EngineResult<Vec<CapabilityDeliveryRecord>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT delivery_id, contact_installation_id, payload,
                        attempt_count, next_attempt_at, last_error, created_at
                 FROM capability_delivery_outbox
                 WHERE next_attempt_at <= ?1 AND dead_lettered_at IS NULL
                 ORDER BY next_attempt_at ASC, created_at ASC;",
            )
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map([now_ms], |row| {
                Ok(CapabilityDeliveryRecord {
                    delivery_id: row.get("delivery_id")?,
                    contact_installation_id: row.get("contact_installation_id")?,
                    payload: row.get("payload")?,
                    attempt_count: row.get::<_, i64>("attempt_count")? as u32,
                    next_attempt_at: row.get("next_attempt_at")?,
                    last_error: row.get("last_error")?,
                    created_at: row.get("created_at")?,
                })
            })
            .map_err(sqlite_error)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(sqlite_error)
    }

    pub fn has_capability_delivery_for_contact(
        &self,
        contact_installation_id: &str,
    ) -> EngineResult<bool> {
        self.connection
            .query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM capability_delivery_outbox
                    WHERE contact_installation_id = ?1
                 );",
                [contact_installation_id],
                |row| row.get::<_, i64>(0),
            )
            .map(|value| value != 0)
            .map_err(sqlite_error)
    }

    pub fn claim_capability_delivery(
        &self,
        delivery_id: &str,
        next_attempt_at: i64,
        last_error: Option<&str>,
    ) -> EngineResult<bool> {
        let changed = self
            .connection
            .execute(
                "UPDATE capability_delivery_outbox
                 SET attempt_count = attempt_count + 1,
                     next_attempt_at = ?1,
                     last_error = ?2
                 WHERE delivery_id = ?3 AND next_attempt_at <= ?4;",
                params![next_attempt_at, last_error, delivery_id, unix_ms()],
            )
            .map_err(sqlite_error)?;
        Ok(changed > 0)
    }

    pub fn complete_capability_delivery(&self, delivery_id: &str) -> EngineResult<()> {
        self.connection
            .execute(
                "DELETE FROM capability_delivery_outbox WHERE delivery_id = ?1;",
                [delivery_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn complete_capability_deliveries_for_contact(
        &self,
        contact_installation_id: &str,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "DELETE FROM capability_delivery_outbox
                 WHERE contact_installation_id = ?1;",
                [contact_installation_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    /// Re-enable one terminal retry record after an explicit operator/user
    /// action. The last error is retained for diagnostics; only scheduling
    /// state is reset.
    pub fn retry_dead_letter(&self, kind: &str, id: &str) -> EngineResult<bool> {
        let changed = match kind {
            "capability" => self.connection.execute(
                "UPDATE capability_delivery_outbox
                 SET dead_lettered_at = NULL, next_attempt_at = 0
                 WHERE delivery_id = ?1 AND dead_lettered_at IS NOT NULL;",
                [id],
            ),
            "endpoint_bootstrap" => self.connection.execute(
                "UPDATE peer_endpoint_bootstrap_outbox
                 SET dead_lettered_at = NULL, next_attempt_at = 0
                 WHERE contact_installation_id = ?1 AND dead_lettered_at IS NOT NULL;",
                [id],
            ),
            "contact_confirmation" => self.connection.execute(
                "UPDATE pending_contact_confirmations
                 SET dead_lettered_at = NULL, next_attempt_at = 0
                 WHERE pairing_id = ?1 AND dead_lettered_at IS NOT NULL;",
                [id],
            ),
            "welcome" => self.connection.execute(
                "UPDATE pending_welcomes
                 SET dead_lettered_at = NULL, next_attempt_at = 0
                 WHERE invite_id = ?1 AND dead_lettered_at IS NOT NULL;",
                [id],
            ),
            _ => {
                return Err(EngineError::InvalidCommand(
                    "unknown retry dead-letter kind".to_owned(),
                ));
            }
        }
        .map_err(sqlite_error)?;
        Ok(changed == 1)
    }

    pub fn dead_letters(&self) -> EngineResult<Vec<DeadLetterRecord>> {
        let mut statement = self.connection.prepare(
            "SELECT kind, id, attempt_count, dead_lettered_at, last_error
             FROM (
                SELECT 'capability' AS kind, delivery_id AS id, attempt_count, dead_lettered_at, last_error
                FROM capability_delivery_outbox WHERE dead_lettered_at IS NOT NULL
                UNION ALL
                SELECT 'endpoint_bootstrap', contact_installation_id, attempt_count, dead_lettered_at, last_error
                FROM peer_endpoint_bootstrap_outbox WHERE dead_lettered_at IS NOT NULL
                UNION ALL
                SELECT 'contact_confirmation', pairing_id, attempt_count, dead_lettered_at, last_error
                FROM pending_contact_confirmations WHERE dead_lettered_at IS NOT NULL
                UNION ALL
                SELECT 'welcome', invite_id, attempt_count, dead_lettered_at, last_error
                FROM pending_welcomes WHERE dead_lettered_at IS NOT NULL
             ) ORDER BY dead_lettered_at DESC, kind ASC, id ASC;",
        ).map_err(sqlite_error)?;
        let rows = statement
            .query_map([], |row| {
                Ok(DeadLetterRecord {
                    kind: row.get("kind")?,
                    id: row.get("id")?,
                    attempt_count: row.get::<_, i64>("attempt_count")? as u32,
                    dead_lettered_at: row.get("dead_lettered_at")?,
                    last_error: row.get("last_error")?,
                })
            })
            .map_err(sqlite_error)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(sqlite_error)
    }

    pub fn record_capability_delivery_error(
        &self,
        delivery_id: &str,
        next_attempt_at: i64,
        error: &str,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "UPDATE capability_delivery_outbox
                 SET next_attempt_at = ?1, last_error = ?2,
                     dead_lettered_at = CASE WHEN ?2 LIKE 'permanent:%' OR ?2 LIKE 'protocol:%' THEN unixepoch() ELSE dead_lettered_at END
                 WHERE delivery_id = ?3;",
                params![next_attempt_at, error, delivery_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn invite_used(&self, invite_id: &str) -> EngineResult<bool> {
        self.connection
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM used_invites WHERE invite_id = ?1) AS used;",
                [invite_id],
                |row| row.get::<_, i64>("used"),
            )
            .map(|used| used != 0)
            .map_err(sqlite_error)
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

    pub fn message(&self, message_id: &str) -> EngineResult<Option<StoredMessageRecord>> {
        self.connection
            .query_row(
                "SELECT id, conversation_id, outgoing, body, state, created_at,
                        COALESCE(wire_ciphertext, relay_payload) AS wire_ciphertext,
                        ciphertext_hash, attempt_count, last_attempt_at,
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
                        wire_ciphertext: row.get("wire_ciphertext")?,
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

    pub fn persist_outbound_encryption_and_claim(
        &mut self,
        message_id: &str,
        wire_ciphertext: &[u8],
        conversation_id: &str,
        snapshot: &[u8],
        next_attempt_at: i64,
        ack_deadline: Option<i64>,
    ) -> EngineResult<bool> {
        let ciphertext_hash = sha2::Sha256::digest(wire_ciphertext).to_vec();
        let now_ms = unix_ms();
        let transaction = self.connection.transaction().map_err(sqlite_error)?;
        let changed = transaction
            .execute(
                "UPDATE messages\n                 SET wire_ciphertext = ?2,\n                     ciphertext_hash = ?3,\n                     attempt_count = attempt_count + 1,\n                     last_attempt_at = ?4,\n                     next_attempt_at = ?5,\n                     ack_deadline = ?6,\n                     last_transport_error = NULL\n                 WHERE id = ?1\n                   AND outgoing = 1\n                   AND UPPER(state) IN ('SENDING', 'QUEUED')\n                   AND next_attempt_at <= ?4;",
                params![
                    message_id,
                    wire_ciphertext,
                    ciphertext_hash,
                    now_ms,
                    next_attempt_at,
                    ack_deadline,
                ],
            )
            .map_err(sqlite_error)?;
        if changed == 0 {
            transaction.rollback().map_err(sqlite_error)?;
            return Ok(false);
        }
        transaction
            .execute(
                "UPDATE messages SET claimed_until = ?1, last_error_code = NULL WHERE id = ?2;",
                params![ack_deadline, message_id],
            )
            .map_err(sqlite_error)?;
        transaction
            .execute(
                "INSERT INTO conversation_mls (conversation_id, snapshot, updated_at)\n                 VALUES (?1, ?2, unixepoch())\n                 ON CONFLICT(conversation_id) DO UPDATE SET\n                    snapshot = excluded.snapshot,\n                    updated_at = unixepoch();",
                params![conversation_id, snapshot],
            )
            .map_err(sqlite_error)?;
        transaction.commit().map_err(sqlite_error)?;
        Ok(true)
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
                   AND UPPER(state) IN ('SENDING', 'QUEUED')
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
        if changed > 0 {
            self.connection
                .execute(
                    "UPDATE messages SET claimed_until = ?1, last_error_code = NULL WHERE id = ?2;",
                    params![ack_deadline, message_id],
                )
                .map_err(sqlite_error)?;
        }
        Ok(changed > 0)
    }

    pub fn requeue_after_disconnect(&mut self, now_ms: i64) -> EngineResult<()> {
        let transaction = self.connection.transaction().map_err(sqlite_error)?;
        transaction
            .execute(
                "UPDATE delivery_receipts
                 SET state = 'PENDING', next_attempt_at = ?1
                 WHERE UPPER(state) = 'SENT';",
                [now_ms],
            )
            .map_err(sqlite_error)?;
        transaction
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
        transaction.commit().map_err(sqlite_error)?;
        Ok(())
    }

    pub fn delete_expired_pending_welcomes(&self, now_secs: i64) -> EngineResult<usize> {
        self.connection
            .execute(
                "DELETE FROM pending_welcomes WHERE expires_at < ?1;",
                [now_secs],
            )
            .map_err(sqlite_error)
    }

    pub fn due_pending_welcomes(
        &self,
        now_ms: i64,
        now_secs: i64,
    ) -> EngineResult<Vec<PendingWelcomeRecord>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT invite_id, recipient_installation_id, payload, expires_at,
                        attempt_count, next_attempt_at, last_error
                 FROM pending_welcomes
                 WHERE next_attempt_at <= ?1
                   AND expires_at >= ?2
                   AND dead_lettered_at IS NULL
                 ORDER BY next_attempt_at ASC, invite_id ASC;",
            )
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map(params![now_ms, now_secs], |row| {
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

    pub fn record_pending_welcome_error(
        &self,
        invite_id: &str,
        last_error: &str,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "UPDATE pending_welcomes
                 SET last_error = ?1,
                     dead_lettered_at = CASE WHEN ?1 LIKE 'permanent:%' OR ?1 LIKE 'protocol:%' THEN unixepoch() ELSE dead_lettered_at END
                 WHERE invite_id = ?2;",
                params![last_error, invite_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn claim_pending_welcome_attempt(
        &self,
        invite_id: &str,
        next_attempt_at: i64,
        last_error: Option<&str>,
        now_secs: i64,
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
                   AND next_attempt_at <= ?4
                   AND expires_at >= ?5;",
                params![next_attempt_at, last_error, invite_id, now_ms, now_secs],
            )
            .map_err(sqlite_error)?;
        Ok(changed > 0)
    }

    pub fn next_retry_deadline(
        &self,
        now_ms: i64,
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
        if let Some(deadline) = self.next_pending_welcome_retry_deadline_ms(now_secs)? {
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
        if let Some(deadline) = self.next_read_receipt_retry_deadline(now_ms)? {
            deadlines.push(RetryDeadline {
                kind: RetryKind::ReadReceipt,
                at_ms: deadline,
            });
        }
        if let Some(deadline) = self.next_peer_endpoint_bootstrap_retry_deadline_ms()? {
            deadlines.push(RetryDeadline {
                kind: RetryKind::PeerEndpointBootstrap,
                at_ms: deadline,
            });
        }
        if let Some(deadline) = self.next_pending_contact_confirmation_retry_deadline_ms()? {
            deadlines.push(RetryDeadline {
                kind: RetryKind::ContactConfirmation,
                at_ms: deadline,
            });
        }
        if let Some(deadline) = self.next_pending_pairing_acknowledgement_retry_deadline_ms()? {
            deadlines.push(RetryDeadline {
                kind: RetryKind::PairingAcknowledgement,
                at_ms: deadline,
            });
        }
        Ok(deadlines
            .into_iter()
            .map(|deadline| RetryDeadline {
                at_ms: deadline.at_ms.max(now_ms),
                ..deadline
            })
            .min_by_key(|deadline| deadline.at_ms))
    }

    pub fn next_message_retry_deadline_ms(&self) -> EngineResult<Option<i64>> {
        self.connection
            .query_row(
                "SELECT MIN(next_attempt_at) AS next_attempt_at
                 FROM messages
                 WHERE outgoing = 1
                   AND UPPER(state) IN ('SENDING', 'QUEUED');",
                [],
                |row| row.get("next_attempt_at"),
            )
            .map_err(sqlite_error)
    }

    pub fn next_receipt_retry_deadline_ms(&self) -> EngineResult<Option<i64>> {
        self.connection
            .query_row(
                "SELECT MIN(next_attempt_at) AS next_attempt_at
                 FROM delivery_receipts
                 WHERE UPPER(state) IN ('PENDING', 'SENT');",
                [],
                |row| row.get("next_attempt_at"),
            )
            .map_err(sqlite_error)
    }

    pub fn next_message_ack_deadline_ms(&self) -> EngineResult<Option<i64>> {
        self.connection
            .query_row(
                "SELECT MIN(ack_deadline) AS ack_deadline
                 FROM messages
                 WHERE outgoing = 1
                   AND UPPER(state) = 'SENT'
                   AND ack_deadline IS NOT NULL;",
                [],
                |row| row.get("ack_deadline"),
            )
            .map_err(sqlite_error)
    }

    pub fn next_pending_welcome_retry_deadline_ms(
        &self,
        now_secs: i64,
    ) -> EngineResult<Option<i64>> {
        self.connection
            .query_row(
                "SELECT MIN(next_attempt_at) AS next_attempt_at
                 FROM pending_welcomes
                 WHERE expires_at >= ?1;",
                [now_secs],
                |row| row.get("next_attempt_at"),
            )
            .map_err(sqlite_error)
    }

    pub fn next_pairing_response_retry_deadline_ms(
        &self,
        now_secs: i64,
    ) -> EngineResult<Option<i64>> {
        self.connection
            .query_row(
                "SELECT MIN(next_attempt_at) AS next_attempt_at
                 FROM pairing_inbox
                 WHERE expires_at >= ?1
                   AND response_delivered = 0
                   AND UPPER(state) IN ('ACCEPTED', 'REJECTED');",
                [now_secs],
                |row| row.get("next_attempt_at"),
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
                   AND response_delivered = 0
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
                   AND response_delivered = 0
                   AND UPPER(state) IN ('ACCEPTED', 'REJECTED')
                   AND next_attempt_at <= ?5;",
                params![next_attempt_at, last_error, pairing_id, now_secs, now_ms],
            )
            .map_err(sqlite_error)?;
        Ok(changed > 0)
    }

    pub fn complete_pairing_response(&self, pairing_id: &str) -> EngineResult<()> {
        self.connection
            .execute(
                "UPDATE pairing_inbox
                 SET response_delivered = 1,
                     next_attempt_at = 0,
                     last_error = NULL,
                     updated_at = unixepoch()
                 WHERE pairing_id = ?1;",
                [pairing_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
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
            .query_map([now_ms], |row| row.get("id"))
            .map_err(sqlite_error)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(sqlite_error)
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

fn sqlcipher_rekey_pragma(database_key: &[u8]) -> String {
    let mut hex = String::with_capacity(database_key.len() * 2);
    for byte in database_key {
        use std::fmt::Write as _;
        let _ = write!(&mut hex, "{byte:02x}");
    }
    format!("PRAGMA rekey = \"x'{hex}'\";")
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

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;

    fn temp_database_path(name: &str) -> PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock must be after unix epoch")
            .as_nanos();
        std::env::temp_dir().join(format!(
            "torchat-client-engine-{name}-{}-{nanos}.db",
            std::process::id()
        ))
    }

    fn key(byte: u8) -> SecretBytes {
        SecretBytes(vec![byte; 32])
    }

    #[test]
    fn open_requires_32_byte_database_key() {
        let path = temp_database_path("invalid-key");
        let result = ClientDatabase::open(&path, &SecretBytes(vec![1; 31]));

        assert!(matches!(result, Err(EngineError::InvalidConfig(_))));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn rekey_rotates_sqlcipher_key_and_old_key_no_longer_opens() {
        let path = temp_database_path("rekey");
        let old_key = key(41);
        let new_key = key(42);
        let mut database = ClientDatabase::open(&path, &old_key).expect("database opens");
        database
            .connection()
            .execute(
                "INSERT INTO settings (key, value) VALUES ('rekey-test', 'true');",
                [],
            )
            .expect("fixture should be written");
        database.rekey(&new_key).expect("rekey should verify");
        drop(database);

        assert!(ClientDatabase::open(&path, &old_key).is_err());
        let reopened = ClientDatabase::open(&path, &new_key).expect("new key opens database");
        let value: String = reopened
            .connection()
            .query_row(
                "SELECT value FROM settings WHERE key = 'rekey-test';",
                [],
                |row| row.get(0),
            )
            .expect("rekeyed data remains readable");
        assert_eq!(value, "true");
        drop(reopened);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn open_runs_all_migrations_with_correct_sqlcipher_key() {
        let path = temp_database_path("migrations");
        let database = ClientDatabase::open(&path, &key(7)).expect("database opens");

        let latest_version: i64 = database
            .connection()
            .query_row("SELECT MAX(version) FROM schema_migrations;", [], |row| {
                row.get("MAX(version)")
            })
            .expect("schema_migrations version is readable");

        assert_eq!(latest_version, 29);
        assert_eq!(database.migration_runner().checksum().len(), 64);

        drop(database);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn relationship_lifecycle_triggers_are_absent_after_current_migration() {
        let path = temp_database_path("relationship-trigger-removal");
        let database = ClientDatabase::open(&path, &key(71)).expect("database opens");
        let remaining: i64 = database
            .connection()
            .query_row(
                "SELECT COUNT(*)
                 FROM sqlite_master
                 WHERE type = 'trigger'
                   AND name IN (
                     'record_inserted_relationship_boundary',
                     'record_reactivated_relationship_boundary',
                     'ignore_stale_relationship_removal',
                     'apply_incoming_relationship_removal',
                     'suppress_removed_relationship_mls_insert',
                     'suppress_removed_relationship_mls_update',
                     'suppress_removed_contact_endpoint_insert',
                     'suppress_removed_contact_endpoint_update'
                   );",
                [],
                |row| row.get(0),
            )
            .expect("trigger inventory is readable");
        assert_eq!(remaining, 0);
        drop(database);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn processed_command_prune_keeps_fresh_rows_and_enforces_limit() {
        let path = temp_database_path("processed-command-prune");
        let database = ClientDatabase::open(&path, &key(8)).expect("database opens");
        for index in 0..5 {
            database
                .connection()
                .execute(
                    "INSERT INTO processed_commands
                     (command_id, command_type, result_json, committed_revision, created_at)
                     VALUES (?1, 'test', '{}', ?2, ?3);",
                    params![
                        format!("command-{index}"),
                        index as i64,
                        if index == 0 { 900 } else { 959 + index as i64 }
                    ],
                )
                .expect("processed command inserts");
        }

        assert!(
            database
                .load_processed_command("command-1")
                .expect("replay lookup succeeds")
                .is_some()
        );

        let removed = database
            .prune_processed_commands(1_000, 50, 3)
            .expect("prune succeeds");

        assert_eq!(removed, 2);
        let count: i64 = database
            .connection()
            .query_row("SELECT COUNT(*) FROM processed_commands;", [], |row| {
                row.get(0)
            })
            .expect("count is readable");
        assert_eq!(count, 3);
        let newest: String = database
            .connection()
            .query_row(
                "SELECT command_id FROM processed_commands ORDER BY created_at ASC LIMIT 1;",
                [],
                |row| row.get(0),
            )
            .expect("freshest retained command is readable");
        assert_eq!(newest, "command-2");
        assert!(
            database
                .load_processed_command("command-0")
                .expect("expired replay lookup succeeds")
                .is_none()
        );

        drop(database);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn read_receipt_outbox_is_idempotent_and_survives_reopen() {
        let path = temp_database_path("read-receipt-outbox");
        let database = ClientDatabase::open(&path, &key(10)).expect("database opens");
        database
            .connection()
            .execute_batch(
                "INSERT INTO contacts
                 (installation_id, nickname, public_key, fingerprint, verification, source)
                 VALUES ('peer-read', 'Peer', 'pk', 'fp', 'UNVERIFIED', 'test');
                 INSERT INTO conversations (id, contact_installation_id, state)
                 VALUES ('peer-read', 'peer-read', 'ESTABLISHED');",
            )
            .expect("contact and conversation exist");

        let first = database
            .enqueue_read_receipt(
                "peer-read",
                "peer-read",
                "[\"00000000-0000-0000-0000-000000000002\",\"00000000-0000-0000-0000-000000000001\"]",
                100,
                1_000,
            )
            .expect("first receipt is queued");
        let second = database
            .enqueue_read_receipt(
                "peer-read",
                "peer-read",
                "[\"00000000-0000-0000-0000-000000000001\",\"00000000-0000-0000-0000-000000000002\"]",
                200,
                1_001,
            )
            .expect("duplicate receipt is coalesced");
        assert_eq!(first, second);
        let reordered = database
            .enqueue_read_receipt(
                "peer-read",
                "peer-read",
                "[\"00000000-0000-0000-0000-000000000001\",\"00000000-0000-0000-0000-000000000002\"]",
                300,
                1_002,
            )
            .expect("same canonical batch remains coalesced");
        assert_eq!(first, reordered);
        assert_eq!(
            database
                .due_read_receipts(1_001)
                .expect("due receipts")
                .len(),
            1
        );

        database
            .persist_read_receipt_encryption(&first, b"wire", "peer-read", b"snapshot", 2_000)
            .expect("encrypted receipt is persisted");
        drop(database);

        let reopened = ClientDatabase::open(&path, &key(10)).expect("database reopens");
        let stored = reopened
            .due_read_receipts(2_000)
            .expect("receipt survives reopen")
            .pop()
            .expect("stored receipt exists");
        assert_eq!(stored.receipt_id, first);
        assert_eq!(stored.wire_ciphertext.as_deref(), Some(b"wire".as_slice()));
        assert_eq!(stored.read_at, 300);
        let looked_up = reopened
            .read_receipt(&first)
            .expect("direct receipt lookup succeeds")
            .expect("receipt remains addressable after reopen");
        assert_eq!(looked_up.attempt_count, stored.attempt_count);
        reopened
            .requeue_read_receipt(&first, 3_000, "relay retry")
            .expect("receipt can be requeued by id");
        assert_eq!(
            reopened
                .read_receipt(&first)
                .expect("requeued receipt lookup succeeds")
                .expect("requeued receipt exists")
                .last_error
                .as_deref(),
            Some("relay retry")
        );

        drop(reopened);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn local_invite_mls_state_is_isolated_by_invite_id() {
        let path = temp_database_path("invite-mls");
        let database = ClientDatabase::open(&path, &key(9)).expect("database opens");
        for (invite_id, snapshot) in [("invite-a", vec![1, 2]), ("invite-b", vec![3, 4])] {
            database
                .put_pending_local_invite_mls(&PendingLocalInviteMlsRecord {
                    invite_id: invite_id.to_owned(),
                    recipient_installation_id: None,
                    snapshot,
                    expires_at: unix_secs() + 60,
                })
                .expect("invite state persists");
        }

        assert_eq!(
            database
                .pending_local_invite_mls("invite-a", unix_secs())
                .unwrap()
                .unwrap()
                .snapshot,
            vec![1, 2]
        );
        assert_eq!(
            database
                .pending_local_invite_mls("invite-b", unix_secs())
                .unwrap()
                .unwrap()
                .snapshot,
            vec![3, 4]
        );

        drop(database);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn opening_version_7_database_applies_contact_transport_policy_migration() {
        let path = temp_database_path("migration-7-to-8");
        let database_key = key(17);
        let connection = Connection::open(&path).expect("database file opens");
        connection
            .execute_batch(&sqlcipher_key_pragma(database_key.expose()))
            .expect("database key applies");
        connection
            .execute_batch(CONNECTION_PRAGMAS)
            .expect("connection pragmas apply");
        MigrationRunner::new(&MIGRATIONS[..8])
            .run(&connection)
            .expect("version 7 migrations apply");
        connection
            .execute(
                "INSERT INTO contacts (
                    installation_id, nickname, public_key, fingerprint,
                    verification, source, created_at, updated_at
                 ) VALUES (
                    'contact-1', 'Alice', 'pk', 'fp',
                    'VERIFIED', 'PAIRING', 1, 1
                 );",
                [],
            )
            .expect("contact inserts");
        drop(connection);

        let database =
            ClientDatabase::open(&path, &database_key).expect("version 8 database opens");
        let policy: String = database
            .connection()
            .query_row(
                "SELECT transport_policy FROM contacts WHERE installation_id = 'contact-1';",
                [],
                |row| row.get(0),
            )
            .expect("transport policy is readable");
        let latest_version: i64 = database
            .connection()
            .query_row("SELECT MAX(version) FROM schema_migrations;", [], |row| {
                row.get(0)
            })
            .expect("latest migration is readable");

        assert_eq!(policy, "PEER_ONLY");
        assert_eq!(latest_version, 29);
        drop(database);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn reopen_with_wrong_sqlcipher_key_fails_integrity_check() {
        let path = temp_database_path("wrong-key");
        let database = ClientDatabase::open(&path, &key(11)).expect("database opens");
        drop(database);

        let result = ClientDatabase::open(&path, &key(12));

        assert!(matches!(result, Err(EngineError::Storage(_))));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn refreshing_peer_endpoint_bootstrap_resets_retry_metadata() {
        let path = temp_database_path("peer-endpoint-bootstrap-reset");
        let database = ClientDatabase::open(&path, &key(21)).expect("database opens");
        database
            .connection()
            .execute(
                "INSERT INTO contacts (
                    installation_id, nickname, public_key, fingerprint,
                    verification, source, created_at, updated_at, transport_policy
                 ) VALUES (
                    'contact-1', 'Alice', 'pk', 'fp',
                    'VERIFIED', 'PAIRING', 1, 1, 'PEER_ONLY'
                 );",
                [],
            )
            .expect("contact inserts");

        database
            .put_peer_endpoint_bootstrap("contact-1", b"payload-a", 1)
            .expect("bootstrap inserts");
        assert!(
            database
                .claim_peer_endpoint_bootstrap_attempt("contact-1", 1, 12345, Some("timeout"))
                .expect("claim works")
        );

        database
            .put_peer_endpoint_bootstrap("contact-1", b"payload-b", 2)
            .expect("bootstrap refreshes");

        let record = database
            .due_peer_endpoint_bootstraps(0)
            .expect("bootstrap rows are readable")
            .into_iter()
            .find(|row| row.contact_installation_id == "contact-1")
            .expect("bootstrap row exists");

        assert_eq!(record.endpoint_sequence, 2);
        assert_eq!(record.attempt_count, 0);
        assert_eq!(record.next_attempt_at, 0);
        assert_eq!(record.last_error, None);
        assert_eq!(record.payload, b"payload-b");

        drop(database);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn refreshing_pending_contact_confirmation_resets_retry_metadata() {
        let path = temp_database_path("contact-confirmation-reset");
        let database = ClientDatabase::open(&path, &key(22)).expect("database opens");

        database
            .put_pending_contact_confirmation("pairing-1", "peer-1", "cap-a")
            .expect("confirmation inserts");
        assert!(
            database
                .claim_pending_contact_confirmation_attempt(
                    "pairing-1",
                    12345,
                    Some("relay unavailable"),
                )
                .expect("claim works")
        );

        database
            .put_pending_contact_confirmation("pairing-1", "peer-1", "cap-b")
            .expect("confirmation refreshes");

        let record = database
            .due_pending_contact_confirmations(0)
            .expect("confirmation rows are readable")
            .into_iter()
            .find(|row| row.pairing_id == "pairing-1")
            .expect("confirmation row exists");

        assert_eq!(record.peer_installation_id, "peer-1");
        assert_eq!(record.capability, "cap-b");
        assert_eq!(record.attempt_count, 0);
        assert_eq!(record.next_attempt_at, 0);
        assert_eq!(record.last_error, None);

        drop(database);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn recording_peer_endpoint_bootstrap_error_updates_last_error() {
        let path = temp_database_path("peer-endpoint-bootstrap-error");
        let database = ClientDatabase::open(&path, &key(24)).expect("database opens");
        database
            .connection()
            .execute(
                "INSERT INTO contacts (
                    installation_id, nickname, public_key, fingerprint,
                    verification, source, created_at, updated_at, transport_policy
                 ) VALUES (
                    'contact-1', 'Alice', 'pk', 'fp',
                    'VERIFIED', 'PAIRING', 1, 1, 'PEER_ONLY'
                 );",
                [],
            )
            .expect("contact inserts");

        database
            .put_peer_endpoint_bootstrap("contact-1", b"payload-a", 1)
            .expect("bootstrap inserts");
        database
            .record_peer_endpoint_bootstrap_error("contact-1", 1, "protocol: malformed payload")
            .expect("error persists");

        assert!(
            database
                .due_peer_endpoint_bootstraps(0)
                .expect("bootstrap rows are readable")
                .is_empty()
        );
        let dead_letters = database.dead_letters().expect("dead letters are listed");
        assert_eq!(dead_letters.len(), 1);
        assert_eq!(dead_letters[0].kind, "endpoint_bootstrap");

        assert!(
            database
                .retry_dead_letter("endpoint_bootstrap", "contact-1")
                .expect("dead letter retry succeeds")
        );
        let record = database
            .due_peer_endpoint_bootstraps(0)
            .expect("retried bootstrap is readable")
            .into_iter()
            .find(|row| row.contact_installation_id == "contact-1")
            .expect("retried bootstrap row exists");
        assert_eq!(
            record.last_error.as_deref(),
            Some("protocol: malformed payload")
        );

        drop(database);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn next_contact_peer_retry_deadline_uses_contact_installation_id() {
        let path = temp_database_path("peer-retry-deadline");
        let database = ClientDatabase::open(&path, &key(31)).expect("database opens");
        database
            .connection()
            .execute_batch(
                "INSERT INTO contacts (
                    installation_id, nickname, public_key, fingerprint,
                    verification, source, created_at, updated_at, transport_policy
                 ) VALUES
                    ('contact-1', 'Alice', 'pk-1', 'fp-1', 'VERIFIED', 'PAIRING', 1, 1, 'PEER_ONLY'),
                    ('contact-2', 'Bob', 'pk-2', 'fp-2', 'VERIFIED', 'PAIRING', 1, 1, 'PEER_ONLY');
                 INSERT INTO conversations (
                    id, contact_installation_id, state, unread_count, last_message_preview,
                    last_message_at, created_at, updated_at
                 ) VALUES
                    ('conversation-1', 'contact-1', 'ACTIVE', 0, NULL, NULL, 1, 1),
                    ('conversation-2', 'contact-2', 'ACTIVE', 0, NULL, NULL, 1, 1);
                 INSERT INTO messages (
                    id, conversation_id, outgoing, body, state, created_at,
                    relay_payload, ciphertext_hash, attempt_count, last_attempt_at,
                    next_attempt_at, ack_deadline, last_transport_error
                 ) VALUES
                    ('message-1', 'conversation-1', 1, 'hello', 'QUEUED', 100, NULL, NULL, 0, NULL, 0, NULL, NULL),
                    ('message-2', 'conversation-2', 1, 'hello', 'QUEUED', 200, NULL, NULL, 0, NULL, 0, NULL, NULL);
                 INSERT INTO outbound_deliveries (
                    message_id, contact_installation_id, sequence, state,
                    attempt_count, next_attempt_at, created_at, updated_at
                 ) VALUES
                    ('message-1', 'contact-1', 1, 'QUEUED', 0, 3456, 100, unixepoch()),
                    ('message-2', 'contact-2', 1, 'QUEUED', 0, 7890, 200, unixepoch());",
            )
            .expect("contact, message and delivery fixtures insert");

        let deadline = database
            .next_contact_peer_retry_deadline_ms("contact-1")
            .expect("deadline query succeeds");

        assert_eq!(deadline, Some(3456));

        drop(database);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn recording_pending_contact_confirmation_error_updates_last_error() {
        let path = temp_database_path("contact-confirmation-error");
        let database = ClientDatabase::open(&path, &key(23)).expect("database opens");

        database
            .put_pending_contact_confirmation("pairing-1", "peer-1", "cap-a")
            .expect("confirmation inserts");
        database
            .record_pending_contact_confirmation_error("pairing-1", "relay unavailable")
            .expect("error persists");

        let record = database
            .due_pending_contact_confirmations(0)
            .expect("confirmation rows are readable")
            .into_iter()
            .find(|row| row.pairing_id == "pairing-1")
            .expect("confirmation row exists");

        assert_eq!(record.last_error.as_deref(), Some("relay unavailable"));

        drop(database);
        let _ = std::fs::remove_file(path);
    }
}
