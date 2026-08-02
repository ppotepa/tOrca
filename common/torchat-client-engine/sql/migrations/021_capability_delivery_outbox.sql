CREATE TABLE capability_delivery_outbox (
    delivery_id TEXT PRIMARY KEY NOT NULL,
    contact_installation_id TEXT NOT NULL,
    payload BLOB NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    created_at INTEGER NOT NULL
);

CREATE INDEX idx_capability_delivery_outbox_due
    ON capability_delivery_outbox(next_attempt_at, created_at);
