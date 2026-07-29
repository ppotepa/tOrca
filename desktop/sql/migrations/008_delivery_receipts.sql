CREATE TABLE delivery_receipts (
    message_id TEXT PRIMARY KEY,
    original_sender TEXT NOT NULL,
    state TEXT NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    last_error TEXT
);

CREATE INDEX delivery_receipts_retry
ON delivery_receipts (
    state,
    next_attempt_at
);
