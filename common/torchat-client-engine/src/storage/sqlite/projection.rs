use super::*;

impl ClientDatabase {
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
}
