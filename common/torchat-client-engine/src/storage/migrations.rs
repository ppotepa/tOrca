use rusqlite::{Connection, OptionalExtension, params};
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
        for migration in self.migrations {
            let applied: Option<i64> = connection
                .query_row(super::sqlite::MIGRATION_LOOKUP, [migration.name], |row| {
                    row.get("version")
                })
                .optional()
                .map_err(sqlite_error)?;
            if applied == Some(migration.version) {
                continue;
            }
            connection
                .execute_batch(migration.sql)
                .map_err(sqlite_error)?;
            connection
                .execute(
                    super::sqlite::MIGRATION_INSERT,
                    params![migration.version, migration.name],
                )
                .map_err(sqlite_error)?;
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

fn sqlite_error(error: rusqlite::Error) -> EngineError {
    EngineError::Storage(format!("{error:#}"))
}
