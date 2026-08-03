CREATE TABLE IF NOT EXISTS relationship_removal_ack_outbox (
    removal_id TEXT PRIMARY KEY,
    contact_installation_id TEXT NOT NULL,
    relationship_epoch INTEGER NOT NULL,
    payload BLOB NOT NULL,
    state TEXT NOT NULL DEFAULT 'PENDING',
    attempt_count INTEGER NOT NULL DEFAULT 0,
    claimed_until INTEGER,
    next_attempt_at INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    last_error_code TEXT,
    dead_lettered_at INTEGER,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX IF NOT EXISTS idx_relationship_removal_ack_retry
ON relationship_removal_ack_outbox(state, next_attempt_at, removal_id);
