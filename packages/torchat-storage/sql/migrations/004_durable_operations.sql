CREATE TABLE IF NOT EXISTS durable_operations (
    operation_id TEXT PRIMARY KEY NOT NULL,
    operation_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    state TEXT NOT NULL,
    started_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    retry_at INTEGER,
    error_code TEXT
);

CREATE INDEX IF NOT EXISTS idx_durable_operations_pending
    ON durable_operations(state, retry_at, updated_at)
    WHERE state IN ('pending', 'running', 'waiting_for_retry');
