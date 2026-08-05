INSERT INTO durable_operations (
    operation_id, operation_type, entity_id, state, started_at,
    updated_at, attempt_count, retry_at, error_code
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
ON CONFLICT(operation_id) DO UPDATE SET
    operation_type = excluded.operation_type,
    entity_id = excluded.entity_id,
    state = excluded.state,
    started_at = excluded.started_at,
    updated_at = excluded.updated_at,
    attempt_count = excluded.attempt_count,
    retry_at = excluded.retry_at,
    error_code = excluded.error_code;
