CREATE TABLE IF NOT EXISTS pending_pairing_acknowledgements (
    pairing_id TEXT PRIMARY KEY,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL DEFAULT 0,
    last_error TEXT
);

CREATE INDEX IF NOT EXISTS idx_pending_pairing_acknowledgements_retry
ON pending_pairing_acknowledgements(next_attempt_at, pairing_id);
