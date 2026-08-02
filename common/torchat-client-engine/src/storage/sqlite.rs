use std::{collections::HashSet, path::Path, time::Duration};

use rusqlite::{Connection, OptionalExtension, params};
use sha2::Digest;
use torchat_core::peer_protocol::{PeerEndpointBundle, PeerEndpointUpdate, PeerMessageEnvelope};

use crate::{EngineError, EngineResult, config::SecretBytes};

use super::{Migration, MigrationRunner, transaction::SqliteTransaction};

pub const MIGRATION_LOOKUP: &str = include_str!("../../sql/queries/migration_lookup.sql");
pub const MIGRATION_INSERT: &str = include_str!("../../sql/queries/migration_insert.sql");
pub const TABLE_COLUMNS: &str = include_str!("../../sql/queries/table_columns.sql");
pub const CONNECTION_PRAGMAS: &str = include_str!("../../sql/queries/connection_pragmas.sql");

// Development/0.x databases are recreated by deploy-clean. Keep their
// initial schema as one deterministic batch so a fresh Android or desktop
// client cannot observe a partially applied migration chain. The historical
// migration table is still populated with the same versions, which lets an
// existing 0.x database remain readable until the first explicit reset.
pub const BASELINE_SCHEMA: &str = concat!(
    include_str!("../../sql/migrations/000_schema_migrations.sql"),
    "\n",
    include_str!("../../sql/migrations/001_canonical_client.sql"),
    "\n",
    include_str!("../../sql/migrations/002_pairing_inbox_retry.sql"),
    "\n",
    include_str!("../../sql/migrations/003_pairing_response_delivery.sql"),
    "\n",
    include_str!("../../sql/migrations/004_retry_indexes.sql"),
    "\n",
    include_str!("../../sql/migrations/005_message_replies.sql"),
    "\n",
    include_str!("../../sql/migrations/006_contact_preferences.sql"),
    "\n",
    include_str!("../../sql/migrations/007_peer_p2p.sql"),
    "\n",
    include_str!("../../sql/migrations/008_contact_transport_policy.sql"),
    "\n",
    include_str!("../../sql/migrations/009_peer_endpoint_bootstrap_outbox.sql"),
    "\n",
    include_str!("../../sql/migrations/010_pending_contact_confirmations.sql"),
    "\n",
    include_str!("../../sql/migrations/011_pending_pairing_acknowledgements.sql"),
    "\n",
    include_str!("../../sql/migrations/012_pending_peer_endpoint_inbox.sql"),
    "\n",
    include_str!("../../sql/migrations/013_default_peer_transport.sql"),
    "\n",
    include_str!("../../sql/migrations/014_runtime_integrity.sql"),
    "\n",
    include_str!("../../sql/migrations/015_pairing_mls_state.sql"),
    "\n",
    include_str!("../../sql/migrations/016_projection_consistency.sql"),
    "\n",
    "INSERT OR IGNORE INTO schema_migrations (version, name) VALUES ",
    "(0, '000_schema_migrations.sql'),",
    "(1, '001_canonical_client.sql'),",
    "(2, '002_pairing_inbox_retry.sql'),",
    "(3, '003_pairing_response_delivery.sql'),",
    "(4, '004_retry_indexes.sql'),",
    "(5, '005_message_replies.sql'),",
    "(6, '006_contact_preferences.sql'),",
    "(7, '007_peer_p2p.sql'),",
    "(8, '008_contact_transport_policy.sql'),",
    "(9, '009_peer_endpoint_bootstrap_outbox.sql'),",
    "(10, '010_pending_contact_confirmations.sql'),",
    "(11, '011_pending_pairing_acknowledgements.sql'),",
    "(12, '012_pending_peer_endpoint_inbox.sql'),",
    "(13, '013_default_peer_transport.sql'),",
    "(14, '014_runtime_integrity.sql'),",
    "(15, '015_pairing_mls_state.sql'),",
    "(16, '016_projection_consistency.sql');"
);

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
    Migration {
        version: 3,
        name: "003_pairing_response_delivery.sql",
        sql: include_str!("../../sql/migrations/003_pairing_response_delivery.sql"),
    },
    Migration {
        version: 4,
        name: "004_retry_indexes.sql",
        sql: include_str!("../../sql/migrations/004_retry_indexes.sql"),
    },
    Migration {
        version: 5,
        name: "005_message_replies.sql",
        sql: include_str!("../../sql/migrations/005_message_replies.sql"),
    },
    Migration {
        version: 6,
        name: "006_contact_preferences.sql",
        sql: include_str!("../../sql/migrations/006_contact_preferences.sql"),
    },
    Migration {
        version: 7,
        name: "007_peer_p2p.sql",
        sql: include_str!("../../sql/migrations/007_peer_p2p.sql"),
    },
    Migration {
        version: 8,
        name: "008_contact_transport_policy.sql",
        sql: include_str!("../../sql/migrations/008_contact_transport_policy.sql"),
    },
    Migration {
        version: 9,
        name: "009_peer_endpoint_bootstrap_outbox.sql",
        sql: include_str!("../../sql/migrations/009_peer_endpoint_bootstrap_outbox.sql"),
    },
    Migration {
        version: 10,
        name: "010_pending_contact_confirmations.sql",
        sql: include_str!("../../sql/migrations/010_pending_contact_confirmations.sql"),
    },
    Migration {
        version: 11,
        name: "011_pending_pairing_acknowledgements.sql",
        sql: include_str!("../../sql/migrations/011_pending_pairing_acknowledgements.sql"),
    },
    Migration {
        version: 12,
        name: "012_pending_peer_endpoint_inbox.sql",
        sql: include_str!("../../sql/migrations/012_pending_peer_endpoint_inbox.sql"),
    },
    Migration {
        version: 13,
        name: "013_default_peer_transport.sql",
        sql: include_str!("../../sql/migrations/013_default_peer_transport.sql"),
    },
    Migration {
        version: 14,
        name: "014_runtime_integrity.sql",
        sql: include_str!("../../sql/migrations/014_runtime_integrity.sql"),
    },
    Migration {
        version: 15,
        name: "015_pairing_mls_state.sql",
        sql: include_str!("../../sql/migrations/015_pairing_mls_state.sql"),
    },
    Migration {
        version: 16,
        name: "016_projection_consistency.sql",
        sql: include_str!("../../sql/migrations/016_projection_consistency.sql"),
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
pub struct PendingLocalInviteMlsRecord {
    pub invite_id: String,
    pub recipient_installation_id: Option<String>,
    pub snapshot: Vec<u8>,
    pub expires_at: i64,
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
    pub wire_ciphertext: Option<Vec<u8>>,
    pub ciphertext_hash: Option<Vec<u8>>,
    pub attempt_count: u32,
    pub last_attempt_at: Option<i64>,
    pub next_attempt_at: i64,
    pub ack_deadline: Option<i64>,
    pub last_transport_error: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OutboundDeliveryRecord {
    pub message_id: String,
    pub contact_installation_id: String,
    pub sequence: u64,
    pub state: String,
    pub attempt_count: u32,
    pub next_attempt_at: i64,
    pub ack_deadline: Option<i64>,
    pub last_error: Option<String>,
    pub created_at: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InboundPeerEnvelopeRecord {
    pub sender_installation_id: String,
    pub message_id: String,
    pub conversation_id: String,
    pub sequence: u64,
    pub ciphertext: Vec<u8>,
    pub ciphertext_hash: Vec<u8>,
    pub state: String,
    pub received_at: i64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InboundEnvelopeStoreResult {
    Stored,
    Duplicate { delivered: bool },
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

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PeerEndpointBootstrapRecord {
    pub contact_installation_id: String,
    pub payload: Vec<u8>,
    pub endpoint_sequence: u64,
    pub attempt_count: u32,
    pub next_attempt_at: i64,
    pub last_error: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PendingPeerEndpointInboxRecord {
    pub contact_installation_id: String,
    pub payload: Vec<u8>,
    pub endpoint_sequence: u64,
    pub received_at: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PendingContactConfirmationRecord {
    pub pairing_id: String,
    pub peer_installation_id: String,
    pub capability: String,
    pub attempt_count: u32,
    pub next_attempt_at: i64,
    pub last_error: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RetryKind {
    MessageSend,
    MessageAckDeadline,
    Receipt,
    PendingWelcome,
    PairingResponse,
    PeerEndpointBootstrap,
    ContactConfirmation,
    PairingAcknowledgement,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RetryDeadline {
    pub kind: RetryKind,
    pub at_ms: i64,
}

impl ClientDatabase {
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

    pub fn load_processed_command(
        &self,
        command_id: &str,
    ) -> EngineResult<Option<(String, String, i64)>> {
        self.connection
            .query_row(
                "SELECT command_type, result_json, committed_revision
                 FROM processed_commands WHERE command_id = ?1;",
                [command_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i64>(2)?,
                    ))
                },
            )
            .optional()
            .map_err(sqlite_error)
    }

    pub fn save_processed_command(
        &mut self,
        command_id: &str,
        command_type: &str,
        result_json: &str,
        committed_revision: u64,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "INSERT OR IGNORE INTO processed_commands
                 (command_id, command_type, result_json, committed_revision)
                 VALUES (?1, ?2, ?3, ?4);",
                rusqlite::params![
                    command_id,
                    command_type,
                    result_json,
                    committed_revision as i64
                ],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn projection_head(&self) -> EngineResult<(String, u64)> {
        self.connection
            .query_row(
                "SELECT store_id, global_revision FROM projection_meta WHERE singleton = 1;",
                [],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)? as u64)),
            )
            .map_err(sqlite_error)
    }

    pub fn migration_runner(&self) -> &MigrationRunner {
        &self.migration_runner
    }

    pub fn transaction(&mut self) -> EngineResult<SqliteTransaction<'_>> {
        let transaction = self.connection.transaction().map_err(sqlite_error)?;
        Ok(SqliteTransaction::new(transaction))
    }

    pub fn local_peer_endpoint(&self) -> EngineResult<Option<(PeerEndpointBundle, u64)>> {
        let stored = self
            .connection
            .query_row(
                "SELECT bundle_json, generation
                 FROM local_peer_endpoint
                 WHERE singleton = 1;",
                [],
                |row| {
                    Ok((
                        row.get::<_, Vec<u8>>("bundle_json")?,
                        row.get::<_, i64>("generation")?,
                    ))
                },
            )
            .optional()
            .map_err(sqlite_error)?;
        stored
            .map(|(json, generation)| {
                serde_json::from_slice(&json)
                    .map(|endpoint| (endpoint, generation as u64))
                    .map_err(|error| {
                        EngineError::Storage(format!("decode local peer endpoint: {error}"))
                    })
            })
            .transpose()
    }

    pub fn put_local_peer_endpoint(
        &self,
        endpoint: &PeerEndpointBundle,
        generation: u64,
    ) -> EngineResult<()> {
        let json = serde_json::to_vec(endpoint).map_err(|error| {
            EngineError::Storage(format!("encode local peer endpoint: {error}"))
        })?;
        self.connection
            .execute(
                "INSERT INTO local_peer_endpoint (
                    singleton, bundle_json, sequence, generation, updated_at
                 ) VALUES (1, ?1, ?2, ?3, unixepoch())
                 ON CONFLICT(singleton) DO UPDATE SET
                    bundle_json = excluded.bundle_json,
                    sequence = excluded.sequence,
                    generation = excluded.generation,
                    updated_at = unixepoch();",
                params![json, endpoint.sequence as i64, generation as i64],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn delete_local_peer_endpoint(&self) -> EngineResult<()> {
        self.connection
            .execute("DELETE FROM local_peer_endpoint WHERE singleton = 1;", [])
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn contact_peer_endpoint(
        &self,
        installation_id: &str,
    ) -> EngineResult<Option<PeerEndpointBundle>> {
        let json = self
            .connection
            .query_row(
                "SELECT bundle_json
                 FROM contact_peer_endpoints
                 WHERE contact_installation_id = ?1;",
                [installation_id],
                |row| row.get::<_, Vec<u8>>("bundle_json"),
            )
            .optional()
            .map_err(sqlite_error)?;
        json.map(|value| {
            serde_json::from_slice(&value).map_err(|error| {
                EngineError::Storage(format!("decode contact peer endpoint: {error}"))
            })
        })
        .transpose()
    }

    pub fn put_contact_peer_endpoint(&self, endpoint: &PeerEndpointBundle) -> EngineResult<()> {
        let json = serde_json::to_vec(endpoint).map_err(|error| {
            EngineError::Storage(format!("encode contact peer endpoint: {error}"))
        })?;
        self.connection
            .execute(
                "INSERT INTO contact_peer_endpoints (
                    contact_installation_id, bundle_json, sequence, updated_at
                 ) VALUES (?1, ?2, ?3, unixepoch())
                 ON CONFLICT(contact_installation_id) DO UPDATE SET
                    bundle_json = excluded.bundle_json,
                    sequence = excluded.sequence,
                    updated_at = unixepoch()
                 WHERE excluded.sequence > contact_peer_endpoints.sequence;",
                params![endpoint.installation_id, json, endpoint.sequence as i64,],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn mark_peer_connected(
        &self,
        installation_id: &str,
        connected_at: i64,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "UPDATE contact_peer_endpoints
                 SET last_connected_at = ?2, updated_at = unixepoch()
                 WHERE contact_installation_id = ?1;",
                params![installation_id, connected_at],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn enqueue_endpoint_update_for_contacts(
        &self,
        update: &PeerEndpointUpdate,
    ) -> EngineResult<()> {
        let payload = serde_json::to_vec(update).map_err(|error| {
            EngineError::Storage(format!("encode peer endpoint update: {error}"))
        })?;
        self.connection
            .execute(
                "INSERT OR IGNORE INTO endpoint_update_outbox (
                    contact_installation_id, payload, sequence, attempt_count,
                    next_attempt_at, last_error, updated_at
                 )
                 SELECT installation_id, ?1, ?2, 0, 0, NULL, unixepoch()
                 FROM contacts;",
                params![payload, update.endpoint.sequence as i64],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn pending_endpoint_updates(
        &self,
        contact_installation_id: &str,
    ) -> EngineResult<Vec<PeerEndpointUpdate>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT payload
                 FROM endpoint_update_outbox
                 WHERE contact_installation_id = ?1
                 ORDER BY sequence ASC;",
            )
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map([contact_installation_id], |row| row.get::<_, Vec<u8>>(0))
            .map_err(sqlite_error)?;
        rows.map(|row| {
            let payload = row.map_err(sqlite_error)?;
            serde_json::from_slice(&payload).map_err(|error| {
                EngineError::Storage(format!("decode peer endpoint update: {error}"))
            })
        })
        .collect()
    }

    pub fn complete_endpoint_updates(
        &self,
        contact_installation_id: &str,
        through_sequence: u64,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "DELETE FROM endpoint_update_outbox
                 WHERE contact_installation_id = ?1 AND sequence <= ?2;",
                params![contact_installation_id, through_sequence as i64],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn put_peer_endpoint_bootstrap(
        &self,
        contact_installation_id: &str,
        payload: &[u8],
        endpoint_sequence: u64,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "INSERT INTO peer_endpoint_bootstrap_outbox (
                    contact_installation_id, payload, endpoint_sequence, attempt_count,
                    next_attempt_at, last_error, updated_at
                 ) VALUES (?1, ?2, ?3, 0, 0, NULL, unixepoch())
                 ON CONFLICT(contact_installation_id) DO UPDATE SET
                    payload = excluded.payload,
                    endpoint_sequence = excluded.endpoint_sequence,
                    attempt_count = 0,
                    next_attempt_at = 0,
                    last_error = NULL,
                    updated_at = unixepoch()
                 WHERE excluded.endpoint_sequence >= peer_endpoint_bootstrap_outbox.endpoint_sequence;",
                params![contact_installation_id, payload, endpoint_sequence as i64],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn due_peer_endpoint_bootstraps(
        &self,
        now_ms: i64,
    ) -> EngineResult<Vec<PeerEndpointBootstrapRecord>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT contact_installation_id, payload, endpoint_sequence, attempt_count,
                        next_attempt_at, last_error
                 FROM peer_endpoint_bootstrap_outbox
                 WHERE next_attempt_at <= ?1
                 ORDER BY next_attempt_at ASC, contact_installation_id ASC;",
            )
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map([now_ms], |row| {
                Ok(PeerEndpointBootstrapRecord {
                    contact_installation_id: row.get("contact_installation_id")?,
                    payload: row.get("payload")?,
                    endpoint_sequence: row.get::<_, i64>("endpoint_sequence")? as u64,
                    attempt_count: row.get::<_, i64>("attempt_count")? as u32,
                    next_attempt_at: row.get("next_attempt_at")?,
                    last_error: row.get("last_error")?,
                })
            })
            .map_err(sqlite_error)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(sqlite_error)
    }

    pub fn claim_peer_endpoint_bootstrap_attempt(
        &self,
        contact_installation_id: &str,
        endpoint_sequence: u64,
        next_attempt_at: i64,
        last_error: Option<&str>,
    ) -> EngineResult<bool> {
        let changed = self
            .connection
            .execute(
                "UPDATE peer_endpoint_bootstrap_outbox
                 SET attempt_count = attempt_count + 1,
                     next_attempt_at = ?1,
                     last_error = ?2,
                     updated_at = unixepoch()
                 WHERE contact_installation_id = ?3
                   AND endpoint_sequence = ?4
                   AND next_attempt_at <= ?5;",
                params![
                    next_attempt_at,
                    last_error,
                    contact_installation_id,
                    endpoint_sequence as i64,
                    unix_ms()
                ],
            )
            .map_err(sqlite_error)?;
        Ok(changed == 1)
    }

    pub fn complete_peer_endpoint_bootstrap(
        &self,
        contact_installation_id: &str,
        endpoint_sequence: u64,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "DELETE FROM peer_endpoint_bootstrap_outbox
                 WHERE contact_installation_id = ?1
                   AND endpoint_sequence <= ?2;",
                params![contact_installation_id, endpoint_sequence as i64],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn next_peer_endpoint_bootstrap_retry_deadline_ms(&self) -> EngineResult<Option<i64>> {
        self.connection
            .query_row(
                "SELECT MIN(next_attempt_at) AS next_attempt_at
                 FROM peer_endpoint_bootstrap_outbox;",
                [],
                |row| row.get("next_attempt_at"),
            )
            .map_err(sqlite_error)
    }

    pub fn put_pending_contact_confirmation(
        &self,
        pairing_id: &str,
        peer_installation_id: &str,
        capability: &str,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "INSERT INTO pending_contact_confirmations (
                    pairing_id, peer_installation_id, capability, attempt_count,
                    next_attempt_at, last_error, created_at, updated_at
                 ) VALUES (?1, ?2, ?3, 0, 0, NULL, unixepoch(), unixepoch())
                 ON CONFLICT(pairing_id) DO UPDATE SET
                    peer_installation_id = excluded.peer_installation_id,
                    capability = excluded.capability,
                    attempt_count = 0,
                    next_attempt_at = 0,
                    last_error = NULL,
                    updated_at = unixepoch();",
                params![pairing_id, peer_installation_id, capability],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn put_pending_pairing_acknowledgement(
        &self,
        pairing_id: &str,
        last_error: Option<&str>,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "INSERT INTO pending_pairing_acknowledgements (
                    pairing_id, attempt_count, next_attempt_at, last_error
                 ) VALUES (?1, 0, 0, ?2)
                 ON CONFLICT(pairing_id) DO UPDATE SET
                    next_attempt_at = 0,
                    last_error = excluded.last_error;",
                params![pairing_id, last_error],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn due_pending_pairing_acknowledgements(
        &self,
        now_ms: i64,
    ) -> EngineResult<Vec<(String, u32)>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT pairing_id, attempt_count
                 FROM pending_pairing_acknowledgements
                 WHERE next_attempt_at <= ?1
                 ORDER BY next_attempt_at ASC, pairing_id ASC;",
            )
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map([now_ms], |row| {
                Ok((
                    row.get::<_, String>("pairing_id")?,
                    row.get::<_, i64>("attempt_count")? as u32,
                ))
            })
            .map_err(sqlite_error)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(sqlite_error)
    }

    pub fn claim_pending_pairing_acknowledgement_attempt(
        &self,
        pairing_id: &str,
        next_attempt_at: i64,
        last_error: Option<&str>,
    ) -> EngineResult<bool> {
        let now_ms = unix_ms();
        let changed = self
            .connection
            .execute(
                "UPDATE pending_pairing_acknowledgements
                 SET attempt_count = attempt_count + 1,
                     next_attempt_at = ?1,
                     last_error = ?2
                 WHERE pairing_id = ?3
                   AND next_attempt_at <= ?4;",
                params![next_attempt_at, last_error, pairing_id, now_ms],
            )
            .map_err(sqlite_error)?;
        Ok(changed > 0)
    }

    pub fn complete_pending_pairing_acknowledgement(&self, pairing_id: &str) -> EngineResult<()> {
        self.connection
            .execute(
                "DELETE FROM pending_pairing_acknowledgements
                 WHERE pairing_id = ?1;",
                [pairing_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn next_pending_pairing_acknowledgement_retry_deadline_ms(
        &self,
    ) -> EngineResult<Option<i64>> {
        self.connection
            .query_row(
                "SELECT MIN(next_attempt_at)
                 FROM pending_pairing_acknowledgements;",
                [],
                |row| row.get(0),
            )
            .optional()
            .map(|value| value.flatten())
            .map_err(sqlite_error)
    }

    pub fn due_pending_contact_confirmations(
        &self,
        now_ms: i64,
    ) -> EngineResult<Vec<PendingContactConfirmationRecord>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT pairing_id, peer_installation_id, capability, attempt_count,
                        next_attempt_at, last_error
                 FROM pending_contact_confirmations
                 WHERE next_attempt_at <= ?1
                 ORDER BY next_attempt_at ASC, pairing_id ASC;",
            )
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map([now_ms], |row| {
                Ok(PendingContactConfirmationRecord {
                    pairing_id: row.get("pairing_id")?,
                    peer_installation_id: row.get("peer_installation_id")?,
                    capability: row.get("capability")?,
                    attempt_count: row.get::<_, i64>("attempt_count")? as u32,
                    next_attempt_at: row.get("next_attempt_at")?,
                    last_error: row.get("last_error")?,
                })
            })
            .map_err(sqlite_error)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(sqlite_error)
    }

    pub fn claim_pending_contact_confirmation_attempt(
        &self,
        pairing_id: &str,
        next_attempt_at: i64,
        last_error: Option<&str>,
    ) -> EngineResult<bool> {
        let changed = self
            .connection
            .execute(
                "UPDATE pending_contact_confirmations
                 SET attempt_count = attempt_count + 1,
                     next_attempt_at = ?1,
                     last_error = ?2,
                     updated_at = unixepoch()
                 WHERE pairing_id = ?3
                   AND next_attempt_at <= ?4;",
                params![next_attempt_at, last_error, pairing_id, unix_ms()],
            )
            .map_err(sqlite_error)?;
        Ok(changed == 1)
    }

    pub fn complete_pending_contact_confirmation(&self, pairing_id: &str) -> EngineResult<()> {
        self.connection
            .execute(
                "DELETE FROM pending_contact_confirmations
                 WHERE pairing_id = ?1;",
                [pairing_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn record_peer_endpoint_bootstrap_error(
        &self,
        contact_installation_id: &str,
        endpoint_sequence: u64,
        error: &str,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "UPDATE peer_endpoint_bootstrap_outbox
                 SET last_error = ?1,
                     updated_at = unixepoch()
                 WHERE contact_installation_id = ?2
                   AND endpoint_sequence = ?3;",
                params![error, contact_installation_id, endpoint_sequence as i64],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn record_pending_contact_confirmation_error(
        &self,
        pairing_id: &str,
        error: &str,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "UPDATE pending_contact_confirmations
                 SET last_error = ?1,
                     updated_at = unixepoch()
                 WHERE pairing_id = ?2;",
                params![error, pairing_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn next_pending_contact_confirmation_retry_deadline_ms(&self) -> EngineResult<Option<i64>> {
        self.connection
            .query_row(
                "SELECT MIN(next_attempt_at) AS next_attempt_at
                 FROM pending_contact_confirmations;",
                [],
                |row| row.get("next_attempt_at"),
            )
            .map_err(sqlite_error)
    }

    pub fn enqueue_outbound_delivery(
        &self,
        message_id: &str,
        contact_installation_id: &str,
        sequence: u64,
        created_at: i64,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "INSERT INTO outbound_deliveries (
                    message_id, contact_installation_id, sequence, state,
                    attempt_count, next_attempt_at, created_at, updated_at
                 ) VALUES (?1, ?2, ?3, 'QUEUED', 0, 0, ?4, unixepoch())
                 ON CONFLICT(message_id) DO NOTHING;",
                params![
                    message_id,
                    contact_installation_id,
                    sequence as i64,
                    created_at,
                ],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn due_outbound_deliveries(
        &self,
        now_ms: i64,
        limit: usize,
    ) -> EngineResult<Vec<OutboundDeliveryRecord>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT message_id, contact_installation_id, sequence, state,
                        attempt_count, next_attempt_at, ack_deadline, last_error, created_at
                 FROM outbound_deliveries
                 WHERE UPPER(state) IN ('QUEUED', 'IN_FLIGHT')
                   AND next_attempt_at <= ?1
                 ORDER BY created_at ASC, message_id ASC
                 LIMIT ?2;",
            )
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map(params![now_ms, limit as i64], |row| {
                Ok(OutboundDeliveryRecord {
                    message_id: row.get("message_id")?,
                    contact_installation_id: row.get("contact_installation_id")?,
                    sequence: row.get::<_, i64>("sequence")? as u64,
                    state: row.get("state")?,
                    attempt_count: row.get::<_, i64>("attempt_count")? as u32,
                    next_attempt_at: row.get("next_attempt_at")?,
                    ack_deadline: row.get("ack_deadline")?,
                    last_error: row.get("last_error")?,
                    created_at: row.get("created_at")?,
                })
            })
            .map_err(sqlite_error)?;
        rows.collect::<rusqlite::Result<Vec<_>>>()
            .map_err(sqlite_error)
    }

    pub fn outbound_delivery(
        &self,
        message_id: &str,
    ) -> EngineResult<Option<OutboundDeliveryRecord>> {
        self.connection
            .query_row(
                "SELECT message_id, contact_installation_id, sequence, state,
                        attempt_count, next_attempt_at, ack_deadline, last_error, created_at
                 FROM outbound_deliveries
                 WHERE message_id = ?1;",
                [message_id],
                |row| {
                    Ok(OutboundDeliveryRecord {
                        message_id: row.get("message_id")?,
                        contact_installation_id: row.get("contact_installation_id")?,
                        sequence: row.get::<_, i64>("sequence")? as u64,
                        state: row.get("state")?,
                        attempt_count: row.get::<_, i64>("attempt_count")? as u32,
                        next_attempt_at: row.get("next_attempt_at")?,
                        ack_deadline: row.get("ack_deadline")?,
                        last_error: row.get("last_error")?,
                        created_at: row.get("created_at")?,
                    })
                },
            )
            .optional()
            .map_err(sqlite_error)
    }

    pub fn next_contact_peer_retry_deadline_ms(
        &self,
        installation_id: &str,
    ) -> EngineResult<Option<i64>> {
        self.connection
            .query_row(
                "SELECT MIN(next_attempt_at)
                 FROM outbound_deliveries
                 WHERE contact_installation_id = ?1
                   AND UPPER(state) = 'QUEUED';",
                [installation_id],
                |row| row.get(0),
            )
            .optional()
            .map(|value| value.flatten())
            .map_err(sqlite_error)
    }

    pub fn next_contact_receipt_retry_deadline_ms(
        &self,
        installation_id: &str,
    ) -> EngineResult<Option<i64>> {
        self.connection
            .query_row(
                "SELECT MIN(next_attempt_at)
                 FROM delivery_receipts
                 WHERE original_sender = ?1
                   AND UPPER(state) = 'PENDING';",
                [installation_id],
                |row| row.get(0),
            )
            .optional()
            .map(|value| value.flatten())
            .map_err(sqlite_error)
    }

    pub fn claim_outbound_delivery(
        &self,
        message_id: &str,
        next_attempt_at: i64,
        ack_deadline: i64,
    ) -> EngineResult<bool> {
        self.connection
            .execute(
                "UPDATE outbound_deliveries
                 SET state = 'IN_FLIGHT',
                     attempt_count = attempt_count + 1,
                     next_attempt_at = ?2,
                     ack_deadline = ?3,
                     last_error = NULL,
                     updated_at = unixepoch()
                 WHERE message_id = ?1
                   AND (
                       UPPER(state) = 'QUEUED'
                       OR (
                           UPPER(state) = 'IN_FLIGHT'
                           AND COALESCE(ack_deadline, 0) <= ?4
                       )
                   );",
                params![message_id, next_attempt_at, ack_deadline, unix_ms()],
            )
            .map(|changed| changed > 0)
            .map_err(sqlite_error)
    }

    pub fn requeue_outbound_delivery(
        &self,
        message_id: &str,
        next_attempt_at: i64,
        error: &str,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "UPDATE outbound_deliveries
                 SET state = 'QUEUED', next_attempt_at = ?2, ack_deadline = NULL,
                     last_error = ?3, updated_at = unixepoch()
                 WHERE message_id = ?1;",
                params![message_id, next_attempt_at, error],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn complete_outbound_delivery(&self, message_id: &str) -> EngineResult<()> {
        self.connection
            .execute(
                "DELETE FROM outbound_deliveries WHERE message_id = ?1;",
                [message_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn expedite_peer_deliveries(&self, installation_id: &str) -> EngineResult<()> {
        self.connection
            .execute(
                "UPDATE outbound_deliveries
                 SET state = 'QUEUED', next_attempt_at = 0, ack_deadline = NULL,
                     updated_at = unixepoch()
                 WHERE contact_installation_id = ?1;",
                [installation_id],
            )
            .map_err(sqlite_error)?;
        self.connection
            .execute(
                "UPDATE messages
                 SET state = CASE
                         WHEN UPPER(state) = 'SENDING' THEN 'QUEUED'
                         ELSE state
                     END,
                     next_attempt_at = 0,
                     ack_deadline = NULL
                 WHERE conversation_id = ?1
                   AND outgoing = 1
                   AND UPPER(state) IN ('QUEUED', 'SENDING');",
                [installation_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn requeue_peer_deliveries(&self, now_ms: i64) -> EngineResult<()> {
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(sqlite_error)?;
        transaction
            .execute(
                "UPDATE outbound_deliveries
                 SET state = 'QUEUED', next_attempt_at = ?1, ack_deadline = NULL,
                     updated_at = unixepoch()
                 WHERE UPPER(state) = 'IN_FLIGHT';",
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
                   AND UPPER(state) = 'SENDING'
                   AND id IN (
                        SELECT message_id
                        FROM outbound_deliveries
                        WHERE UPPER(state) = 'QUEUED'
                   );",
                [now_ms],
            )
            .map_err(sqlite_error)?;
        transaction.commit().map_err(sqlite_error)?;
        Ok(())
    }

    pub fn store_inbound_peer_envelope(
        &self,
        envelope: &PeerMessageEnvelope,
        received_at: i64,
    ) -> EngineResult<InboundEnvelopeStoreResult> {
        let hash = envelope.ciphertext_hash().to_vec();
        if let Some((existing_hash, state)) = self
            .connection
            .query_row(
                "SELECT ciphertext_hash, state
                 FROM inbound_peer_envelopes
                 WHERE sender_installation_id = ?1 AND message_id = ?2;",
                params![
                    envelope.sender_installation_id,
                    envelope.message_id.to_string(),
                ],
                |row| {
                    Ok((
                        row.get::<_, Vec<u8>>("ciphertext_hash")?,
                        row.get::<_, String>("state")?,
                    ))
                },
            )
            .optional()
            .map_err(sqlite_error)?
        {
            if existing_hash != hash {
                return Err(EngineError::InvalidCommand(
                    "duplicate peer envelope has different ciphertext".to_owned(),
                ));
            }
            return Ok(InboundEnvelopeStoreResult::Duplicate {
                delivered: state.eq_ignore_ascii_case("DELIVERED"),
            });
        }
        self.connection
            .execute(
                "INSERT INTO inbound_peer_envelopes (
                    sender_installation_id, message_id, conversation_id, sequence,
                    ciphertext, ciphertext_hash, state, received_at, updated_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'PERSISTED', ?7, unixepoch());",
                params![
                    envelope.sender_installation_id,
                    envelope.message_id.to_string(),
                    envelope.conversation_id,
                    envelope.sequence as i64,
                    envelope.ciphertext,
                    hash,
                    received_at,
                ],
            )
            .map_err(sqlite_error)?;
        Ok(InboundEnvelopeStoreResult::Stored)
    }

    pub fn pending_inbound_peer_envelopes(&self) -> EngineResult<Vec<InboundPeerEnvelopeRecord>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT sender_installation_id, message_id, conversation_id, sequence,
                        ciphertext, ciphertext_hash, state, received_at
                 FROM inbound_peer_envelopes
                 WHERE UPPER(state) = 'PERSISTED'
                 ORDER BY received_at ASC, message_id ASC;",
            )
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map([], |row| {
                Ok(InboundPeerEnvelopeRecord {
                    sender_installation_id: row.get("sender_installation_id")?,
                    message_id: row.get("message_id")?,
                    conversation_id: row.get("conversation_id")?,
                    sequence: row.get::<_, i64>("sequence")? as u64,
                    ciphertext: row.get("ciphertext")?,
                    ciphertext_hash: row.get("ciphertext_hash")?,
                    state: row.get("state")?,
                    received_at: row.get("received_at")?,
                })
            })
            .map_err(sqlite_error)?;
        rows.collect::<rusqlite::Result<Vec<_>>>()
            .map_err(sqlite_error)
    }

    pub fn rejected_inbound_peer_senders(&self) -> EngineResult<HashSet<String>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT DISTINCT sender_installation_id
                 FROM inbound_peer_envelopes
                 WHERE UPPER(state) = 'REJECTED';",
            )
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(sqlite_error)?;
        rows.collect::<rusqlite::Result<HashSet<_>>>()
            .map_err(sqlite_error)
    }

    pub fn complete_inbound_peer_envelope(
        &self,
        sender_installation_id: &str,
        message_id: &str,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "UPDATE inbound_peer_envelopes
                 SET state = 'DELIVERED', updated_at = unixepoch()
                 WHERE sender_installation_id = ?1 AND message_id = ?2;",
                params![sender_installation_id, message_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn reject_inbound_peer_envelope(
        &self,
        sender_installation_id: &str,
        message_id: &str,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "UPDATE inbound_peer_envelopes
                 SET state = 'REJECTED', updated_at = unixepoch()
                 WHERE sender_installation_id = ?1 AND message_id = ?2;",
                params![sender_installation_id, message_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn put_pending_local_invite_mls(
        &self,
        record: &PendingLocalInviteMlsRecord,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "INSERT INTO pending_local_invite_mls (
                    invite_id, recipient_installation_id, snapshot, expires_at
                 ) VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(invite_id) DO UPDATE SET
                    recipient_installation_id = excluded.recipient_installation_id,
                    snapshot = excluded.snapshot,
                    expires_at = excluded.expires_at;",
                params![
                    record.invite_id,
                    record.recipient_installation_id,
                    record.snapshot,
                    record.expires_at,
                ],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn pending_local_invite_mls(
        &self,
        invite_id: &str,
        now_secs: i64,
    ) -> EngineResult<Option<PendingLocalInviteMlsRecord>> {
        self.connection
            .query_row(
                "SELECT invite_id, recipient_installation_id, snapshot, expires_at
                 FROM pending_local_invite_mls
                 WHERE invite_id = ?1 AND expires_at >= ?2;",
                params![invite_id, now_secs],
                |row| {
                    Ok(PendingLocalInviteMlsRecord {
                        invite_id: row.get("invite_id")?,
                        recipient_installation_id: row.get("recipient_installation_id")?,
                        snapshot: row.get("snapshot")?,
                        expires_at: row.get("expires_at")?,
                    })
                },
            )
            .optional()
            .map_err(sqlite_error)
    }

    pub fn delete_expired_pending_local_invite_mls(&self, now_secs: i64) -> EngineResult<usize> {
        self.connection
            .execute(
                "DELETE FROM pending_local_invite_mls WHERE expires_at < ?1;",
                [now_secs],
            )
            .map_err(sqlite_error)
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

    pub fn pending_welcomes(&self, now_secs: i64) -> EngineResult<Vec<PendingWelcomeRecord>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT invite_id, recipient_installation_id, payload, expires_at,
                        attempt_count, next_attempt_at, last_error
                 FROM pending_welcomes
                 WHERE expires_at >= ?1
                 ORDER BY expires_at ASC, invite_id ASC;",
            )
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map([now_secs], |row| {
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

    pub fn pending_welcome(&self, invite_id: &str) -> EngineResult<Option<PendingWelcomeRecord>> {
        self.connection
            .query_row(
                "SELECT invite_id, recipient_installation_id, payload, expires_at,
                        attempt_count, next_attempt_at, last_error
                 FROM pending_welcomes
                 WHERE invite_id = ?1;",
                [invite_id],
                |row| {
                    Ok(PendingWelcomeRecord {
                        invite_id: row.get("invite_id")?,
                        recipient_installation_id: row.get("recipient_installation_id")?,
                        payload: row.get("payload")?,
                        expires_at: row.get("expires_at")?,
                        attempt_count: row.get::<_, i64>("attempt_count")? as u32,
                        next_attempt_at: row.get("next_attempt_at")?,
                        last_error: row.get("last_error")?,
                    })
                },
            )
            .optional()
            .map_err(sqlite_error)
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

    pub fn put_pending_peer_endpoint_inbox(
        &self,
        record: &PendingPeerEndpointInboxRecord,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "INSERT INTO pending_peer_endpoint_inbox (
                    contact_installation_id, payload, endpoint_sequence, received_at
                 ) VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(contact_installation_id) DO UPDATE SET
                    payload = excluded.payload,
                    endpoint_sequence = excluded.endpoint_sequence,
                    received_at = excluded.received_at
                 WHERE excluded.endpoint_sequence > pending_peer_endpoint_inbox.endpoint_sequence;",
                params![
                    record.contact_installation_id,
                    record.payload,
                    record.endpoint_sequence as i64,
                    record.received_at,
                ],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    pub fn pending_peer_endpoint_inbox(
        &self,
        contact_installation_id: &str,
    ) -> EngineResult<Option<PendingPeerEndpointInboxRecord>> {
        self.connection
            .query_row(
                "SELECT contact_installation_id, payload, endpoint_sequence, received_at
                 FROM pending_peer_endpoint_inbox
                 WHERE contact_installation_id = ?1;",
                [contact_installation_id],
                |row| {
                    Ok(PendingPeerEndpointInboxRecord {
                        contact_installation_id: row.get("contact_installation_id")?,
                        payload: row.get("payload")?,
                        endpoint_sequence: row.get::<_, i64>("endpoint_sequence")? as u64,
                        received_at: row.get("received_at")?,
                    })
                },
            )
            .optional()
            .map_err(sqlite_error)
    }

    pub fn remove_pending_peer_endpoint_inbox(
        &self,
        contact_installation_id: &str,
    ) -> EngineResult<()> {
        self.connection
            .execute(
                "DELETE FROM pending_peer_endpoint_inbox
                 WHERE contact_installation_id = ?1;",
                [contact_installation_id],
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

    pub fn delivery_receipt(
        &self,
        message_id: &str,
    ) -> EngineResult<Option<DeliveryReceiptRecord>> {
        self.connection
            .query_row(
                "SELECT envelope_id, message_id, conversation_id, original_sender, received_at,
                        relay_payload, state, attempt_count, next_attempt_at, last_error, created_at
                 FROM delivery_receipts
                 WHERE message_id = ?1;",
                [message_id],
                |row| {
                    Ok(DeliveryReceiptRecord {
                        envelope_id: row.get("envelope_id")?,
                        message_id: row.get("message_id")?,
                        conversation_id: row.get("conversation_id")?,
                        original_sender: row.get("original_sender")?,
                        received_at: row.get("received_at")?,
                        relay_payload: row.get("relay_payload")?,
                        state: row.get("state")?,
                        attempt_count: row.get::<_, i64>("attempt_count")? as u32,
                        next_attempt_at: row.get("next_attempt_at")?,
                        last_error: row.get("last_error")?,
                        created_at: row.get("created_at")?,
                    })
                },
            )
            .optional()
            .map_err(sqlite_error)
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

    pub fn persist_receipt_encryption(
        &mut self,
        message_id: &str,
        relay_payload: &[u8],
        conversation_id: &str,
        snapshot: &[u8],
        next_attempt_at: i64,
        last_error: Option<&str>,
    ) -> EngineResult<bool> {
        let now_ms = unix_ms();
        let transaction = self.connection.transaction().map_err(sqlite_error)?;
        let changed = transaction
            .execute(
                "UPDATE delivery_receipts
                 SET relay_payload = COALESCE(relay_payload, ?1),
                     state = 'SENT',
                     attempt_count = attempt_count + 1,
                     next_attempt_at = ?2,
                     last_error = ?3
                 WHERE message_id = ?4
                   AND UPPER(state) IN ('PENDING', 'SENT')
                   AND next_attempt_at <= ?5;",
                params![
                    relay_payload,
                    next_attempt_at,
                    last_error,
                    message_id,
                    now_ms
                ],
            )
            .map_err(sqlite_error)?;
        if changed == 0 {
            transaction.rollback().map_err(sqlite_error)?;
            return Ok(false);
        }
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
        transaction
            .execute(
                "UPDATE received_envelopes
                 SET receipt_state = 'SENT'
                 WHERE message_id = ?1;",
                [message_id],
            )
            .map_err(sqlite_error)?;
        transaction.commit().map_err(sqlite_error)?;
        Ok(true)
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
        Ok(changed > 0)
    }

    pub fn claim_receipt_attempt(
        &mut self,
        message_id: &str,
        next_attempt_at: i64,
        last_error: Option<&str>,
    ) -> EngineResult<bool> {
        let now_ms = unix_ms();
        let transaction = self.connection.transaction().map_err(sqlite_error)?;
        let changed = transaction
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
        if changed > 0 {
            transaction
                .execute(
                    "UPDATE received_envelopes
                     SET receipt_state = 'SENT'
                     WHERE message_id = ?1;",
                    [message_id],
                )
                .map_err(sqlite_error)?;
        }
        transaction.commit().map_err(sqlite_error)?;
        Ok(changed > 0)
    }

    pub fn complete_delivery_receipt(&mut self, message_id: &str) -> EngineResult<()> {
        let transaction = self.connection.transaction().map_err(sqlite_error)?;
        transaction
            .execute(
                "UPDATE delivery_receipts
                 SET state = 'DELIVERED', next_attempt_at = 0, last_error = NULL
                 WHERE message_id = ?1;",
                [message_id],
            )
            .map_err(sqlite_error)?;
        transaction
            .execute(
                "UPDATE received_envelopes
                 SET receipt_state = 'DELIVERED'
                 WHERE message_id = ?1;",
                [message_id],
            )
            .map_err(sqlite_error)?;
        transaction.commit().map_err(sqlite_error)?;
        Ok(())
    }

    pub fn requeue_delivery_receipt(
        &mut self,
        message_id: &str,
        next_attempt_at: i64,
        last_error: &str,
    ) -> EngineResult<()> {
        let transaction = self.connection.transaction().map_err(sqlite_error)?;
        transaction
            .execute(
                "UPDATE delivery_receipts
                 SET state = 'PENDING', next_attempt_at = ?1, last_error = ?2
                 WHERE message_id = ?3;",
                params![next_attempt_at, last_error, message_id],
            )
            .map_err(sqlite_error)?;
        transaction
            .execute(
                "UPDATE received_envelopes
                 SET receipt_state = 'PENDING'
                 WHERE message_id = ?1;",
                [message_id],
            )
            .map_err(sqlite_error)?;
        transaction.commit().map_err(sqlite_error)?;
        Ok(())
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
                 SET last_error = ?1
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
    fn open_runs_all_migrations_with_correct_sqlcipher_key() {
        let path = temp_database_path("migrations");
        let database = ClientDatabase::open(&path, &key(7)).expect("database opens");

        let latest_version: i64 = database
            .connection()
            .query_row("SELECT MAX(version) FROM schema_migrations;", [], |row| {
                row.get("MAX(version)")
            })
            .expect("schema_migrations version is readable");

        assert_eq!(latest_version, 16);
        assert_eq!(database.migration_runner().checksum().len(), 64);

        drop(database);
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
        assert_eq!(latest_version, 16);
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
            .record_peer_endpoint_bootstrap_error("contact-1", 1, "relay unavailable")
            .expect("error persists");

        let record = database
            .due_peer_endpoint_bootstraps(0)
            .expect("bootstrap rows are readable")
            .into_iter()
            .find(|row| row.contact_installation_id == "contact-1")
            .expect("bootstrap row exists");

        assert_eq!(record.last_error.as_deref(), Some("relay unavailable"));

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
