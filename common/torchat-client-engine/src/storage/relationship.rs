use rusqlite::{OptionalExtension, params};

use crate::{EngineError, EngineResult};

use super::ClientDatabase;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RelationshipTombstone {
    pub contact_installation_id: String,
    pub removed_at: i64,
    pub preserve_history: bool,
}

impl ClientDatabase {
    pub fn apply_relationship_removal(
        &mut self,
        contact_installation_id: &str,
        removed_at: i64,
        preserve_history: bool,
    ) -> EngineResult<()> {
        if contact_installation_id.trim().is_empty() {
            return Err(EngineError::InvalidCommand(
                "contact installation id must not be empty".to_owned(),
            ));
        }
        let transaction = self.transaction()?;
        let tx = transaction.as_ref();
        tx.execute_batch(
            "CREATE TABLE IF NOT EXISTS relationship_tombstones (
                contact_installation_id TEXT PRIMARY KEY,
                removed_at INTEGER NOT NULL,
                preserve_history INTEGER NOT NULL DEFAULT 1
            );",
        )
        .map_err(storage_error)?;
        tx.execute(
            "INSERT INTO relationship_tombstones (
                contact_installation_id, removed_at, preserve_history
             ) VALUES (?1, ?2, ?3)
             ON CONFLICT(contact_installation_id) DO UPDATE SET
                removed_at = excluded.removed_at,
                preserve_history = excluded.preserve_history;",
            params![
                contact_installation_id,
                removed_at,
                i64::from(preserve_history),
            ],
        )
        .map_err(storage_error)?;
        tx.execute(
            "UPDATE contacts
             SET blocked = 1, updated_at = unixepoch()
             WHERE installation_id = ?1;",
            [contact_installation_id],
        )
        .map_err(storage_error)?;
        tx.execute(
            "UPDATE conversations
             SET state = 'OFFLINE', updated_at = unixepoch()
             WHERE contact_installation_id = ?1;",
            [contact_installation_id],
        )
        .map_err(storage_error)?;
        if !preserve_history {
            tx.execute(
                "DELETE FROM messages
                 WHERE conversation_id IN (
                    SELECT id FROM conversations
                    WHERE contact_installation_id = ?1
                 );",
                [contact_installation_id],
            )
            .map_err(storage_error)?;
        }
        tx.execute(
            "DELETE FROM conversation_mls
             WHERE conversation_id IN (
                SELECT id FROM conversations
                WHERE contact_installation_id = ?1
             );",
            [contact_installation_id],
        )
        .map_err(storage_error)?;
        tx.execute(
            "DELETE FROM outbound_deliveries
             WHERE contact_installation_id = ?1;",
            [contact_installation_id],
        )
        .map_err(storage_error)?;
        tx.execute(
            "DELETE FROM contact_peer_endpoints
             WHERE contact_installation_id = ?1;",
            [contact_installation_id],
        )
        .map_err(storage_error)?;
        tx.execute(
            "DELETE FROM endpoint_update_outbox
             WHERE contact_installation_id = ?1;",
            [contact_installation_id],
        )
        .map_err(storage_error)?;
        transaction.commit()
    }

    pub fn relationship_tombstone(
        &mut self,
        contact_installation_id: &str,
    ) -> EngineResult<Option<RelationshipTombstone>> {
        let transaction = self.transaction()?;
        let tx = transaction.as_ref();
        tx.execute_batch(
            "CREATE TABLE IF NOT EXISTS relationship_tombstones (
                contact_installation_id TEXT PRIMARY KEY,
                removed_at INTEGER NOT NULL,
                preserve_history INTEGER NOT NULL DEFAULT 1
            );",
        )
        .map_err(storage_error)?;
        let value = tx
            .query_row(
                "SELECT contact_installation_id, removed_at, preserve_history
                 FROM relationship_tombstones
                 WHERE contact_installation_id = ?1;",
                [contact_installation_id],
                |row| {
                    Ok(RelationshipTombstone {
                        contact_installation_id: row.get("contact_installation_id")?,
                        removed_at: row.get("removed_at")?,
                        preserve_history: row.get::<_, i64>("preserve_history")? != 0,
                    })
                },
            )
            .optional()
            .map_err(storage_error)?;
        transaction.rollback()?;
        Ok(value)
    }

    pub fn clear_relationship_tombstone(
        &mut self,
        contact_installation_id: &str,
    ) -> EngineResult<()> {
        let transaction = self.transaction()?;
        transaction
            .as_ref()
            .execute(
                "DELETE FROM relationship_tombstones
                 WHERE contact_installation_id = ?1;",
                [contact_installation_id],
            )
            .map_err(storage_error)?;
        transaction.commit()
    }
}

fn storage_error(error: rusqlite::Error) -> EngineError {
    EngineError::Storage(format!("{error:#}"))
}
