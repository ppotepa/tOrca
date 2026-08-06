SELECT operation_id, operation_type, entity_id, state, started_at,
       updated_at, attempt_count, retry_at, error_code, command_descriptor
FROM durable_operations
WHERE state IN ('pending', 'running', 'waiting_for_retry')
ORDER BY COALESCE(retry_at, updated_at) ASC, operation_id ASC;
