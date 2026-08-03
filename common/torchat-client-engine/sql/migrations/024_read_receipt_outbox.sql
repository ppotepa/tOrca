CREATE TABLE IF NOT EXISTS read_receipt_outbox (
    receipt_id TEXT PRIMARY KEY,
    contact_installation_id TEXT NOT NULL,
    conversation_id TEXT NOT NULL,
    message_ids_json TEXT NOT NULL,
    read_at INTEGER NOT NULL,
    wire_ciphertext BLOB,
    state TEXT NOT NULL DEFAULT 'QUEUED',
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    UNIQUE(contact_installation_id, conversation_id, message_ids_json),
    FOREIGN KEY (contact_installation_id) REFERENCES contacts(installation_id)
        ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_read_receipt_outbox_retry
ON read_receipt_outbox(state, next_attempt_at, created_at, receipt_id);
