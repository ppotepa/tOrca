use rusqlite::{Connection, OptionalExtension};
use sha2::{Digest, Sha256};

use crate::{EngineError, EngineResult};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Migration {
    pub version: i64,
    pub name: &'static str,
    pub sql: &'static str,
}

pub struct MigrationRunner {
    migrations: &'static [Migration],
}

impl MigrationRunner {
    pub const fn new(migrations: &'static [Migration]) -> Self {
        Self { migrations }
    }

    pub fn migrations(&self) -> &'static [Migration] {
        self.migrations
    }

    pub fn run(&self, connection: &Connection) -> EngineResult<()> {
        let transaction = connection.unchecked_transaction().map_err(sqlite_error)?;
        self.run_locked(&transaction)?;
        transaction.commit().map_err(sqlite_error)
    }

    fn run_locked(&self, connection: &Connection) -> EngineResult<()> {
        for migration in self.migrations {
            if migration.version == 0 && !schema_migrations_table_exists(connection)? {
                connection
                    .execute_batch(migration.sql)
                    .map_err(sqlite_error)?;
            }

            let applied = applied_version(connection, migration.name)?;
            if applied == Some(migration.version) {
                continue;
            }
            if let Some(other_version) = applied {
                return Err(EngineError::Storage(format!(
                    "migration {} was recorded with version {}, expected {}",
                    migration.name, other_version, migration.version,
                )));
            }

            connection
                .execute_batch(migration.sql)
                .map_err(sqlite_error)?;
            connection
                .execute(
                    super::sqlite::sql_catalog::metadata::MIGRATION_INSERT,
                    rusqlite::params![migration.version, migration.name],
                )
                .map_err(sqlite_error)?;

            let verified = applied_version(connection, migration.name)?;
            if verified != Some(migration.version) {
                return Err(EngineError::Storage(format!(
                    "migration {} verification failed: expected version {}, found {:?}",
                    migration.name, migration.version, verified,
                )));
            }
        }
        Ok(())
    }

    pub fn checksum(&self) -> String {
        let mut digest = Sha256::new();
        for migration in self.migrations {
            digest.update(migration.version.to_le_bytes());
            digest.update(migration.name.as_bytes());
            digest.update(migration.sql.as_bytes());
        }
        format!("{:x}", digest.finalize())
    }
}

fn applied_version(connection: &Connection, migration_name: &str) -> EngineResult<Option<i64>> {
    connection
        .query_row(super::sqlite::MIGRATION_LOOKUP, [migration_name], |row| {
            row.get("version")
        })
        .optional()
        .map_err(sqlite_error)
}

fn sqlite_error(error: rusqlite::Error) -> EngineError {
    EngineError::Storage(format!("{error:#}"))
}

fn schema_migrations_table_exists(connection: &Connection) -> EngineResult<bool> {
    connection
        .query_row(
            super::sqlite::sql_catalog::metadata::SCHEMA_MIGRATIONS_TABLE_EXISTS,
            [],
            |_| Ok(()),
        )
        .optional()
        .map(|value| value.is_some())
        .map_err(sqlite_error)
}
