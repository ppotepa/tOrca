SELECT operation_id, operation_type, entity_id, state, started_at,
       updated_at, attempt_count, retry_at, error_code, command_descriptor
FROM durable_operations
WHERE operation_id = ?1
LIMIT 1;
