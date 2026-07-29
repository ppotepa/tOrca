use rusqlite::Transaction;

use crate::{EngineError, EngineResult};

pub struct SqliteTransaction<'db> {
    transaction: Option<Transaction<'db>>,
}

impl<'db> SqliteTransaction<'db> {
    pub fn new(transaction: Transaction<'db>) -> Self {
        Self {
            transaction: Some(transaction),
        }
    }

    pub fn as_ref(&self) -> &Transaction<'db> {
        self.transaction
            .as_ref()
            .expect("sqlite transaction must be present while active")
    }

    pub fn as_mut(&mut self) -> &mut Transaction<'db> {
        self.transaction
            .as_mut()
            .expect("sqlite transaction must be present while active")
    }

    pub fn commit(mut self) -> EngineResult<()> {
        self.transaction
            .take()
            .expect("sqlite transaction must exist for commit")
            .commit()
            .map_err(sqlite_error)
    }

    pub fn rollback(mut self) -> EngineResult<()> {
        self.transaction
            .take()
            .expect("sqlite transaction must exist for rollback")
            .rollback()
            .map_err(sqlite_error)
    }
}

fn sqlite_error(error: rusqlite::Error) -> EngineError {
    EngineError::Storage(format!("{error:#}"))
}
