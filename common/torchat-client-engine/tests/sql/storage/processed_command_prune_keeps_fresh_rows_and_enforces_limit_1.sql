INSERT INTO processed_commands
                     (command_id, command_type, result_json, committed_revision, created_at)
                     VALUES (?1, 'test', '{}', ?2, ?3);
