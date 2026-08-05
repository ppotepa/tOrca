SELECT command_type, result_json, committed_revision
FROM processed_commands WHERE command_id = ?1;
