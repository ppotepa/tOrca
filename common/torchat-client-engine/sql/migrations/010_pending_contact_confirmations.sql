CREATE TABLE IF NOT EXISTS pending_contact_confirmations (
    pairing_id TEXT PRIMARY KEY,
    peer_installation_id TEXT NOT NULL,
    capability TEXT NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE INDEX IF NOT EXISTS idx_pending_contact_confirmations_retry
ON pending_contact_confirmations(next_attempt_at, pairing_id);
