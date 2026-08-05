use super::*;

impl ClientDatabase {
    pub const PROCESSED_COMMAND_RETENTION_SECS: i64 = 30 * 24 * 60 * 60;
    pub const MAX_PROCESSED_COMMANDS: i64 = 10_000;

    /// Removes replay records outside the bounded idempotency window.
    ///
    /// The command journal is intentionally finite: command IDs are expected
    /// to be replayed during the retry/restart horizon, not used as an
    /// unbounded audit log.
    pub fn prune_processed_commands(
        &self,
        now: i64,
        retention_secs: i64,
        max_rows: i64,
    ) -> EngineResult<usize> {
        let retention_secs = retention_secs.max(0);
        let max_rows = max_rows.max(0);
        let mut removed = self
            .connection
            .execute(
                super::sql_catalog::projection::PRUNE_BY_AGE,
                [now.saturating_sub(retention_secs)],
            )
            .map_err(sqlite_error)?;
        let overflow = self
            .connection
            .execute(super::sql_catalog::projection::PRUNE_OVER_LIMIT, [max_rows])
            .map_err(sqlite_error)?;
        removed += overflow;
        Ok(removed)
    }

    pub fn load_processed_command(
        &self,
        command_id: &str,
    ) -> EngineResult<Option<(String, String, i64)>> {
        self.connection
            .query_row(
                super::sql_catalog::projection::GET_PROCESSED_COMMAND,
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
                super::sql_catalog::projection::SAVE_PROCESSED_COMMAND,
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
            .query_row(super::sql_catalog::projection::GET_HEAD, [], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)? as u64))
            })
            .map_err(sqlite_error)
    }
}
