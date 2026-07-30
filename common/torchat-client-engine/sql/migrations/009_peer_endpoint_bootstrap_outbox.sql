CREATE TABLE IF NOT EXISTS peer_endpoint_bootstrap_outbox (
    contact_installation_id TEXT PRIMARY KEY,
    payload BLOB NOT NULL,
    endpoint_sequence INTEGER NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    updated_at INTEGER NOT NULL,
    FOREIGN KEY (contact_installation_id)
        REFERENCES contacts(installation_id)
        ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_peer_endpoint_bootstrap_retry
ON peer_endpoint_bootstrap_outbox(next_attempt_at, contact_installation_id);
