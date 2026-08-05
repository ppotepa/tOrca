use std::{
    collections::HashSet,
    path::Path,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use rusqlite::{Connection, OptionalExtension, params};
use sha2::Digest;
use torchat_core::peer_protocol::{PeerEndpointBundle, PeerEndpointUpdate, PeerMessageEnvelope};
use torchat_runtime::CapabilityStatus;
use uuid::Uuid;
use zeroize::Zeroizing;

use crate::{EngineError, EngineResult, SecretBytes};

use super::{MigrationRunner, transaction::SqliteTransaction};

pub type ContactEndpointCapability = (String, Vec<u8>, u64, CapabilityStatus);

const RELATIONSHIP_REMOVAL_MAX_ATTEMPTS: i64 = 8;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RelationshipRemovalOutboxRecord {
    pub removal_id: String,
    pub contact_installation_id: String,
    pub removed_at: i64,
    pub relationship_epoch: i64,
    pub preserve_history: bool,
    pub attempt_count: u32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RelationshipRemovalAckOutboxRecord {
    pub removal_id: String,
    pub contact_installation_id: String,
    pub payload: Vec<u8>,
    pub attempt_count: u32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MlsCheckpointRecord {
    pub conversation_id: String,
    pub snapshot: Vec<u8>,
    pub state_version: u64,
    pub snapshot_hash: Option<Vec<u8>>,
}

pub struct ClientDatabase {
    connection: Connection,
    migration_runner: MigrationRunner,
}

pub(crate) mod affected_rows;
mod messages;
mod migrations;
mod pairing;
mod peer_endpoints;
mod projection;
mod read_receipts;
mod receipts;
mod records;
pub(crate) mod sql_catalog;
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
                sql_catalog::delivery::RECORD_DEAD_LETTER,
                rusqlite::params![kind, item_id, contact_installation_id, attempt_count, error],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn record_contact_seen(&self, contact_id: &str, observed_at: i64) -> EngineResult<()> {
        self.connection
            .execute(
                sql_catalog::contacts::RECORD_SEEN,
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
        let key = sqlcipher_key_value(database_key.expose());
        connection
            .pragma_update(None, "key", &*key)
            .map_err(sqlite_error)?;
        connection
            .pragma_update(None, "foreign_keys", true)
            .map_err(sqlite_error)?;
        connection
            .pragma_update(None, "journal_mode", "WAL")
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
            .query_row(sql_catalog::projection::HAS_SCHEMA_MIGRATIONS, [], |row| {
                row.get::<_, i64>(0)
            })
            .map_err(sqlite_error)?
            != 0;
        let has_client_tables = connection
            .query_row(sql_catalog::projection::HAS_CLIENT_TABLES, [], |row| {
                row.get::<_, i64>(0)
            })
            .map_err(sqlite_error)?
            != 0;
        if !has_schema_migrations && has_client_tables {
            return Err(EngineError::Storage(
                "unversioned client database detected; run deploy-clean or reset the client database"
                    .to_owned(),
            ));
        }
        let migration_runner = MigrationRunner::new(MIGRATIONS);
        migration_runner.run(&connection)?;
        // The base schema owns the projection singleton. Keep this repair
        // idempotent so databases created by the first flattened-schema build
        // (which lacked the seed row) can recover without losing local data.
        connection
            .execute(
                include_str!("../../../sql/commands/metadata/ensure_projection_singleton.sql"),
                [],
            )
            .map_err(sqlite_error)?;
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

    /// Temporary compatibility surface for migration tests; production callers
    /// must use typed repository methods. It will be removed with REF2-08.
    pub fn connection(&self) -> &Connection {
        &self.connection
    }

    /// Rotate the SQLCipher key while the database is open under its current
    /// key. Callers must persist the new key only after this returns success.
    pub fn rekey(&mut self, new_key: &SecretBytes) -> EngineResult<()> {
        if new_key.expose().len() != 32 {
            return Err(EngineError::InvalidConfig(
                "databaseKey must contain exactly 32 bytes".to_owned(),
            ));
        }
        let key = sqlcipher_key_value(new_key.expose());
        self.connection
            .pragma_update(None, "rekey", &*key)
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
            .prepare(sql_catalog::relationships::DUE_REMOVALS)
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
                sql_catalog::relationships::MARK_REMOVAL_DISPATCHED,
                rusqlite::params![
                    removal_id,
                    next_attempt_at,
                    RELATIONSHIP_REMOVAL_MAX_ATTEMPTS
                ],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn complete_relationship_removal_ack(&self, removal_id: &str) -> EngineResult<()> {
        self.connection
            .execute(
                sql_catalog::relationships::COMPLETE_REMOVAL_ACK,
                [removal_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn retry_relationship_removal_dead_letter(&self, removal_id: &str) -> EngineResult<()> {
        self.connection
            .execute(
                sql_catalog::relationships::DEAD_LETTER_REMOVAL,
                [removal_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn due_relationship_removal_acks(
        &self,
        now_ms: i64,
    ) -> EngineResult<Vec<RelationshipRemovalAckOutboxRecord>> {
        let mut statement = self
            .connection
            .prepare(sql_catalog::relationships::DUE_REMOVAL_ACKS)
            .map_err(sqlite_error)?;
        statement
            .query_map([now_ms], |row| {
                Ok(RelationshipRemovalAckOutboxRecord {
                    removal_id: row.get(0)?,
                    contact_installation_id: row.get(1)?,
                    payload: row.get(2)?,
                    attempt_count: row.get::<_, i64>(3)?.max(0) as u32,
                })
            })
            .map_err(sqlite_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sqlite_error)
    }

    pub fn mark_relationship_removal_ack_dispatched(
        &self,
        removal_id: &str,
        next_attempt_at: i64,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                sql_catalog::relationships::MARK_REMOVAL_ACK_DISPATCHED,
                params![
                    removal_id,
                    next_attempt_at,
                    RELATIONSHIP_REMOVAL_MAX_ATTEMPTS
                ],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn complete_relationship_removal_ack_delivery(&self, removal_id: &str) -> EngineResult<()> {
        self.connection
            .execute(
                sql_catalog::relationships::COMPLETE_REMOVAL_ACK_DELIVERY,
                [removal_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn retry_relationship_removal_ack_dead_letter(&self, removal_id: &str) -> EngineResult<()> {
        self.connection
            .execute(
                sql_catalog::relationships::DEAD_LETTER_REMOVAL_ACK,
                [removal_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn conversation_mls_snapshots(&self) -> EngineResult<Vec<(String, Vec<u8>)>> {
        let mut statement = self
            .connection
            .prepare(sql_catalog::mls::LIST_SNAPSHOTS)
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
            .query_row(sql_catalog::mls::GET_SNAPSHOT, [conversation_id], |row| {
                row.get("snapshot")
            })
            .optional()
            .map_err(sqlite_error)
    }

    pub fn conversation_mls_checkpoint(
        &self,
        conversation_id: &str,
    ) -> EngineResult<Option<MlsCheckpointRecord>> {
        self.connection
            .query_row(sql_catalog::mls::GET_CHECKPOINT, [conversation_id], |row| {
                Ok(MlsCheckpointRecord {
                    conversation_id: row.get(0)?,
                    snapshot: row.get(1)?,
                    state_version: row.get::<_, i64>(2)?.max(0) as u64,
                    snapshot_hash: row.get(3)?,
                })
            })
            .optional()
            .map_err(sqlite_error)
    }

    pub fn put_conversation_mls_snapshot(
        &self,
        conversation_id: &str,
        snapshot: &[u8],
    ) -> EngineResult<()> {
        let snapshot_hash = sha2::Sha256::digest(snapshot).to_vec();
        self.connection
            .execute(
                sql_catalog::mls::UPSERT_SNAPSHOT_FROM_DATABASE,
                params![conversation_id, snapshot, snapshot_hash],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn delete_conversation_mls_snapshot(&self, conversation_id: &str) -> EngineResult<()> {
        self.connection
            .execute(sql_catalog::mls::DELETE_SNAPSHOT, [conversation_id])
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn put_pending_application_envelope(
        &self,
        record: &PendingApplicationEnvelopeRecord,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                include_str!(
                    "../../../sql/commands/projection/put_pending_application_envelope_1.sql"
                ),
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
            .prepare(include_str!(
                "../../../sql/queries/projection/pending_application_envelopes_1.sql"
            ))
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
                include_str!(
                    "../../../sql/commands/projection/remove_pending_application_envelope_1.sql"
                ),
                params![sender_installation_id, message_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn put_capability_delivery(&self, record: &CapabilityDeliveryRecord) -> EngineResult<()> {
        self.connection
            .execute(
                sql_catalog::capabilities::PUT_DELIVERY,
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
            .prepare(sql_catalog::capabilities::DUE_DELIVERIES)
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
                sql_catalog::capabilities::HAS_DELIVERY_FOR_CONTACT,
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
                sql_catalog::capabilities::CLAIM_DELIVERY,
                params![next_attempt_at, last_error, delivery_id, unix_ms()],
            )
            .map_err(sqlite_error)?;
        Ok(changed > 0)
    }

    pub fn complete_capability_delivery(&self, delivery_id: &str) -> EngineResult<()> {
        self.connection
            .execute(sql_catalog::capabilities::COMPLETE_DELIVERY, [delivery_id])
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn complete_capability_deliveries_for_contact(
        &self,
        contact_installation_id: &str,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                sql_catalog::capabilities::COMPLETE_CONTACT_DELIVERIES,
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
                include_str!("../../../sql/commands/delivery/retry_dead_letter_1.sql"),
                [id],
            ),
            "welcome" => self.connection.execute(
                include_str!("../../../sql/commands/delivery/retry_dead_letter_4.sql"),
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
        let mut statement = self
            .connection
            .prepare(include_str!(
                "../../../sql/queries/delivery/dead_letters_1.sql"
            ))
            .map_err(sqlite_error)?;
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
                sql_catalog::capabilities::RECORD_DELIVERY_ERROR,
                params![next_attempt_at, error, delivery_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn invite_used(&self, invite_id: &str) -> EngineResult<bool> {
        self.connection
            .query_row(sql_catalog::pairing::INVITE_USED, [invite_id], |row| {
                row.get::<_, i64>("used")
            })
            .map(|used| used != 0)
            .map_err(sqlite_error)
    }

    pub fn consume_invite(&self, invite_id: &str) -> EngineResult<bool> {
        let inserted = self
            .connection
            .execute(sql_catalog::pairing::CONSUME_INVITE, [invite_id])
            .map_err(sqlite_error)?;
        Ok(inserted > 0)
    }

    pub fn message(&self, message_id: &str) -> EngineResult<Option<StoredMessageRecord>> {
        self.connection
            .query_row(sql_catalog::messages::GET_BY_ID, [message_id], |row| {
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
            })
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
                sql_catalog::projection::PERSIST_ENCRYPTION,
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
                sql_catalog::projection::SET_ACK_DEADLINE,
                params![ack_deadline, message_id],
            )
            .map_err(sqlite_error)?;
        transaction
            .execute(
                sql_catalog::projection::CLAIM_ENCRYPTED_MESSAGE,
                params![
                    conversation_id,
                    snapshot,
                    sha2::Sha256::digest(snapshot).to_vec()
                ],
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
                sql_catalog::projection::CLAIM_OUTGOING_ATTEMPT,
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
                    sql_catalog::projection::SET_OUTGOING_ACK_DEADLINE,
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
                sql_catalog::projection::REQUEUE_DISCONNECTED_DELIVERIES,
                [now_ms],
            )
            .map_err(sqlite_error)?;
        transaction
            .execute(
                sql_catalog::projection::REQUEUE_DISCONNECTED_ACKS,
                params![now_ms],
            )
            .map_err(sqlite_error)?;
        transaction.commit().map_err(sqlite_error)?;
        Ok(())
    }

    pub fn delete_expired_pending_welcomes(&self, now_secs: i64) -> EngineResult<usize> {
        self.connection
            .execute(
                include_str!("../../../sql/commands/pairing/delete_expired_pending_welcomes_1.sql"),
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
            .prepare(include_str!(
                "../../../sql/queries/pairing/due_pending_welcomes_1.sql"
            ))
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
                include_str!("../../../sql/commands/pairing/record_pending_welcome_error_1.sql"),
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
                include_str!("../../../sql/commands/pairing/claim_pending_welcome_attempt_1.sql"),
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
        if let Some(deadline) = self.next_relationship_removal_retry_deadline_ms()? {
            deadlines.push(RetryDeadline {
                kind: RetryKind::RelationshipRemoval,
                at_ms: deadline,
            });
        }
        if let Some(deadline) = self.next_relationship_removal_ack_retry_deadline_ms()? {
            deadlines.push(RetryDeadline {
                kind: RetryKind::RelationshipRemovalAck,
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
                include_str!("../../../sql/queries/messages/next_message_retry_deadline_ms_1.sql"),
                [],
                |row| row.get("next_attempt_at"),
            )
            .map_err(sqlite_error)
    }

    fn next_relationship_removal_retry_deadline_ms(&self) -> EngineResult<Option<i64>> {
        self.connection
            .query_row(
                include_str!("../../../sql/queries/relationships/next_relationship_removal_retry_deadline_ms_1.sql"),
                [],
                |row| row.get(0),
            )
            .map_err(sqlite_error)
    }

    fn next_relationship_removal_ack_retry_deadline_ms(&self) -> EngineResult<Option<i64>> {
        self.connection
            .query_row(
                include_str!("../../../sql/queries/relationships/next_relationship_removal_ack_retry_deadline_ms_1.sql"),
                [],
                |row| row.get(0),
            )
            .map_err(sqlite_error)
    }

    pub fn next_receipt_retry_deadline_ms(&self) -> EngineResult<Option<i64>> {
        self.connection
            .query_row(
                include_str!("../../../sql/queries/receipts/next_receipt_retry_deadline_ms_1.sql"),
                [],
                |row| row.get("next_attempt_at"),
            )
            .map_err(sqlite_error)
    }

    pub fn next_message_ack_deadline_ms(&self) -> EngineResult<Option<i64>> {
        self.connection
            .query_row(
                include_str!("../../../sql/queries/messages/next_message_ack_deadline_ms_1.sql"),
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
                include_str!(
                    "../../../sql/queries/pairing/next_pending_welcome_retry_deadline_ms_1.sql"
                ),
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
                include_str!(
                    "../../../sql/queries/pairing/next_pairing_response_retry_deadline_ms_1.sql"
                ),
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
                include_str!("../../../sql/queries/pairing/pairing_response_retry_record_1.sql"),
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
                include_str!("../../../sql/commands/pairing/claim_pairing_response_attempt_1.sql"),
                params![next_attempt_at, last_error, pairing_id, now_secs, now_ms],
            )
            .map_err(sqlite_error)?;
        Ok(changed > 0)
    }

    pub fn complete_pairing_response(&self, pairing_id: &str) -> EngineResult<()> {
        self.connection
            .execute(
                include_str!("../../../sql/commands/pairing/complete_pairing_response_1.sql"),
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
                include_str!("../../../sql/commands/pairing/record_pairing_response_error_1.sql"),
                params![last_error, pairing_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn expired_ack_deadline_message_ids(&self, now_ms: i64) -> EngineResult<Vec<String>> {
        let mut statement = self
            .connection
            .prepare(include_str!(
                "../../../sql/queries/messages/expired_ack_deadline_message_ids_1.sql"
            ))
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

fn sqlcipher_key_value(database_key: &[u8]) -> Zeroizing<String> {
    let mut hex = Zeroizing::new(String::with_capacity(database_key.len() * 2));
    for byte in database_key {
        use std::fmt::Write as _;
        let _ = write!(&mut hex, "{byte:02x}");
    }
    Zeroizing::new(format!("x'{}'", hex.as_str()))
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
                include_str!("../../../../../packages/torchat-client-engine/tests/sql/storage/rekey_rotates_sqlcipher_key_and_old_key_no_longer_opens_1.sql"),
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
                include_str!("../../../../../packages/torchat-client-engine/tests/sql/storage/rekey_rotates_sqlcipher_key_and_old_key_no_longer_opens_2.sql"),
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
            .query_row(include_str!("../../../../../packages/torchat-client-engine/tests/sql/storage/open_runs_all_migrations_with_correct_sqlcipher_key_1.sql"), [], |row| {
                row.get("MAX(version)")
            })
            .expect("schema_migrations version is readable");

        assert_eq!(latest_version, MIGRATIONS.last().unwrap().version);
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
                include_str!("../../../../../packages/torchat-client-engine/tests/sql/storage/relationship_lifecycle_triggers_are_absent_after_current_migration_1.sql"),
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
                    include_str!("../../../../../packages/torchat-client-engine/tests/sql/storage/processed_command_prune_keeps_fresh_rows_and_enforces_limit_1.sql"),
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
            .query_row(include_str!("../../../../../packages/torchat-client-engine/tests/sql/storage/processed_command_prune_keeps_fresh_rows_and_enforces_limit_2.sql"), [], |row| {
                row.get(0)
            })
            .expect("count is readable");
        assert_eq!(count, 3);
        let newest: String = database
            .connection()
            .query_row(
                include_str!("../../../../../packages/torchat-client-engine/tests/sql/storage/processed_command_prune_keeps_fresh_rows_and_enforces_limit_3.sql"),
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
                include_str!("../../../../../packages/torchat-client-engine/tests/sql/storage/read_receipt_outbox_is_idempotent_and_survives_reopen_1.sql"),
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
                    local_capability_id: "1234567890abcdef".to_owned(),
                    local_capability_secret: vec![9; 16],
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
        let stored = database
            .pending_local_invite_mls("invite-a", unix_secs())
            .unwrap()
            .unwrap();
        assert_eq!(stored.local_capability_id, "1234567890abcdef");
        assert_eq!(stored.local_capability_secret, vec![9; 16]);
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
    fn reopen_with_wrong_sqlcipher_key_fails_integrity_check() {
        let path = temp_database_path("wrong-key");
        let database = ClientDatabase::open(&path, &key(11)).expect("database opens");
        drop(database);

        let result = ClientDatabase::open(&path, &key(12));

        assert!(matches!(result, Err(EngineError::Storage(_))));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn next_contact_peer_retry_deadline_uses_contact_installation_id() {
        let path = temp_database_path("peer-retry-deadline");
        let database = ClientDatabase::open(&path, &key(31)).expect("database opens");
        database
            .connection()
            .execute_batch(
                include_str!("../../../../../packages/torchat-client-engine/tests/sql/storage/next_contact_peer_retry_deadline_uses_contact_installation_id_1.sql"),
            )
            .expect("contact, message and delivery fixtures insert");

        let deadline = database
            .next_contact_peer_retry_deadline_ms("contact-1")
            .expect("deadline query succeeds");

        assert_eq!(deadline, Some(3456));

        drop(database);
        let _ = std::fs::remove_file(path);
    }
}
