INSERT INTO processed_commands
                 (command_id, command_type, result_json, committed_revision)
                 VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(command_id) DO NOTHING;
