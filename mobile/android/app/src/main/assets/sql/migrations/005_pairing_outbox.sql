CREATE TABLE IF NOT EXISTS pairing_outbox (
    pairing_id TEXT PRIMARY KEY,
    expires_at INTEGER NOT NULL,
    state TEXT NOT NULL
);
