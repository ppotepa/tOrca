use rusqlite::OptionalExtension;

use crate::{EngineError, EngineResult};

use super::ClientDatabase;

const ENSURE_TABLE: &str = "CREATE TABLE IF NOT EXISTS relationship_tombstones (
    contact_installation_id TEXT PRIMARY KEY,
    removed_at INTEGER NOT NULL,
    preserve_history INTEGER NOT NULL DEFAULT 1
);";

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
        tx.execute_batch(ENSURE_TABLE).map_err(storage_error)?;
        tx.execute(
            "INSERT INTO relationship_tombstones (
                contact_installation_id, removed_at, preserve_history
             ) VALUES (?1, ?2, ?3)
             ON CONFLICT(contact_installation_id) DO UPDATE SET
                removed_at = excluded.removed_at,
                preserve_history = excluded.preserve_history;",
            rusqlite::params![
                contact_installation_id,
                removed_at,
                if preserve_history { 1_i64 } else { 0_i64 },
            ],
        )
        .map_err(storage_error)?;
        tx.execute(
            "UPDATE contacts SET blocked = 1, updated_at = unixepoch()
             WHERE installation_id = ?1;",
            [contact_installation_id],
        )
        .map_err(storage_error)?;
        tx.execute(
            "UPDATE conversations SET state = 'OFFLINE', updated_at = unixepoch()
             WHERE contact_installation_id = ?1;",
            [contact_installation_id],
        )
        .map_err(storage_error)?;
        if !preserve_history {
            tx.execute(
                "DELETE FROM messages WHERE conversation_id IN (
                    SELECT id FROM conversations WHERE contact_installation_id = ?1
                 );",
                [contact_installation_id],
            )
            .map_err(storage_error)?;
        }
        for sql in [
            "DELETE FROM conversation_mls WHERE conversation_id IN (
                SELECT id FROM conversations WHERE contact_installation_id = ?1
             );",
            "DELETE FROM outbound_deliveries WHERE contact_installation_id = ?1;",
            "DELETE FROM contact_peer_endpoints WHERE contact_installation_id = ?1;",
            "DELETE FROM endpoint_update_outbox WHERE contact_installation_id = ?1;",
        ] {
            tx.execute(sql, [contact_installation_id])
                .map_err(storage_error)?;
        }
        transaction.commit()
    }

    pub fn relationship_tombstone(
        &mut self,
        contact_installation_id: &str,
    ) -> EngineResult<Option<RelationshipTombstone>> {
        let transaction = self.transaction()?;
        let tx = transaction.as_ref();
        tx.execute_batch(ENSURE_TABLE).map_err(storage_error)?;
        let value = tx
            .query_row(
                "SELECT contact_installation_id, removed_at, preserve_history
                 FROM relationship_tombstones WHERE contact_installation_id = ?1;",
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
                "DELETE FROM relationship_tombstones WHERE contact_installation_id = ?1;",
                [contact_installation_id],
            )
            .map_err(storage_error)?;
        transaction.commit()
    }
}

fn storage_error(error: rusqlite::Error) -> EngineError {
    EngineError::Storage(format!("{error:#}"))
}

#[cfg(test)]
mod tests {
    use std::{fs, path::PathBuf};

    use uuid::Uuid;

    use crate::{ClientDatabase, config::SecretBytes};

    fn database() -> (ClientDatabase, PathBuf) {
        let path = std::env::temp_dir().join(format!(
            "torchat-relationship-{}.sqlite",
            Uuid::new_v4()
        ));
        let database = ClientDatabase::open(&path, &SecretBytes(vec![7; 32]))
            .expect("temporary encrypted database should open");
        (database, path)
    }

    fn seed_relationship(database: &mut ClientDatabase) {
        let transaction = database.transaction().unwrap();
        transaction
            .as_ref()
            .execute_batch(
                "INSERT INTO contacts (
                    installation_id, nickname, public_key, fingerprint,
                    verification, source
                 ) VALUES ('peer-1', 'Alice', 'public', 'fingerprint',
                           'VERIFIED', 'PAIRING');
                 INSERT INTO conversations (
                    id, contact_installation_id, state, unread_count,
                    last_message_preview, last_message_at
                 ) VALUES ('peer-1', 'peer-1', 'ACTIVE', 0, 'hello', 1);
                 INSERT INTO conversation_mls (conversation_id, snapshot)
                 VALUES ('peer-1', X'010203');
                 INSERT INTO messages (
                    id, conversation_id, outgoing, body, state,
                    created_at, next_attempt_at
                 ) VALUES ('message-1', 'peer-1', 0, 'hello', 'DELIVERED', 1, 0);",
            )
            .unwrap();
        transaction.commit().unwrap();
    }

    fn scalar(database: &mut ClientDatabase, sql: &str) -> i64 {
        let transaction = database.transaction().unwrap();
        let value = transaction
            .as_ref()
            .query_row(sql, [], |row| row.get(0))
            .unwrap();
        transaction.rollback().unwrap();
        value
    }

    #[test]
    fn removal_preserves_history_but_disables_relationship() {
        let (mut database, path) = database();
        seed_relationship(&mut database);
        database
            .apply_relationship_removal("peer-1", 42, true)
            .unwrap();

        let tombstone = database
            .relationship_tombstone("peer-1")
            .unwrap()
            .expect("tombstone should exist");
        assert_eq!(tombstone.removed_at, 42);
        assert!(tombstone.preserve_history);
        assert_eq!(
            scalar(
                &mut database,
                "SELECT blocked FROM contacts WHERE installation_id = 'peer-1';"
            ),
            1
        );
        assert_eq!(
            scalar(
                &mut database,
                "SELECT COUNT(*) FROM conversations WHERE id = 'peer-1' AND state = 'OFFLINE';"
            ),
            1
        );
        assert_eq!(scalar(&mut database, "SELECT COUNT(*) FROM messages;"), 1);
        assert_eq!(scalar(&mut database, "SELECT COUNT(*) FROM conversation_mls;"), 0);
        drop(database);
        let _ = fs::remove_file(path);
    }

    #[test]
    fn removal_can_delete_local_history() {
        let (mut database, path) = database();
        seed_relationship(&mut database);
        database
            .apply_relationship_removal("peer-1", 43, false)
            .unwrap();
        assert_eq!(scalar(&mut database, "SELECT COUNT(*) FROM messages;"), 0);
        assert!(!database
            .relationship_tombstone("peer-1")
            .unwrap()
            .unwrap()
            .preserve_history);
        drop(database);
        let _ = fs::remove_file(path);
    }

    #[test]
    fn tombstone_can_be_cleared_for_fresh_pairing() {
        let (mut database, path) = database();
        seed_relationship(&mut database);
        database
            .apply_relationship_removal("peer-1", 44, true)
            .unwrap();
        database.clear_relationship_tombstone("peer-1").unwrap();
        assert!(database.relationship_tombstone("peer-1").unwrap().is_none());
        drop(database);
        let _ = fs::remove_file(path);
    }
}
